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

    /// Fewer points than this means the user held the hotkey without really
    /// drawing (a stray click, a twitch) — treat it as "no circle".
    private static let minimumPoints = 5
    /// Breathing room around the stroke so the crop includes what was ringed,
    /// not just the ink.
    private static let padding: CGFloat = 12
    private static let fadeDuration: TimeInterval = 0.25

    private init() {}

    // MARK: - Session

    /// Show the overlays and start sampling the cursor.
    func begin() {
        guard !isActive else { return }
        isActive = true
        sessionGeneration += 1

        globalPoints.removeAll()
        owningScreenFrame = nil

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
            overlay.contentView.isCapturing = true
            // Capture the drag so it draws instead of ALSO dragging /
            // selecting content in the app underneath.
            overlay.panel.ignoresMouseEvents = false
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
        // Only draw while the primary button is down — hovering with the
        // hotkey held draws nothing.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }

        let global = NSEvent.mouseLocation
        // Exact containment first. NSRect.contains excludes the max edges,
        // and macOS pins the cursor to exactly frame.maxY when it's slammed
        // against the top of a display — hence the 1pt-slack fallback.
        let overlayForPoint = overlays.values.first { NSPointInRect(global, $0.screenFrame) }
            ?? overlays.values.first { $0.screenFrame.insetBy(dx: -1, dy: -1).contains(global) }
        guard let overlay = overlayForPoint else { return }

        if owningScreenFrame == nil { owningScreenFrame = overlay.screenFrame }
        globalPoints.append(global)

        // AppKit global space is bottom-left origin; the SwiftUI Canvas is
        // top-left origin and starts at the panel's own (0,0).
        let local = CGPoint(
            x: global.x - overlay.screenFrame.minX,
            y: overlay.screenFrame.maxY - global.y
        )
        overlay.model.points.append(local)
    }

    // MARK: - Panels

    /// Create any missing panel and refresh every panel's frame to the
    /// current display layout. Existing panels are reused, never rebuilt;
    /// panels for displays that went away simply stay hidden.
    private func syncPanels() {
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            if let existing = overlays[id] {
                existing.screenFrame = screen.frame
                existing.panel.setFrame(screen.frame, display: false)
            } else {
                overlays[id] = makeOverlay(for: screen)
            }
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
