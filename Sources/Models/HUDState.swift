import Foundation

enum HUDState: Equatable {
    case idle
    case recording
    case transcribing
    case speaking
    case error(String)
}
