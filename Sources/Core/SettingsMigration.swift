import Foundation

/// The body used to be Hush (com.hush.app). Its settings — keys, voice,
/// languages, sounds, Berrie's spot on screen — are copied once into this
/// bundle's defaults. Nothing is removed from the old domain.
enum SettingsMigration {
    static let flag = "berrieBodyMigrated"
    static let legacyDomain = "com.hush.app"

    @discardableResult
    static func copy(from legacy: [String: Any], into defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: flag) else { return 0 }
        for (key, value) in legacy { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: flag)
        return legacy.count
    }

    static func runIfNeeded() {
        let legacy = UserDefaults.standard.persistentDomain(forName: legacyDomain) ?? [:]
        copy(from: legacy, into: .standard)
    }
}
