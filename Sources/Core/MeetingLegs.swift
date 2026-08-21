//
//  MeetingLegs.swift
//  Hush
//
//  Which of the meeting's two audio files actually survived stop. One
//  missing leg degrades the meeting (with a visible note); it no longer
//  discards the other leg's perfectly good audio. Only `.neither` fails.
//
//  The empty case is `neither`, not `none`: a case literally named `none`
//  collides with `Optional.none` at every `== .none` comparison site and
//  the compiler resolves it to the wrong type.
//

import Foundation

enum MeetingLegs: Equatable {
    case both(mic: URL, system: URL)
    case micOnly(URL)
    case systemOnly(URL)
    case neither

    static func from(mic: URL?, system: URL?) -> MeetingLegs {
        switch (mic, system) {
        case let (mic?, system?): return .both(mic: mic, system: system)
        case let (mic?, nil):     return .micOnly(mic)
        case let (nil, system?):  return .systemOnly(system)
        case (nil, nil):          return .neither
        }
    }

    /// Shown transiently after a degraded save. Nil when nothing was lost.
    var warningAfterSave: String? {
        switch self {
        case .both, .neither: return nil
        case .micOnly:        return "saved — no system audio was captured"
        case .systemOnly:     return "saved — no mic audio was captured"
        }
    }
}
