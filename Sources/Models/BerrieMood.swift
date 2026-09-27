import Foundation

/// What Berrie's face shows. Derived, never stored: the flow already keeps
/// `HUDState` honest, and `isAsking` tells dictation and circle-to-ask apart
/// (both record).
enum BerrieMood: String, CaseIterable, Equatable {
    case idle, listening, looking, thinking, talking

    static func from(hud: HUDState, asking: Bool) -> BerrieMood {
        switch hud {
        case .idle, .error: return .idle
        case .recording: return asking ? .looking : .listening
        case .transcribing: return .thinking
        case .speaking: return .talking
        }
    }

    /// File in `Sources/Berrie/` (without extension). Missing files fall
    /// back to idle + badge in BerrieView.
    var imageName: String { "berrie-\(rawValue)" }

    /// SF Symbol drawn over the idle art until the mood has its own PNG.
    var badgeSymbol: String? {
        switch self {
        case .idle: return nil
        case .listening: return "mic.fill"
        case .looking: return "binoculars.fill"
        case .thinking: return "ellipsis"
        case .talking: return "waveform"
        }
    }
}
