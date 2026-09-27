import XCTest
@testable import Hush

final class KeyMigrationTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "KeyMigrationTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testNeededOnlyOnce() {
        let d = freshDefaults()
        XCTAssertTrue(KeyMigration.needed(defaults: d))
        d.set(true, forKey: KeyMigration.flag)
        XCTAssertFalse(KeyMigration.needed(defaults: d))
    }

    func testRunSetsTalkComboAndFlag() {
        let d = freshDefaults()
        let settings = AppSettings.shared
        let before = settings.talkCombo
        KeyMigration.run(defaults: d, settings: settings, setDictateKey: false)
        XCTAssertEqual(settings.talkCombo, "option+shift")
        XCTAssertTrue(d.bool(forKey: KeyMigration.flag))
        settings.talkCombo = before
    }
}
