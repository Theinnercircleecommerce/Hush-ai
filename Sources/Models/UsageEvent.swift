import Foundation
import GRDB

/// One billable call to a paid provider.
///
/// Deliberately holds no prompt, transcript, or answer text — counts and money
/// only. The screen contents that make a Hush question expensive are exactly
/// the contents that shouldn't be sitting in a local database.
struct UsageEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    /// `"claude"` or `"tts"`.
    var provider: String
    var model: String
    /// For TTS this is the input *character* count, not tokens — the endpoint
    /// bills text input per character.
    var inputTokens: Int
    var outputTokens: Int
    /// Computed from `Pricing` at write time and never recomputed.
    var costUSD: Double
    /// True when the provider gave us no usage numbers and the cost was
    /// derived (TTS). Rendered with a `≈`.
    var isEstimate: Bool

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         provider: String,
         model: String,
         inputTokens: Int,
         outputTokens: Int,
         costUSD: Double,
         isEstimate: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.isEstimate = isEstimate
    }

    enum Provider {
        static let claude = "claude"
        static let tts = "tts"
    }
}
