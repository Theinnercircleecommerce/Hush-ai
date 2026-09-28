import XCTest
@testable import Hush

final class SettingsMigrationTests: XCTestCase {
    func testCopiesEveryKeyOnceAndSetsFlag() {
        let name = "SettingsMigrationTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let n = SettingsMigration.copy(from: ["talkCombo": "option+shift", "ttsVoice": "onyx"], into: d)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(d.string(forKey: "talkCombo"), "option+shift")
        XCTAssertTrue(d.bool(forKey: SettingsMigration.flag))
        XCTAssertEqual(SettingsMigration.copy(from: ["talkCombo": "fn"], into: d), 0)
        XCTAssertEqual(d.string(forKey: "talkCombo"), "option+shift")
    }
}
