import Cocoa
import Combine
import SwiftUI

/// Hover-over-the-notch → menu panel. Owns an invisible mouse-accepting
/// "catcher" strip over the notch/pill zone per screen, and one shared
/// menu panel that springs open beneath the notch of the hovered screen.
final class NudgeMenuController {
    static let shared = NudgeMenuController()

    private(set) var isOpen = false
    private var menuPanel: KeyableMenuPanel?
    private var clickOutsideMonitor: Any?
    private weak var appState: AppState?

    private init() {}

    private var stateCancellable: AnyCancellable?
    private var hoverTimer: Timer?
    private var outsideTicks = 0
    /// Screen the panel was opened on — the panel is reused, so its own
    /// `screen` is unreliable while it is ordered out or mid-animation.
    private var openScreen: NSScreen?
    /// Bumped on every close AND every open. The close animation's
    /// completion handler only hides the panel if its generation is still
    /// current — otherwise a re-hover during the shrink would be undone by
    /// the stale completion, stranding the panel hidden with isOpen == true.
    private var closeGeneration = 0

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
    /// only has to reposition and animate.
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

        // Pre-warm: lay out the full view tree now (both tabs are mounted),
        // so the first hover and first gear press pay nothing.
        panel.setFrame(
            NSRect(origin: .zero, size: NudgeMenuLayout.settingsSize),
            display: false
        )
        hosting.layoutSubtreeIfNeeded()
        panel.setFrame(
            NSRect(origin: .zero, size: NudgeMenuLayout.homeSize),
            display: false
        )
        hosting.layoutSubtreeIfNeeded()

        menuPanel = panel
    }

    private func startHoverMonitoring() {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.hoverTick()
        }
        // .common so the poll keeps running while menus/scrolling are active.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// The strip that counts as "hovering the notch": full notch width +
    /// shelf wings, plus a few points below the notch line so the target
    /// is reachable even though macOS nudges the cursor out of the notch.
    private func hoverZone(for screen: NSScreen) -> NSRect {
        let metrics = NotchMetrics.metrics(for: screen)
        let width: CGFloat = metrics.hasNotch ? metrics.notchWidth + 72 : 260
        let height: CGFloat = metrics.hasNotch ? metrics.notchHeight + 6 : 20
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func hoverTick() {
        guard let appState = appState else { return }

        // Self-heal: if state says open but the panel is not visible,
        // reset so the next hover can open. (Guards against any future
        // desync of the same class as the close-animation race.)
        if isOpen, let panel = menuPanel, !panel.isVisible {
            isOpen = false
            removeClickOutsideMonitor()
        }

        let mouse = NSEvent.mouseLocation

        if !isOpen {
            guard appState.hudState == .idle else { return }
            for screen in NSScreen.screens where hoverZone(for: screen).contains(mouse) {
                open(on: screen)
                return
            }
        } else if let panel = menuPanel {
            let nearPanel = panel.frame.insetBy(dx: -8, dy: -8).contains(mouse)
            let inZone = NSScreen.screens.contains { hoverZone(for: $0).contains(mouse) }
            if nearPanel || inZone {
                outsideTicks = 0
            } else {
                outsideTicks += 1
                if outsideTicks >= 4 {   // ~0.4s away → close
                    outsideTicks = 0
                    close()
                }
            }
        }
    }

    func open(on screen: NSScreen) {
        guard !isOpen else { return }
        guard let appState = appState, let panel = menuPanel else { return }
        // Never open while the nudge is busy showing dictation state.
        if appState.hudState != .idle { return }
        isOpen = true
        openScreen = screen
        closeGeneration += 1   // invalidate any in-flight close completion
        NotificationCenter.default.post(
            name: Notification.Name("NudgeMenuWillOpen"), object: nil)

        let size = NudgeMenuLayout.homeSize
        let topY = screen.frame.maxY

        // Start collapsed at the notch-shelf footprint, spring out to full.
        let startFrame = Self.shelfFrame(for: screen)
        let endFrame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: topY - size.height,
            width: size.width, height: size.height
        )
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 1
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(endFrame, display: true)
        }
        installClickOutsideMonitor()
    }

    /// Collapsed footprint the panel grows out of / shrinks back into.
    private static func shelfFrame(for screen: NSScreen) -> NSRect {
        let metrics = NotchMetrics.metrics(for: screen)
        let topY = screen.frame.maxY
        let width: CGFloat = metrics.hasNotch ? metrics.notchWidth + 72 : 260
        let height: CGFloat = metrics.hasNotch ? metrics.notchHeight + 1 : 16
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: topY - height,
            width: width, height: height
        )
    }

    func close() {
        guard isOpen, let panel = menuPanel else { return }
        isOpen = false
        removeClickOutsideMonitor()
        closeGeneration += 1
        let generation = closeGeneration

        guard let screen = openScreen ?? panel.screen ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }
        let collapsed = Self.shelfFrame(for: screen)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(collapsed, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self,
                  self.closeGeneration == generation,
                  !self.isOpen else { return }   // a reopen happened — do NOT hide
            panel.orderOut(nil)
        })
        // menuPanel stays set — the panel is reused on the next open.
    }

    /// Called by NudgeMenuView when switching Home <-> Settings.
    func resize(to size: CGSize) {
        guard let panel = menuPanel,
              let screen = openScreen ?? panel.screen ?? NSScreen.main else { return }
        let topY = screen.frame.maxY
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: topY - size.height,
                           width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func installClickOutsideMonitor() {
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
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

enum NudgeMenuLayout {
    static let homeSize = CGSize(width: 510, height: 380)
    static let settingsSize = CGSize(width: 510, height: 640)
    static let subpageSize = CGSize(width: 510, height: 560)
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
