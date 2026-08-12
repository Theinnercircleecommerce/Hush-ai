import XCTest
@testable import Hush

final class MeetingRecapServiceTests: XCTestCase {

    func testFormatTranscriptUsesMinutesSecondsAndSpeaker() {
        let text = MeetingRecapService.formatTranscript([
            AttributedLine(t: 192, speaker: "Sarah", text: "ship friday"),
        ])
        XCTAssertEqual(text, "[03:12] Sarah: ship friday")
    }

    func testParseCleanJSON() {
        let result = MeetingRecapService.parse(
            #"{"title": "Launch sync", "recap": "we agreed to ship.", "action_items": [{"owner": "Sarah", "task": "send deck"}]}"#
        )
        XCTAssertEqual(result?.title, "Launch sync")
        XCTAssertEqual(result?.actionItems, [ActionItem(owner: "Sarah", task: "send deck")])
    }

    func testParseTolieratesMarkdownFences() {
        let fenced = """
        ```json
        {"title": "t", "recap": "r", "action_items": []}
        ```
        """
        XCTAssertEqual(MeetingRecapService.parse(fenced)?.recap, "r")
    }

    func testParseMissingRequiredKeyReturnsNil() {
        XCTAssertNil(MeetingRecapService.parse(#"{"recap": "no title here"}"#))
    }

    func testParseMalformedActionItemsAreSkippedNotFatal() {
        let result = MeetingRecapService.parse(
            #"{"title": "t", "recap": "r", "action_items": [{"owner": "Sarah"}, {"owner": "Tom", "task": "book room"}]}"#
        )
        XCTAssertEqual(result?.actionItems, [ActionItem(owner: "Tom", task: "book room")])
    }
}
