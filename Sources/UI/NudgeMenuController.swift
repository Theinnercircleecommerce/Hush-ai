import Cocoa
import Combine
import SwiftUI

/// Hover-over-the-notch → menu panel. Polls the mouse position; when it
/// dwells on the notch (or the pill on a notchless screen) the shared menu
/// panel springs open beneath it.
///
/// The panel WINDOW is fixed-size and never animates — every grow/shrink
/// is a SwiftUI spring inside NudgeMenuView. Animating an NSPanel frame
/// with live SwiftUI content re-layouts the whole tree per frame on the
/// main thread and stutters; content-side animation does not.
final class NudgeMenuController {
    static let shared = NudgeMenuController()

    private(set) var isOpen = false
    private var menuPanel: KeyableMenuPanel?

    /// The menu panel, for excluding Hush's own windows from screen capture
    /// (TalkSession's hushWindows). Read-only.
    var panelWindows: [NSWindow] { menuPanel.map { [$0] } ?? [] }

    private var clickOutsideMonitor: Any?
    private var localClickMonitor: Any?
    private weak var appState: AppState?

    private init() {}

    private var stateCancellable: AnyCancellable?
    private var hoverTimer: Timer?
    private var outsideTicks = 0
    /// Screen the panel was opened on — the panel is reused, so its own
    /// `screen` is unreliable while it is ordered out.
    private var openScreen: NSScreen?
    /// Bumped on every open AND close so the delayed orderOut after a close
    /// is skipped if a reopen happened in the meantime (otherwise the stale
    /// hide strands the panel invisible with isOpen == true).
    private var closeGeneration = 0
    /// The page size the CONTENT currently occupies (the window is bigger).
    /// Drives the mouse-out rect and the dead-zone click check.
    private var currentPageSize = NudgeMenuLayout.homeSize
    /// Consecutive poll ticks the mouse has been inside a hover zone while
    /// closed. Opening requires 2 (~0.1s) so flicking the cursor THROUGH
    /// the zone on the way somewhere else doesn't trigger the panel.
    private var dwellTicks = 0

    func attach(appState: AppState) {
        self.appState = appState
        // Auto-close the panel the moment dictation starts.
        stateCancellable = appState.$hudState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state != .idle { self?.close() }
            }
        makePanel(appState: appState)
        startHoverMonitoring()
    }

    /// Built once, kept alive forever. Creating the panel + hosting view is
    /// what made the first hover stutter; doing it up front means open()
    /// only has to reposition and order front.
    private func makePanel(appState: AppState) {
        guard menuPanel == nil else { return }
        let panel = KeyableMenuPanel()
        let hosting = NSHostingView(
            rootView: NudgeMenuView(
                appState: appState,
                onClose: { [weak self] in self?.close() }
            )
        )
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        // Pre-warm: lay out the full view tree now (all pages are mounted),
        // so the first hover pays nothing.
        panel.setFrame(
            NSRect(origin: .zero, size: NudgeMenuLayout.panelSize),
            display: false
        )
        hosting.layoutSubtreeIfNeeded()

        menuPanel = panel
    }

    private func startHoverMonitoring() {
        hoverTimer?.invalidate()
        // 20 Hz — a 10 Hz poll can miss a fast flick through the zone.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.hoverTick()
        }
        // .common so the poll keeps running while menus/scrolling are active.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// The strip that counts as "hovering the notch" — sized to the VISIBLE
    /// target only: the hardware notch, or the pill on a notchless screen.
    private func hoverZone(for screen: NSScreen) -> NSRect {
        let metrics = NotchMetrics.metrics(for: screen)
        let width: CGFloat = metrics.hasNotch ? metrics.notchWidth + 8 : 188
        let height: CGFloat = metrics.hasNotch ? metrics.notchHeight : 16
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// NSRect.contains EXCLUDES the max edge — but when the cursor is
    /// shoved against the top of the topmost display, macOS pins
    /// mouseLocation.y at exactly screen.frame.maxY. That made the pill
    /// zone unhittable by the natural gesture (slam cursor to the top).
    /// Top edge must be inclusive, with a point of slack.
    private func zoneContains(_ mouse: NSPoint, for screen: NSScreen) -> Bool {
        let zone = hoverZone(for: screen)
        return mouse.x >= zone.minX && mouse.x <= zone.maxX
            && mouse.y >= zone.minY && mouse.y <= zone.maxY + 1
    }

    /// Screen rect the CONTENT visually occupies right now (window is
    /// fixed-size and bigger; the visible part is top-centered inside it).
    private func visibleRect() -> NSRect? {
        guard let screen = openScreen else { return nil }
        return NSRect(
            x: screen.frame.midX - currentPageSize.width / 2,
            y: screen.frame.maxY - currentPageSize.height,
            width: currentPageSize.width,
            height: currentPageSize.height
        )
    }

    private func hoverTick() {
        guard let appState = appState else { return }

        // Self-heal: state says open but the panel was hidden out from
        // under us — reset so the next hover can open.
        if isOpen, let panel = menuPanel, !panel.isVisible {
            isOpen = false
            removeClickOutsideMonitor()
            Self.log("HEAL hidden-while-open → isOpen=false")
        }

        let mouse = NSEvent.mouseLocation

        if !isOpen {
            guard appState.hudState == .idle else {
                if NSScreen.screens.contains(where: { zoneContains(mouse, for: $0) }) {
                    Self.log("BLOCKED hover in zone but hudState=\(appState.hudState)")
                }
                return
            }
            if let screen = NSScreen.screens.first(where: { zoneContains(mouse, for: $0) }) {
                dwellTicks += 1
                if dwellTicks >= 2 {   // ~0.1s on target — not a drive-by
                    dwellTicks = 0
                    open(on: screen)
                }
            } else {
                dwellTicks = 0
            }
        } else {
            let nearPanel = visibleRect()?.insetBy(dx: -8, dy: -8).contains(mouse) ?? false
            let inZone = NSScreen.screens.contains { zoneContains(mouse, for: $0) }
            if nearPanel || inZone {
                outsideTicks = 0
            } else {
                outsideTicks += 1
                if outsideTicks >= 8 {   // ~0.4s away → close
                    outsideTicks = 0
                    close()
                }
            }
        }
    }

    /// Diagnostic trail — read with:
    /// `tail -20 "$(getconf DARWIN_USER_TEMP_DIR)/hush-hover.log"`
    private static func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hush-hover.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func open(on screen: NSScreen) {
        guard !isOpen else { return }
        guard let appState = appState, let panel = menuPanel else { return }
        // Never open while the nudge is busy showing dictation state.
        if appState.hudState != .idle { return }
        isOpen = true
        openScreen = screen
        closeGeneration += 1   // invalidate any pending close hide
        currentPageSize = NudgeMenuLayout.homeSize

        // Fixed-size window pinned top-center; never animated.
        let size = NudgeMenuLayout.panelSize
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: screen.frame.maxY - size.height,
                   width: size.width, height: size.height),
            display: false
        )

        // Tell the view to reset collapsed at this screen's shelf size —
        // BEFORE the window shows, so no expanded flash — then order front.
        // The view springs itself open on the next runloop pass.
        let shelf = Self.shelfSize(for: screen)
        NotificationCenter.default.post(
            name: Notification.Name("NudgeMenuWillOpen"), object: nil,
            userInfo: ["width": shelf.width, "height": shelf.height]
        )
        panel.alphaValue = 1
        panel.orderFront(nil)
        installClickOutsideMonitor()
    }

    /// Collapsed footprint the content springs out of / shrinks back into.
    private static func shelfSize(for screen: NSScreen) -> CGSize {
        let metrics = NotchMetrics.metrics(for: screen)
        return CGSize(
            width: metrics.hasNotch ? metrics.notchWidth + 72 : 260,
            height: metrics.hasNotch ? metrics.notchHeight + 1 : 16
        )
    }

    func close() {
        guard isOpen, menuPanel != nil else { return }
        isOpen = false
        removeClickOutsideMonitor()
        closeGeneration += 1
        let generation = closeGeneration

        // Content collapses via SwiftUI (0.2s); hide the window just after.
        NotificationCenter.default.post(
            name: Notification.Name("NudgeMenuWillClose"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self = self,
                  self.closeGeneration == generation,
                  !self.isOpen else { return }   // a reopen happened — do NOT hide
            self.menuPanel?.orderOut(nil)
        }
        // menuPanel stays set — the panel is reused on the next open.
    }

    /// Called by NudgeMenuView on page switches. The window never moves;
    /// this only records the content size for hover/click hit-testing.
    func resize(to size: CGSize) {
        currentPageSize = size
    }

    private func installClickOutsideMonitor() {
        // Clicks in OTHER apps: global monitor (never sees our own clicks).
        // Grace delay so opening-click / permission dialogs aren't caught
        // (farzaa-clicky pattern).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isOpen else { return }
            self.clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.close()
            }
        }
        // Clicks in OUR window but in the transparent dead zone below the
        // visible content (window is fixed at max size): also outside.
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if let self = self, self.isOpen,
               let rect = self.visibleRect(),
               !rect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
                self.close()
            }
            return event
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }
}

enum NudgeMenuLayout {
    /// Fixed window size — big enough for the largest page.
    /// Width bumped to 580 so the Home/Agents tab group ends at ~164pt (left
    /// edge of the 179pt notch occluded strip starts at ~200pt) and the gear
    /// starts at ~548pt (right edge of strip ends at ~380pt). Both clear by
    /// ≥36pt.
    static let panelSize = CGSize(width: 580, height: 640)
    static let homeSize = CGSize(width: 580, height: 248)
    static let settingsSize = CGSize(width: 580, height: 640)
    static let subpageSize = CGSize(width: 580, height: 560)
}

/// Non-activating but key-capable, so the shortcut recorder and text
/// fields inside the menu work without activating Hush.
final class KeyableMenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
