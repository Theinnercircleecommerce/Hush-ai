import Foundation
import KeyboardShortcuts

/// One-time move from Hush's keys (⇧A dictate, ⌃⌥ ask) to Berrie's
/// (⌥Z, ⌥⇧). Both remain ordinary settings the owner can change after.
enum KeyMigration {
    static let flag = "berrieKeysMigrated"

    static func needed(defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: flag)
    }

    /// `setDictateKey: false` lets tests skip the global shortcut store.
    static func run(defaults: UserDefaults, settings: AppSettings, setDictateKey: Bool = true) {
        if setDictateKey {
            KeyboardShortcuts.setShortcut(.init(.z, modifiers: [.option]), for: .toggleRecord)
        }
        settings.talkCombo = "option+shift"
        defaults.set(true, forKey: flag)
    }
}
