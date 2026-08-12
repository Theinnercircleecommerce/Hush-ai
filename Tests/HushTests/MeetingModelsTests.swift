import XCTest
@testable import Hush

final class MeetingModelsTests: XCTestCase {
    func testAttributedLineRoundTripsThroughJSON() throws {
        let lines = [
            AttributedLine(t: 0.0, speaker: "Me", text: "hello"),
            AttributedLine(t: 3.2, speaker: "Sarah", text: "hi there"),
        ]
        let data = try JSONEncoder().encode(lines)
        let decoded = try JSONDecoder().decode([AttributedLine].self, from: data)
        XCTAssertEqual(decoded, lines)
    }
}
