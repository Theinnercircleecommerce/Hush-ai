import Cocoa

/// Hold-to-talk monitor for modifier-only combos (⌃⌥), which
/// KeyboardShortcuts can't express.
///
/// Uses NSEvent global+local monitors rather than a CGEvent tap: listen-only
/// taps are gated behind the Input Monitoring permission, which Hush does not
/// request. NSEvent monitors for flagsChanged deliver with Accessibility
/// trust alone (verified empirically: the tap received zero events with
/// Accessibility granted and Input Monitoring denied; monitors receive them).
/// Monitors are observe-only by design, so they can never swallow keystrokes.
final class TalkHotkeyMonitor {
    static let shared = TalkHotkeyMonitor()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    private init() {}

    /// TEMP DIAGNOSTIC (remove after the ⌃⌥ permission issue is resolved).
    /// Unified logging shows nothing for this ad-hoc-signed bundle, so mirror
    /// the NUDGE-GEO approach and append to a temp file instead.
    static func diag(_ message: String) {
        let line = "TALK \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hush-talk.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func start() {
        guard globalMonitor == nil else {
            Self.diag("start() called again, monitors already exist")
            return
        }
        Self.diag("start() called; AXIsProcessTrusted=\(AXIsProcessTrusted())")

        // Global monitor: fires while OTHER apps are focused (the normal case
        // for a menu-bar app). Local monitor: fires while Hush itself is key
        // (e.g. the nudge menu panel is open); global monitors don't receive
        // those events. The local monitor must return the event unchanged so
        // nothing is swallowed.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: event.modifierFlags)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: event.modifierFlags)
            return event
        }
        Self.diag("monitors installed global=\(globalMonitor != nil) local=\(localMonitor != nil)")
    }

    private func handle(flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.control) && flags.contains(.option)
        if held, !isDown {
            isDown = true
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if !held, isDown {
            isDown = false
            DispatchQueue.main.async { [weak self] in self?.onRelease?() }
        }
    }
}
