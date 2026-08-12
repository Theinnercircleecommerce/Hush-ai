import XCTest
import GRDB
@testable import Hush

final class MeetingStoreTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()   // in-memory
        try queue.write { db in try Meeting.createTable(db) }
        return queue
    }

    func testSaveAndFetchRoundTrip() throws {
        let queue = try makeQueue()
        let lines = [AttributedLine(t: 0, speaker: "Me", text: "hi")]
        let meeting = Meeting(
            id: "m1",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            duration: 120,
            title: "Standup",
            participants: Meeting.encode(["Me", "Sarah"]),
            transcript: Meeting.encode(lines),
            recap: "we said hi",
            actionItems: Meeting.encode([ActionItem(owner: "Sarah", task: "send deck")]),
            recapFailed: false
        )
        try queue.write { db in try meeting.save(db) }

        let fetched = try queue.read { db in try Meeting.fetchOne(db, key: "m1") }
        XCTAssertEqual(fetched?.title, "Standup")
        XCTAssertEqual(fetched?.participantList, ["Me", "Sarah"])
        XCTAssertEqual(fetched?.lines, lines)
        XCTAssertEqual(fetched?.actionItemList, [ActionItem(owner: "Sarah", task: "send deck")])
    }

    func testDelete() throws {
        let queue = try makeQueue()
        let store = MeetingStore(dbQueue: queue)
        let meeting = Meeting(
            id: "m2", startedAt: Date(), duration: 60, title: "t",
            participants: "[]", transcript: "[]",
            recap: nil, actionItems: nil, recapFailed: true
        )
        store.save(meeting)
        store.delete(id: "m2")
        let count = try queue.read { db in try Meeting.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }
}
