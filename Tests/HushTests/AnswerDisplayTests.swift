import XCTest
@testable import Hush

final class AnswerDisplayTests: XCTestCase {
    func testMigrationPrefersStoredValue() {
        XCTAssertEqual(AnswerDisplay.migrate(stored: "voice", legacyShowBubble: true), .voice)
    }

    func testMigrationFromLegacyToggle() {
        XCTAssertEqual(AnswerDisplay.migrate(stored: nil, legacyShowBubble: true), .cursor)
        XCTAssertEqual(AnswerDisplay.migrate(stored: nil, legacyShowBubble: false), .bubble)
        XCTAssertEqual(AnswerDisplay.migrate(stored: nil, legacyShowBubble: nil), .bubble)
    }

    func testBubbleAnchorsToBerriesRightEdge() {
        let berrie = NSRect(x: 100, y: 50, width: 220, height: 126)
        let p = AnswerBubbleController.anchor(for: .bubble, berrie: berrie, cursor: CGPoint(x: 900, y: 900))
        XCTAssertEqual(p, CGPoint(x: 328, y: 176))
    }

    func testCursorAnchorIsRightAndBelowPointer() {
        let p = AnswerBubbleController.anchor(for: .cursor, berrie: nil, cursor: CGPoint(x: 900, y: 900))
        XCTAssertEqual(p, CGPoint(x: 920, y: 870))
    }

    func testBubbleWithoutBerrieFallsBackToCursor() {
        let p = AnswerBubbleController.anchor(for: .bubble, berrie: nil, cursor: CGPoint(x: 10, y: 40))
        XCTAssertEqual(p, CGPoint(x: 30, y: 10))
    }
}
