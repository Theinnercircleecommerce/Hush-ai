import XCTest
@testable import Hush

final class CaptionParserTests: XCTestCase {

    func testPlainCaptionLine() {
        XCTAssertEqual(CaptionParser.speakerName(fromOCRLine: "Sarah Chen: we should ship on friday"), "Sarah Chen")
    }

    func testWhitespaceAroundNameIsStripped() {
        XCTAssertEqual(CaptionParser.speakerName(fromOCRLine: "  Tom : sounds good"), "Tom")
    }

    func testLineWithoutColonIsNotACaption() {
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: "Meeting details"))
    }

    func testEmptyNameIsRejected() {
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: ": stray colon"))
    }

    func testSentenceBeforeColonIsRejected() {
        // OCR grabbed body text containing a colon — five+ words is a
        // sentence, not a name.
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: "here is the thing we discussed: budgets"))
    }

    func testAbsurdlyLongNameIsRejected() {
        let junk = String(repeating: "x", count: 60)
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: "\(junk): hi"))
    }
}
