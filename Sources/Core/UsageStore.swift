//
//  UsageStore.swift
//  Hush
//
//  Records what each paid API call cost and derives the numbers the Usage
//  screen shows. Shares `history.sqlite` with HistoryStore — the `usageEvent`
//  table is created by that class's `v3` migration.
//

import Foundation
import GRDB
import Combine

/// Money spent over some window, split by what spent it.
struct CostTotals {
    var claude: Double = 0
    var tts: Double = 0
    /// Number of questions asked — one Claude call is one question.
    var questions: Int = 0

    var total: Double { claude + tts }
}

/// One calendar day's spend.
struct DailyCost: Identifiable {
    let date: Date
    let claude: Double
    let tts: Double

    var id: Date { date }
    var total: Double { claude + tts }
}

/// Same threading shape as `HistoryStore`: writes happen on the GRDB queue,
/// `@Published` state is only ever assigned on the main thread.
final class UsageStore: ObservableObject {

    static let shared = UsageStore()

    /// Rows from the last `retentionDays`, newest first. Everything the UI
    /// shows is derived from this — the 30-day window is small enough that
    /// recomputing totals in memory is cheaper than round-tripping SQL.
    @Published private(set) var events: [UsageEvent] = []

    /// Rows older than this are pruned on refresh so the table can't grow
    /// without bound. Larger than what the screen lists, because the month
    /// total still needs them.
    private static let retentionDays = 31

    /// Days shown in the per-day list. Short on purpose — a 30-row wall is
    /// noise when the two totals at the top are the answer.
    static let listedDays = 7

    private var dbQueue: DatabaseQueue { HistoryStore.shared.dbQueue }

    private init() {
        // Off the main thread — this is constructed while the menu is being
        // laid out and a disk read has no business blocking that.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Recording

    /// Exact Claude cost. Called once per question, including when the stream
    /// failed partway — Anthropic bills for what it sent.
    func recordClaude(model: String, inputTokens: Int, outputTokens: Int) {
        guard inputTokens > 0 || outputTokens > 0 else { return }
        insert(UsageEvent(
            provider: UsageEvent.Provider.claude,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: Pricing.claudeCost(inputTokens: inputTokens, outputTokens: outputTokens),
            isEstimate: false
        ))
    }

    /// Estimated TTS cost, derived from the text we sent and the length of the
    /// audio that came back.
    func recordTTS(model: String, characters: Int, audioSeconds: Double) {
        guard characters > 0 else { return }
        insert(UsageEvent(
            provider: UsageEvent.Provider.tts,
            model: model,
            inputTokens: characters,
            outputTokens: 0,
            costUSD: Pricing.ttsCost(characters: characters, audioSeconds: audioSeconds),
            isEstimate: true
        ))
    }

    private func insert(_ event: UsageEvent) {
        // Off the caller's thread — both call sites are @MainActor and neither
        // should wait on a disk write to keep speaking.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.dbQueue.write { db in try event.insert(db) }
                self.refresh()
            } catch {
                print("UsageStore: failed to record usage – \(error)")
            }
        }
    }

    // MARK: - Loading

    func refresh() {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.retentionDays, to: Date()
        ) ?? Date.distantPast

        do {
            let fetched = try dbQueue.write { db -> [UsageEvent] in
                // Prune first so the window and the table agree.
                try db.execute(
                    sql: "DELETE FROM usageEvent WHERE timestamp < ?",
                    arguments: [cutoff]
                )
                return try UsageEvent
                    .order(Column("timestamp").desc)
                    .fetchAll(db)
            }
            DispatchQueue.main.async { self.events = fetched }
        } catch {
            print("UsageStore: failed to load usage – \(error)")
        }
    }

    func clearAll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.dbQueue.write { db in try UsageEvent.deleteAll(db) }
                self.refresh()
            } catch {
                print("UsageStore: failed to clear usage – \(error)")
            }
        }
    }

    // MARK: - Derived numbers

    /// Calendar month to date. Resets on the 1st.
    var thisMonth: CostTotals {
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start
            ?? Date.distantPast
        return totals(since: start)
    }

    var today: CostTotals {
        totals(since: Calendar.current.startOfDay(for: Date()))
    }

    /// Average cost of one question this month — the Claude call plus its
    /// share of the voice spend. Zero when nothing has been asked yet.
    var averagePerQuestionThisMonth: Double {
        let month = thisMonth
        guard month.questions > 0 else { return 0 }
        return month.total / Double(month.questions)
    }

    private func totals(since start: Date) -> CostTotals {
        var result = CostTotals()
        for event in events where event.timestamp >= start {
            if event.provider == UsageEvent.Provider.claude {
                result.claude += event.costUSD
                result.questions += 1
            } else {
                result.tts += event.costUSD
            }
        }
        return result
    }

    /// True when nothing has cost anything in the retention window — used to
    /// show an explanation instead of a column of zeroes.
    var isEmpty: Bool { events.isEmpty }

    /// One entry per day, newest first. Days with no spend are included so the
    /// list doesn't silently skip them.
    var dailyBreakdown: [DailyCost] {
        let calendar = Calendar.current
        var claudeByDay: [Date: Double] = [:]
        var ttsByDay: [Date: Double] = [:]

        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            if event.provider == UsageEvent.Provider.claude {
                claudeByDay[day, default: 0] += event.costUSD
            } else {
                ttsByDay[day, default: 0] += event.costUSD
            }
        }

        let today = calendar.startOfDay(for: Date())
        return (0..<Self.listedDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return DailyCost(
                date: day,
                claude: claudeByDay[day] ?? 0,
                tts: ttsByDay[day] ?? 0
            )
        }
    }
}
