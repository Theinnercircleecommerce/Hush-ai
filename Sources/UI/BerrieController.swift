import Cocoa
import SwiftUI

/// Where Berrie sits. Pure so it's testable; AppKit global coordinates
/// (bottom-left origin). Saved as "x,y" in UserDefaults.
enum BerriePosition {
    static let defaultsKey = "berriePosition"
    static let inset: CGFloat = 24

    static func resolve(saved: CGPoint?, size: CGSize, screens: [CGRect]) -> CGPoint {
        if let saved {
            let rect = CGRect(origin: saved, size: size)
            // Mostly on some screen — a sliver off the edge is fine.
            if screens.contains(where: { $0.intersection(rect).width >= size.width / 2
                                        && $0.intersection(rect).height >= size.height / 2 }) {
                return saved
            }
        }
        let first = screens.first ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return CGPoint(x: first.maxX - size.width - inset, y: first.minY + inset)
    }

    static func string(from point: CGPoint) -> String { "\(point.x),\(point.y)" }

    static func point(from string: String?) -> CGPoint? {
        guard let string else { return nil }
        let parts = string.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }
}

/// The floating character: one borderless, non-activating panel that floats
/// above every app, on every Space. Drag to move (remembered), click for a
/// small menu.
@MainActor
final class BerrieController {
    static let shared = BerrieController()

    /// Berrie plus room for a one-line error caption below him.
    static let panelSize = CGSize(width: 220, height: BerrieView.size + 30)

    private var panel: BerriePanel?
    private weak var appState: AppState?

    var panelWindows: [NSWindow] { panel.map { [$0] } ?? [] }
    var panelFrame: NSRect? { panel?.frame }

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show(appState: AppState) {
        self.appState = appState
        if panel == nil { panel = makePanel(appState: appState) }
        place()
        panel?.orderFront(nil)
    }

    private func makePanel(appState: AppState) -> BerriePanel {
        let panel = BerriePanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        let container = BerrieClickView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.onClick = { [weak self] event in self?.showMenu(for: event, in: container) }
        container.onMoved = { origin in
            UserDefaults.standard.set(BerriePosition.string(from: origin), forKey: BerriePosition.defaultsKey)
        }
        let hosting = PassThroughHostingView(rootView: BerrieView(appState: appState))
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        return panel
    }

    private func place() {
        guard let panel else { return }
        let saved = BerriePosition.point(from: UserDefaults.standard.string(forKey: BerriePosition.defaultsKey))
        let origin = BerriePosition.resolve(saved: saved, size: Self.panelSize,
                                            screens: NSScreen.screens.map { $0.visibleFrame })
        panel.setFrameOrigin(origin)
    }

    @objc private func screensChanged() { place() }

    private func showMenu(for event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Ask Berrie…", action: #selector(askTyped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Berrie", action: #selector(quit), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }

    @objc private func askTyped() {
        BerrieAskController.shared.show(near: panel?.frame)
    }

    @objc private func openSettings() {
        let screen = panel?.screen ?? NSScreen.main
        if let screen { NudgeMenuController.shared.open(on: screen) }
    }

    @objc private func checkForUpdates() {
        AppDelegate.shared.updaterController.checkForUpdates(nil)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// Click vs drag, tracked by hand: `performDrag(with:)` hands off to the
/// window server and returns before the mouse moves on a non-activating
/// panel, so every press read as a click. Moving the window ourselves on
/// mouseDragged is deterministic.
final class BerrieClickView: NSView {
    var onClick: ((NSEvent) -> Void)?
    var onMoved: ((CGPoint) -> Void)?

    private var downMouse: NSPoint?
    private var downOrigin: NSPoint?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downMouse = NSEvent.mouseLocation
        downOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let downMouse, let downOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - downMouse.x, dy = now.y - downMouse.y
        if !dragged, hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { downMouse = nil; downOrigin = nil; dragged = false }
        if dragged, let window {
            onMoved?(window.frame.origin)
        } else {
            onClick?(event)
        }
    }
}

/// Lets mouse events fall through to the click view underneath.
final class PassThroughHostingView: NSHostingView<BerrieView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class BerriePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false   // BerrieClickView moves it by hand
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
