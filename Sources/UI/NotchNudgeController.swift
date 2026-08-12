import Cocoa
import SwiftUI

/// Owns one transparent, click-through panel per screen, pinned top-center
/// above the menu bar. Replaces HUDWindowController.
final class NotchNudgeController {
    static let shared = NotchNudgeController()

    private var panels: [NSPanel] = []
    private weak var appState: AppState?

    /// The nudge panels, for excluding Hush's own windows from screen capture
    /// (TalkSession's hushWindows). Read-only.
    var panelWindows: [NSWindow] { panels }

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
            let hosting = NSHostingView(
                rootView: NudgeView(appState: appState, metrics: metrics)
            )
            // The notched screen reports a top safe-area inset; without this
            // the hosting view pushes all content below the hardware notch.
            hosting.safeAreaRegions = []
            panel.contentView = hosting

            let x = screen.frame.midX - NudgeLayout.containerWidth / 2
            let y = screen.frame.maxY - NudgeLayout.containerHeight
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.orderFront(nil)
            panels.append(panel)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let line = "NUDGE-GEO panel=\(NSStringFromRect(panel.frame)) screenMaxY=\(screen.frame.maxY) hostingSafeArea=\(hosting.safeAreaInsets) notchW=\(metrics.notchWidth) notchH=\(metrics.notchHeight) menuBar=\(metrics.menuBarHeight) expansionH=\(metrics.expansionHeight)\n"
                if let data = line.data(using: .utf8) {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("hush-nudge-geo.log")
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    } else {
                        try? data.write(to: url)
                    }
                }
            }
        }
        NudgeMenuController.shared.attach(appState: appState)
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
