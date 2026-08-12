import XCTest
@testable import Hush

/// The zero-setup name source: Meet prints each participant's name on their
/// video tile. These tests pin down what counts as a name versus Meet's own
/// on-screen chrome, since everything downstream (who owns which action
/// item) rests on getting this list right.
final class ParticipantNameFilterTests: XCTestCase {

    func testAcceptsOrdinaryDisplayNames() {
        XCTAssertTrue(ParticipantNameFilter.isPlausibleName("Sarah Chen"))
        XCTAssertTrue(ParticipantNameFilter.isPlausibleName("Tom"))
        XCTAssertTrue(ParticipantNameFilter.isPlausibleName("Maria Del Carmen Ruiz"))
    }

    func testRejectsMeetUIChrome() {
        for chrome in ["Chat", "People", "Meeting details", "Present now", "Leave call"] {
            XCTAssertFalse(ParticipantNameFilter.isPlausibleName(chrome), "should reject \(chrome)")
        }
    }

    func testRejectsOwnTileLabel() {
        // Meet labels the owner's own tile "You" — that person is `Me`, and
        // must never show up as a separate remote participant.
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("You"))
    }

    func testRejectsTextWithDigits() {
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("1080p"))
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("Sarah 2"))
    }

    func testRejectsLowercaseBodyText() {
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("we should ship on friday"))
    }

    func testRejectsSentenceLengthText() {
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("Sarah Chen Is Presenting Her Screen Now"))
    }

    func testRejectsPunctuationHeavyChrome() {
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("Sarah (Presenting)"))
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("Sarah: hello"))
    }

    func testRejectsTooShortAndTooLong() {
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName("S"))
        XCTAssertFalse(ParticipantNameFilter.isPlausibleName(String(repeating: "A", count: 41)))
    }

    func testStripsSurroundingWhitespaceBeforeJudging() {
        XCTAssertTrue(ParticipantNameFilter.isPlausibleName("  Sarah Chen  "))
    }
}
