//
//  TranscriptMerger.swift
//  Hush
//
//  Pure merge of the meeting's two transcripts. Mic segments are the owner;
//  system segments are attributed via the caption-derived speaker timeline.
//

import Foundation

enum TranscriptMerger {

    static let meSpeaker = "Me"
    static let unknownSpeaker = "Someone else"

    /// System segments take the name of the tick active at the segment's
    /// MIDPOINT, not its start — Meet's captions lag speech by about a
    /// second, so start-time matching mis-assigns the first words of a turn.
    static func merge(micSegments: [TranscriptSegment],
                      systemSegments: [TranscriptSegment],
                      speakerTicks: [SpeakerTick]) -> [AttributedLine] {
        let ticks = speakerTicks.sorted { $0.t < $1.t }
        var lines: [AttributedLine] = []

        for seg in micSegments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(AttributedLine(t: seg.start, speaker: meSpeaker, text: text))
        }
        for seg in systemSegments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let midpoint = (seg.start + seg.end) / 2
            lines.append(AttributedLine(t: seg.start,
                                        speaker: speaker(at: midpoint, in: ticks),
                                        text: text))
        }
        return lines.sorted { $0.t < $1.t }
    }

    /// Latest tick at or before `t`, or `unknownSpeaker` when none precedes it.
    /// `sortedTicks` must be ascending by `t`.
    static func speaker(at t: TimeInterval, in sortedTicks: [SpeakerTick]) -> String {
        var current = unknownSpeaker
        for tick in sortedTicks {
            if tick.t <= t { current = tick.name } else { break }
        }
        return current
    }
}
