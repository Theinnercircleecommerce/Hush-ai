//
//  MeetingStore.swift
//  Hush
//
//  Same threading shape as HistoryStore/UsageStore: writes on the GRDB
//  queue, @Published state assigned on the main thread.
//

import Foundation
import GRDB
import Combine

final class MeetingStore: ObservableObject {

    static let shared = MeetingStore(dbQueue: HistoryStore.shared.dbQueue)

    /// Newest first.
    @Published private(set) var meetings: [Meeting] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        refresh()
    }

    func refresh() {
        let rows = (try? dbQueue.read { db in
            try Meeting.order(Column("startedAt").desc).fetchAll(db)
        }) ?? []
        if Thread.isMainThread {
            meetings = rows
        } else {
            DispatchQueue.main.async { self.meetings = rows }
        }
    }

    func save(_ meeting: Meeting) {
        try? dbQueue.write { db in try meeting.save(db) }
        refresh()
    }

    func delete(id: String) {
        _ = try? dbQueue.write { db in try Meeting.deleteOne(db, key: id) }
        refresh()
    }
}
