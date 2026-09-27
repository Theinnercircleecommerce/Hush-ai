import XCTest
@testable import Hush

final class BerrieMoodTests: XCTestCase {
    func testIdleAndErrorAreIdle() {
        XCTAssertEqual(BerrieMood.from(hud: .idle, asking: false), .idle)
        XCTAssertEqual(BerrieMood.from(hud: .error("x"), asking: true), .idle)
    }

    func testRecordingIsListeningForDictationAndLookingForAsk() {
        XCTAssertEqual(BerrieMood.from(hud: .recording, asking: false), .listening)
        XCTAssertEqual(BerrieMood.from(hud: .recording, asking: true), .looking)
    }

    func testThinkingAndTalking() {
        XCTAssertEqual(BerrieMood.from(hud: .transcribing, asking: true), .thinking)
        XCTAssertEqual(BerrieMood.from(hud: .transcribing, asking: false), .thinking)
        XCTAssertEqual(BerrieMood.from(hud: .speaking, asking: true), .talking)
    }

    func testOnlyIdleHasNoBadge() {
        XCTAssertNil(BerrieMood.idle.badgeSymbol)
        for mood in BerrieMood.allCases where mood != .idle {
            XCTAssertNotNil(mood.badgeSymbol, "\(mood) needs a badge until its art exists")
        }
    }
}
