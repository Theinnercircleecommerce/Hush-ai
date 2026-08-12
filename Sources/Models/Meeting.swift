//
//  Meeting.swift
//  Hush
//
//  One recorded meeting. Transcript, participants, and action items are
//  stored as JSON strings — GRDB columns stay flat, Codable does the rest.
//

import Foundation
import GRDB

struct Meeting: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord {
    var id: String
    var startedAt: Date
    var duration: Double
    var title: String
    var participants: String     // JSON [String]
    var transcript: String       // JSON [AttributedLine]
    var recap: String?           // markdown; nil when recapFailed
    var actionItems: String?     // JSON [ActionItem]
    var recapFailed: Bool

    static let databaseTableName = "meeting"

    /// Called from HistoryStore's v4 migration AND from tests, so the test
    /// schema can never drift from the shipped one.
    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("id", .text).primaryKey()
            t.column("startedAt", .datetime).notNull()
            t.column("duration", .double).notNull()
            t.column("title", .text).notNull()
            t.column("participants", .text).notNull()
            t.column("transcript", .text).notNull()
            t.column("recap", .text)
            t.column("actionItems", .text)
            t.column("recapFailed", .boolean).notNull()
        }
        try db.create(index: "meeting_on_startedAt",
                      on: databaseTableName,
                      columns: ["startedAt"])
    }

    // MARK: - JSON helpers

    static func encode<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    var participantList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(participants.utf8))) ?? []
    }
    var lines: [AttributedLine] {
        (try? JSONDecoder().decode([AttributedLine].self, from: Data(transcript.utf8))) ?? []
    }
    var actionItemList: [ActionItem] {
        guard let actionItems else { return [] }
        return (try? JSONDecoder().decode([ActionItem].self, from: Data(actionItems.utf8))) ?? []
    }
}
