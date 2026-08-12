//
//  MeetingModels.swift
//  Hush
//
//  Value types shared by the meeting-recap pipeline (Phase 6).
//

import Foundation

/// One Whisper segment from one audio file. Times are seconds from that
/// file's start.
struct TranscriptSegment: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// "At time t, Meet's caption named this speaker." Emitted only when the
/// name changes, so consecutive ticks always differ.
struct SpeakerTick: Codable, Equatable {
    let t: TimeInterval
    let name: String
}

/// One attributed line of the merged meeting transcript.
struct AttributedLine: Codable, Equatable {
    let t: TimeInterval
    let speaker: String
    let text: String
}

/// One commitment extracted by the recap call.
struct ActionItem: Codable, Equatable {
    let owner: String
    let task: String
}

/// Parsed result of the recap call.
struct MeetingRecapResult: Equatable {
    let title: String
    let recap: String
    let actionItems: [ActionItem]
}
