import Cocoa
import SwiftUI

/// Owns one transparent, click-through panel per screen, pinned top-center
/// above the menu bar. Replaces HUDWindowController.
final class NotchNudgeController {
    static let shared = NotchNudgeController()

    private var panels: [NSPanel] = []
    private weak var appState: AppState?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildPanels),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show(appState: AppState) {
        self.appState = appState
        rebuildPanels()
    }

    @objc private func rebuildPanels() {
        guard let appState = appState else { return }

        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()

        for screen in NSScreen.screens {
            let metrics = NotchMetrics.metrics(for: screen)
            let panel = NudgePanel(
                contentRect: NSRect(
                    x: 0, y: 0,
                    width: NudgeLayout.containerWidth,
                    height: NudgeLayout.containerHeight
                )
            )
            panel.contentView = NSHostingView(
                rootView: NudgeView(appState: appState, metrics: metrics)
            )

            let x = screen.frame.midX - NudgeLayout.containerWidth / 2
            let y = screen.frame.maxY - NudgeLayout.containerHeight
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.orderFront(nil)
            panels.append(panel)
        }
    }
}

private final class NudgePanel: NSPanel {
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
        ignoresMouseEvents = true
        // Above the menu bar so the expansion visually merges with the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
