import Cocoa
import SwiftUI

/// Owns one borderless, transparent, screen-sized panel per display and
/// draws the user's "circle-to-ask" stroke on whichever screen the cursor
/// is on while the talk hotkey is held.
///
/// Lifecycle: `begin()` on hotkey press, `end()` on release. `end()` hands
/// back the stroke's bounding box in GLOBAL AppKit coordinates (bottom-left
/// origin) so a later task can crop a screenshot to it.
///
/// Panels are created once and then reused forever — same pre-warm
/// principle as NudgeMenuController. Building an NSPanel + NSHostingView is
/// the expensive part; doing it per-session would stutter the first frames
/// of every stroke.
final class CircleOverlayController {
    static let shared = CircleOverlayController()

    private(set) var isActive = false

    /// One overlay per physical display, keyed by CGDirectDisplayID.
    private var overlays: [CGDirectDisplayID: ScreenOverlay] = [:]
    /// 60fps cursor sampler. Only alive between begin() and end() — this is
    /// a menu-bar app that stays resident for days.
    private var sampleTimer: Timer?

    /// Every sampled point in GLOBAL AppKit coordinates, kept in parallel
    /// with the per-screen view-local points. The returned bounding box is
    /// computed from THIS array, never from the view-local one, so a
    /// multi-display layout (screens at negative / non-zero origins) can't
    /// shift the crop.
    private var globalPoints: [CGPoint] = []
    /// Frame of the screen the stroke started on — the rect is clamped to it.
    private var owningScreenFrame: NSRect?
    /// Bumped by begin() and end() so a pending fade-out is abandoned if a
    /// new session started in the meantime.
    private var sessionGeneration = 0
    /// Consecutive ticks the talk modifiers have read as absent. Drives the
    /// debounced self-heal; reset by any tick that sees them held.
    private var modifiersAbsentTicks = 0
    /// TEMP DIAGNOSTIC — remove with the TALK diag lines.
    private var diagTickCount = 0

    /// Fewer points than this means the user held the hotkey without really
    /// drawing (a stray click, a twitch) — treat it as "no circle".
    private static let minimumPoints = 5
    /// A sample is only recorded once the cursor has moved at least this far
    /// from the previous recorded point. Samples are TIME-based (60fps), not
    /// motion-based, so without this gate a stationary click-and-hold piles
    /// up identical points and clears `minimumPoints` in ~84ms. 2pt is below
    /// the smallest deliberate hand movement but above cursor jitter, and it
    /// also keeps a long hold from accumulating ~1800 near-duplicate points
    /// that the Canvas would re-walk every frame.
    private static let minimumMovement: CGFloat = 2
    /// The raw stroke must span at least this much in its LARGER dimension.
    /// Rejects a degenerate box that the padding would otherwise inflate into
    /// a plausible-looking 24x24 rect. Deliberately `max` and not both axes:
    /// striking through or underlining a line of text is a legitimate gesture
    /// with a near-zero height.
    private static let minimumStrokeSpan: CGFloat = 16
    /// Breathing room around the stroke so the crop includes what was ringed,
    /// not just the ink.
    private static let padding: CGFloat = 12
    private static let fadeDuration: TimeInterval = 0.25
    /// The self-heal only fires after the modifiers have read as absent for
    /// this many CONSECUTIVE ticks — ~300ms at 60fps. Without the grace
    /// period the heal races the normal release path and wins: modifier
    /// state goes false the instant the keys are lifted, whereas onRelease
    /// arrives later (event-tap callback → DispatchQueue.main.async), and
    /// CFRunLoop services timers before ports. A heal that fired first would
    /// consume the session and leave the real `end()` returning nil, quietly
    /// throwing away the user's circle. 300ms is far longer than that gap
    /// yet short enough that a genuine disaster recovery is invisible.
    private static let selfHealGraceTicks = 18

    private init() {}

    // MARK: - Session

    /// Show the overlays and start sampling the cursor.
    func begin() {
        guard !isActive else { return }
        TalkHotkeyMonitor.diag("overlay begin(), screens=\(NSScreen.screens.count)")
        isActive = true
        sessionGeneration += 1

        globalPoints.removeAll()
        owningScreenFrame = nil
        modifiersAbsentTicks = 0
        diagTickCount = 0

        syncPanels()

        // A fade-out from the previous session may still be in flight; a
        // zero-duration animator write replaces it, which a plain
        // `alphaValue = 1` would not.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            for overlay in overlays.values {
                overlay.panel.animator().alphaValue = 1
            }
        }

        for overlay in overlays.values {
            overlay.model.reset()
            // Owner decision (QA session): drawing needs no mouse button —
            // hold ⌃⌥ and move the cursor, like HeyClicky. The panels
            // therefore stay click-through at all times; they only display
            // ink, never capture input.
            overlay.panel.orderFront(nil)
        }

        startSampling()
    }

    /// Hide the overlays and return the stroke's bounding box in global
    /// AppKit coordinates, or nil if the user didn't actually draw.
    @discardableResult
    func end() -> CGRect? {
        guard isActive else { return nil }
        isActive = false
        sessionGeneration += 1
        let generation = sessionGeneration

        sampleTimer?.invalidate()
        sampleTimer = nil

        let rect = boundingRect()
        TalkHotkeyMonitor.diag("overlay end(), points=\(globalPoints.count) rect=\(rect.map { NSStringFromRect($0) } ?? "nil")")

        for overlay in overlays.values {
            overlay.contentView.isCapturing = false
            // Dormant again: clicks pass straight through to the app below.
            overlay.panel.ignoresMouseEvents = true
        }

        // Fade the ink out, then hide and clear. The panels are NEVER
        // destroyed — only ordered out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            for overlay in overlays.values {
                overlay.panel.animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            guard let self = self, self.sessionGeneration == generation else { return }
            for overlay in self.overlays.values {
                overlay.panel.orderOut(nil)
                overlay.panel.alphaValue = 1
                overlay.model.reset()
            }
        }

        globalPoints.removeAll()
        owningScreenFrame = nil
        return rect
    }

    // MARK: - Geometry

    /// Bounding box of the GLOBAL points, padded and clamped to the screen
    /// the stroke started on. `intersection` does the clamping correctly for
    /// screens at negative or non-zero origins — no min/max on raw numbers.
    private func boundingRect() -> CGRect? {
        guard globalPoints.count >= Self.minimumPoints,
              let screenFrame = owningScreenFrame else { return nil }

        var minX = globalPoints[0].x
        var maxX = globalPoints[0].x
        var minY = globalPoints[0].y
        var maxY = globalPoints[0].y
        for point in globalPoints.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let stroke = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // Second line of defence behind the movement gate: never let the
        // padding inflate a degenerate stroke into a believable rect.
        guard max(stroke.width, stroke.height) >= Self.minimumStrokeSpan else { return nil }
        let padded = stroke.insetBy(dx: -Self.padding, dy: -Self.padding)
        let clamped = padded.intersection(screenFrame)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }

    // MARK: - Sampling

    private func startSampling() {
        sampleTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.sampleTick()
        }
        // .common so sampling survives menu tracking / scrolling.
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func sampleTick() {
        guard isActive else { return }

        // TEMP DIAGNOSTIC (remove with the other TALK diag lines): trace the
        // first ticks of each session so the log shows which gate blocks.
        diagTickCount += 1
        if diagTickCount <= 10 {
            let flags = NSEvent.modifierFlags
            TalkHotkeyMonitor.diag("tick \(diagTickCount): ctrl=\(flags.contains(.control)) opt=\(flags.contains(.option)) button=\(NSEvent.pressedMouseButtons & 1) mouse=\(NSStringFromPoint(NSEvent.mouseLocation)) overlayHit=\(overlay(containing: NSEvent.mouseLocation) != nil) points=\(globalPoints.count)")
        }

        // SELF-HEAL (debounced). While active, every display is covered by a
        // transparent panel that swallows clicks. If the paired onRelease is
        // ever lost — event tap disabled, fast user switch, Space
        // transition, app suspended mid-hold — nothing else would ever take
        // those panels down, leaving a Mac where no click registers
        // anywhere. But healing on the FIRST absent tick would steal the
        // session from the normal release path, which always arrives a
        // little later; hence the grace run. See `selfHealGraceTicks`.
        if NSEvent.modifierFlags.contains([.control, .option]) {
            modifiersAbsentTicks = 0
        } else {
            modifiersAbsentTicks += 1
            if modifiersAbsentTicks >= Self.selfHealGraceTicks { end() }
            // Either way, stop sampling — the user has let go.
            return
        }

        let global = NSEvent.mouseLocation
        guard let overlay = overlay(containing: global) else { return }

        // Ink must agree with the rect. The returned rect is clipped to the
        // screen the stroke STARTED on, so refuse samples from any other
        // display rather than drawing teal ink that is silently discarded —
        // the stroke visibly stops at the real capture boundary.
        if let owning = owningScreenFrame {
            guard overlay.screenFrame == owning else { return }
        } else {
            owningScreenFrame = overlay.screenFrame
        }

        // Movement gate — see `minimumMovement`.
        if let previous = globalPoints.last {
            let dx = global.x - previous.x
            let dy = global.y - previous.y
            guard dx * dx + dy * dy >= Self.minimumMovement * Self.minimumMovement else { return }
        }

        globalPoints.append(global)

        // AppKit global space is bottom-left origin; the SwiftUI Canvas is
        // top-left origin and starts at the panel's own (0,0).
        let local = CGPoint(
            x: global.x - overlay.screenFrame.minX,
            y: overlay.screenFrame.maxY - global.y
        )
        overlay.model.points.append(local)
    }

    /// The overlay whose display contains `global`. Iterates in
    /// `NSScreen.screens` order — dictionary order is unspecified, which on
    /// mirrored or overlapping displays would resolve a boundary point
    /// differently from run to run.
    ///
    /// Exact containment first. `NSRect.contains` excludes the max edges, and
    /// macOS pins the cursor to exactly `frame.maxY` when it is slammed
    /// against the top of a display — hence the 1pt-slack second pass.
    private func overlay(containing global: CGPoint) -> ScreenOverlay? {
        let ordered = NSScreen.screens.compactMap { screen -> ScreenOverlay? in
            guard let id = Self.displayID(of: screen) else { return nil }
            return overlays[id]
        }
        return ordered.first { NSPointInRect(global, $0.screenFrame) }
            ?? ordered.first { $0.screenFrame.insetBy(dx: -1, dy: -1).contains(global) }
    }

    // MARK: - Panels

    /// Create any missing panel, refresh every panel's frame to the current
    /// display layout, and drop panels whose display is gone. Panels for
    /// LIVE displays are reused, never rebuilt.
    private func syncPanels() {
        var live: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            live.insert(id)
            if let existing = overlays[id] {
                existing.screenFrame = screen.frame
                existing.panel.setFrame(screen.frame, display: false)
            } else {
                overlays[id] = makeOverlay(for: screen)
            }
        }

        // Prune orphans. A panel for a disconnected display keeps a frame
        // that matches no real screen; AppKit would constrain it onto a
        // surviving display where begin()'s loop makes it a second,
        // invisible click-eating surface.
        for (id, overlay) in overlays where !live.contains(id) {
            overlay.contentView.isCapturing = false
            overlay.panel.ignoresMouseEvents = true
            // close(), not just orderOut(): orderOut leaves the window in the
            // application's window list, and isReleasedWhenClosed = false
            // means dropping the dictionary reference alone would strand the
            // panel alive — unreachable for reuse and accumulating across
            // dock/undock cycles.
            overlay.panel.close()
            overlays.removeValue(forKey: id)
        }
    }

    private func makeOverlay(for screen: NSScreen) -> ScreenOverlay {
        let panel = CircleOverlayPanel(contentRect: screen.frame)
        let model = StrokeModel()

        let hosting = NSHostingView(rootView: CircleOverlayView(model: model))
        // DO-NOT-REGRESS: a notched screen reports a top safe-area inset,
        // which would push the canvas down and skew every drawn point.
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]

        let content = OverlayContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
        hosting.frame = content.bounds
        content.addSubview(hosting)
        panel.contentView = content

        panel.setFrame(screen.frame, display: false)
        // Pre-warm the view tree so the first stroke pays nothing.
        content.layoutSubtreeIfNeeded()

        return ScreenOverlay(
            panel: panel,
            model: model,
            contentView: content,
            screenFrame: screen.frame
        )
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

// MARK: - Supporting types

private final class ScreenOverlay {
    let panel: CircleOverlayPanel
    let model: StrokeModel
    let contentView: OverlayContentView
    var screenFrame: NSRect

    init(panel: CircleOverlayPanel,
         model: StrokeModel,
         contentView: OverlayContentView,
         screenFrame: NSRect) {
        self.panel = panel
        self.model = model
        self.contentView = contentView
        self.screenFrame = screenFrame
    }
}

/// The panel's content view. `ignoresMouseEvents = false` alone is not
/// enough to stop a drag reaching the app underneath: if hit-testing returns
/// nil AppKit keeps looking down the window list. So this view claims the
/// hit while a session is active — and refuses it while dormant, which is
/// belt-and-braces with `ignoresMouseEvents = true`. It handles no events;
/// claiming the hit is the entire job.
private final class OverlayContentView: NSView {
    var isCapturing = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isCapturing else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }
}

/// Transparent full-screen panel above everything, which never takes focus.
private final class CircleOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        // Dormant by default — clicks pass through until begin() flips it.
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
