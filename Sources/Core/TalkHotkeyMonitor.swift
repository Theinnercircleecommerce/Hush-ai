import Cocoa

/// Hold-to-talk monitor for modifier-only combos (⌃⌥), which
/// KeyboardShortcuts can't express. Listen-only tap: never swallows events.
final class TalkHotkeyMonitor {
    static let shared = TalkHotkeyMonitor()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var isDown = false

    private init() {}

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<TalkHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                switch type {
                case .tapDisabledByTimeout:
                    NSLog("Hush: talk event tap re-enabled after tapDisabledByTimeout")
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                case .tapDisabledByUserInput:
                    NSLog("Hush: talk event tap re-enabled after tapDisabledByUserInput")
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                case .flagsChanged:
                    monitor.handle(flags: event.flags)
                default:
                    break
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Hush: talk hotkey tap could not be created (accessibility permission?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(flags: CGEventFlags) {
        let held = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        if held, !isDown {
            isDown = true
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if !held, isDown {
            isDown = false
            DispatchQueue.main.async { [weak self] in self?.onRelease?() }
        }
    }
}
