//
//  Pricing.swift
//  Hush
//
//  Every provider rate Hush pays, in one place.
//
//  Costs are computed at write time and frozen into the stored row (see
//  UsageStore), so editing a rate here changes what FUTURE calls cost — it
//  never rewrites history. That's deliberate: a month you already paid for
//  shouldn't move when a provider changes its price list.
//

import Foundation

enum Pricing {

    // MARK: - Anthropic (claude-sonnet-4-6)

    /// USD per million input tokens. Screenshots are the bulk of this —
    /// roughly 1,500–2,500 tokens per captured screen.
    static let claudeInputPerMillionTokens = 3.00
    /// USD per million output tokens.
    static let claudeOutputPerMillionTokens = 15.00

    /// Exact — both token counts come off the SSE stream.
    static func claudeCost(inputTokens: Int, outputTokens: Int) -> Double {
        Double(inputTokens) / 1_000_000 * claudeInputPerMillionTokens
            + Double(outputTokens) / 1_000_000 * claudeOutputPerMillionTokens
    }

    // MARK: - OpenAI (gpt-4o-mini-tts)

    /// USD per million *characters* of input text.
    static let ttsInputPerMillionCharacters = 0.60
    /// USD per minute of generated audio. OpenAI bills audio output by token
    /// ($12/M) but publishes this per-minute figure as the practical estimate;
    /// the speech endpoint returns raw MP3 with no usage block, so a
    /// duration-derived estimate is the best we can do without a second API
    /// call. Expect ±10–15% against the real invoice.
    static let ttsPerAudioMinute = 0.015

    /// Estimated. Rows built from this are flagged `isEstimate`.
    static func ttsCost(characters: Int, audioSeconds: Double) -> Double {
        Double(characters) / 1_000_000 * ttsInputPerMillionCharacters
            + max(0, audioSeconds) / 60 * ttsPerAudioMinute
    }
}
