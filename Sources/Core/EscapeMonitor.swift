import Cocoa

/// Esc during a hold drops it: overlay down, mic closed, nothing pasted,
/// nothing asked. Observe-only NSEvent monitors, same as TalkHotkeyMonitor.
final class EscapeMonitor {
    static let shared = EscapeMonitor()

    var onEscape: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    static func isEscape(keyCode: UInt16) -> Bool { keyCode == 53 }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard Self.isEscape(keyCode: event.keyCode) else { return }
        DispatchQueue.main.async { [weak self] in self?.onEscape?() }
    }
}
