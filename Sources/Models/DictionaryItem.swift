import Foundation
import GRDB

struct DictionaryItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: UUID
    var word: String
    
    init(id: UUID = UUID(), word: String) {
        self.id = id
        self.word = word
    }
}
