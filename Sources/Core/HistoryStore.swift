import Foundation
import GRDB
import Combine

class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    
    let dbQueue: DatabaseQueue
    
    @Published var records: [TranscriptionRecord] = []
    @Published var snippets: [Snippet] = []
    @Published var dictionaryItems: [DictionaryItem] = []
    
    init() {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directoryURL = appSupportURL.appendingPathComponent("com.hush.app", isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let dbURL = directoryURL.appendingPathComponent("history.sqlite")
            
            dbQueue = try DatabaseQueue(path: dbURL.path)
            
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1") { db in
                try db.create(table: "transcriptionRecord") { t in
                    t.column("id", .text).primaryKey()
                    t.column("timestamp", .datetime).notNull()
                    t.column("rawTranscript", .text).notNull()
                    t.column("cleanedTranscript", .text).notNull()
                    t.column("wordCount", .integer).notNull()
                    t.column("duration", .double).notNull()
                    t.column("appPastedInto", .text)
                }
            }
            
            migrator.registerMigration("v2") { db in
                try db.create(table: "snippet") { t in
                    t.column("id", .text).primaryKey()
                    t.column("trigger", .text).notNull()
                    t.column("replacement", .text).notNull()
                }
                
                try db.create(table: "dictionaryItem") { t in
                    t.column("id", .text).primaryKey()
                    t.column("word", .text).notNull()
                }
            }
            
            // Per-call spend on the paid APIs. Counts and money only — no
            // prompt, transcript, or answer text. See UsageStore.
            migrator.registerMigration("v3") { db in
                try db.create(table: "usageEvent") { t in
                    t.column("id", .text).primaryKey()
                    t.column("timestamp", .datetime).notNull()
                    t.column("provider", .text).notNull()
                    t.column("model", .text).notNull()
                    t.column("inputTokens", .integer).notNull()
                    t.column("outputTokens", .integer).notNull()
                    t.column("costUSD", .double).notNull()
                    t.column("isEstimate", .boolean).notNull()
                }
                try db.create(index: "usageEvent_on_timestamp",
                              on: "usageEvent",
                              columns: ["timestamp"])
            }

            try migrator.migrate(dbQueue)
            
            refresh()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }
    
    func refresh() {
        do {
            let (fetchedRecords, fetchedSnippets, fetchedDictionary) = try dbQueue.read { db -> ([TranscriptionRecord], [Snippet], [DictionaryItem]) in
                let r = try TranscriptionRecord.order(Column("timestamp").desc).fetchAll(db)
                let s = try Snippet.fetchAll(db)
                let d = try DictionaryItem.fetchAll(db)
                return (r, s, d)
            }
            DispatchQueue.main.async {
                self.records = fetchedRecords
                self.snippets = fetchedSnippets
                self.dictionaryItems = fetchedDictionary
            }
        } catch {
            print("Failed to fetch records: \(error)")
        }
    }
    
    func add(rawText: String, cleanedText: String, duration: TimeInterval, appPastedInto: String? = nil) {
        let words = cleanedText.split(separator: " ").count
        let record = TranscriptionRecord(
            rawTranscript: rawText,
            cleanedTranscript: cleanedText,
            wordCount: words,
            duration: duration,
            appPastedInto: appPastedInto
        )
        
        do {
            _ = try dbQueue.write { db in
                try record.insert(db)
            }
            refresh()
        } catch {
            print("Failed to save record: \(error)")
        }
    }
    
    func delete(record: TranscriptionRecord) {
        do {
            _ = try dbQueue.write { db in
                try record.delete(db)
            }
            refresh()
        } catch {
            print("Failed to delete record: \(error)")
        }
    }
    
    func clearAll() {
        do {
            _ = try dbQueue.write { db in
                try TranscriptionRecord.deleteAll(db)
            }
            refresh()
        } catch {
            print("Failed to clear records: \(error)")
        }
    }
    
    func addSnippet(_ snippet: Snippet) {
        do {
            _ = try dbQueue.write { db in
                try snippet.insert(db)
            }
            refresh()
        } catch {
            print("Failed to add snippet: \(error)")
        }
    }
    
    func deleteSnippet(_ snippet: Snippet) {
        do {
            _ = try dbQueue.write { db in
                try snippet.delete(db)
            }
            refresh()
        } catch {
            print("Failed to delete snippet: \(error)")
        }
    }
    
    func addDictionaryItem(_ item: DictionaryItem) {
        do {
            _ = try dbQueue.write { db in
                try item.insert(db)
            }
            refresh()
        } catch {
            print("Failed to add dictionary item: \(error)")
        }
    }
    
    func deleteDictionaryItem(_ item: DictionaryItem) {
        do {
            _ = try dbQueue.write { db in
                try item.delete(db)
            }
            refresh()
        } catch {
            print("Failed to delete dictionary item: \(error)")
        }
    }
}
