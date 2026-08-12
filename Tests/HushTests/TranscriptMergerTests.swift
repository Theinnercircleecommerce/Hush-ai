import XCTest
@testable import Hush

final class TranscriptMergerTests: XCTestCase {

    func testMicSegmentsAreAlwaysMe() {
        let lines = TranscriptMerger.merge(
            micSegments: [TranscriptSegment(start: 1, end: 3, text: "my line")],
            systemSegments: [],
            speakerTicks: [SpeakerTick(t: 0, name: "Sarah")]
        )
        XCTAssertEqual(lines, [AttributedLine(t: 1, speaker: "Me", text: "my line")])
    }

    func testSystemSegmentTakesTickActiveAtMidpoint() {
        // Segment spans 4...10, midpoint 7. Sarah spoke at t=2, Tom at t=6.
        // Tom is active at the midpoint even though Sarah was active at start.
        let lines = TranscriptMerger.merge(
            micSegments: [],
            systemSegments: [TranscriptSegment(start: 4, end: 10, text: "ship friday")],
            speakerTicks: [SpeakerTick(t: 2, name: "Sarah"), SpeakerTick(t: 6, name: "Tom")]
        )
        XCTAssertEqual(lines, [AttributedLine(t: 4, speaker: "Tom", text: "ship friday")])
    }

    func testNoTickBeforeMidpointFallsBackToSomeoneElse() {
        let lines = TranscriptMerger.merge(
            micSegments: [],
            systemSegments: [TranscriptSegment(start: 0, end: 2, text: "early words")],
            speakerTicks: [SpeakerTick(t: 5, name: "Sarah")]
        )
        XCTAssertEqual(lines.first?.speaker, "Someone else")
    }

    func testOutputIsChronologicalAcrossBothStreams() {
        let lines = TranscriptMerger.merge(
            micSegments: [TranscriptSegment(start: 5, end: 6, text: "me later")],
            systemSegments: [TranscriptSegment(start: 1, end: 2, text: "them first")],
            speakerTicks: [SpeakerTick(t: 0, name: "Sarah")]
        )
        XCTAssertEqual(lines.map(\.text), ["them first", "me later"])
    }

    func testBlankSegmentsAreDropped() {
        let lines = TranscriptMerger.merge(
            micSegments: [TranscriptSegment(start: 0, end: 1, text: "   ")],
            systemSegments: [TranscriptSegment(start: 2, end: 3, text: "")],
            speakerTicks: []
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func testUnsortedTicksAreHandled() {
        XCTAssertEqual(
            TranscriptMerger.speaker(at: 7, in: [SpeakerTick(t: 6, name: "Tom"), SpeakerTick(t: 2, name: "Sarah")].sorted { $0.t < $1.t }),
            "Tom"
        )
    }
}
