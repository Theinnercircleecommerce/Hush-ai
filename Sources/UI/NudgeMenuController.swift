import Cocoa
import Combine
import SwiftUI

/// Hover-over-the-notch → menu panel. Owns an invisible mouse-accepting
/// "catcher" strip over the notch/pill zone per screen, and one shared
/// menu panel that springs open beneath the notch of the hovered screen.
final class NudgeMenuController {
    static let shared = NudgeMenuController()

    private(set) var isOpen = false
    private var catchers: [HoverCatcherPanel] = []
    private var menuPanel: KeyableMenuPanel?
    private var clickOutsideMonitor: Any?
    private weak var appState: AppState?

    private init() {}

    private var stateCancellable: AnyCancellable?

    func attach(appState: AppState) {
        self.appState = appState
        // Auto-close the panel the moment dictation starts.
        stateCancellable = appState.$hudState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state != .idle { self?.close() }
            }
        rebuildCatchers()
    }

    func rebuildCatchers() {
        for catcher in catchers { catcher.close() }
        catchers.removeAll()

        for screen in NSScreen.screens {
            let metrics = NotchMetrics.metrics(for: screen)
            // Zone = idle shelf on notched screens; pill zone on others.
            let zoneWidth: CGFloat = metrics.hasNotch ? metrics.notchWidth + 72 : 260
            let zoneHeight: CGFloat = metrics.hasNotch ? metrics.notchHeight + 1 : 16
            let rect = NSRect(
                x: screen.frame.midX - zoneWidth / 2,
                y: screen.frame.maxY - zoneHeight,
                width: zoneWidth,
                height: zoneHeight
            )
            let catcher = HoverCatcherPanel(zone: rect, screen: screen)
            catcher.onHover = { [weak self] hoveredScreen in
                self?.open(on: hoveredScreen)
            }
            catcher.orderFront(nil)
            catchers.append(catcher)
        }
    }

    func open(on screen: NSScreen) {
        guard !isOpen else { return }
        guard let appState = appState else { return }
        // Never open while the nudge is busy showing dictation state.
        if appState.hudState != .idle { return }
        isOpen = true

        let panel = KeyableMenuPanel()
        let hosting = NSHostingView(
            rootView: NudgeMenuView(
                appState: appState,
                onClose: { [weak self] in self?.close() }
            )
        )
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        let metrics = NotchMetrics.metrics(for: screen)
        let size = NudgeMenuLayout.homeSize
        let topY = screen.frame.maxY - (metrics.hasNotch ? 0 : 4)
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: topY - size.height,
                   width: size.width, height: size.height),
            display: false
        )
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        menuPanel = panel
        installClickOutsideMonitor()
    }

    func close() {
        guard isOpen, let panel = menuPanel else { return }
        isOpen = false
        removeClickOutsideMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
        menuPanel = nil
    }

    /// Called by NudgeMenuView when switching Home <-> Settings.
    func resize(to size: CGSize) {
        guard let panel = menuPanel, let screen = panel.screen ?? NSScreen.main else { return }
        let metrics = NotchMetrics.metrics(for: screen)
        let topY = screen.frame.maxY - (metrics.hasNotch ? 0 : 4)
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
    static let homeSize = CGSize(width: 510, height: 260)
    static let settingsSize = CGSize(width: 510, height: 640)
}

/// Invisible strip over the notch/pill zone that only exists to receive
/// mouse-entered events. The notch zone has no clickable system UI, so
/// intercepting the mouse here is safe.
final class HoverCatcherPanel: NSPanel {
    var onHover: ((NSScreen) -> Void)?
    private let targetScreen: NSScreen

    init(zone: NSRect, screen: NSScreen) {
        self.targetScreen = screen
        super.init(contentRect: zone,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let tracker = HoverTrackerView(frame: NSRect(origin: .zero, size: zone.size))
        tracker.onEntered = { [weak self] in
            guard let self = self else { return }
            self.onHover?(self.targetScreen)
        }
        contentView = tracker
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverTrackerView: NSView {
    var onEntered: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }
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

// Placeholder — replaced by NudgeMenuView.swift in Task 2
struct NudgeMenuView: View {
    @ObservedObject var appState: AppState
    var onClose: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color.black.opacity(0.96))
            .overlay(Text("menu placeholder").foregroundColor(.white))
    }
}
