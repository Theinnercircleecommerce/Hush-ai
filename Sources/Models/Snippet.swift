import Foundation
import GRDB

struct Snippet: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: UUID
    var trigger: String
    var replacement: String
    
    init(id: UUID = UUID(), trigger: String, replacement: String) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
    }
}
