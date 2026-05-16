import Foundation
import GRDB

struct TranscriptionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    var rawTranscript: String
    var cleanedTranscript: String
    var wordCount: Int
    var duration: TimeInterval
    var appPastedInto: String?
    
    init(id: UUID = UUID(), timestamp: Date = Date(), rawTranscript: String, cleanedTranscript: String, wordCount: Int, duration: TimeInterval, appPastedInto: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.wordCount = wordCount
        self.duration = duration
        self.appPastedInto = appPastedInto
    }
}
