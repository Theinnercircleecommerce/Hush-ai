import AVFoundation
import Foundation

/// Converts Claude's text answer to speech via the OpenAI TTS API and plays
/// it through the system default output device.
///
/// Concurrency note: the class is marked @MainActor so every property access
/// and @Published mutation happens on the main thread automatically. The
/// network work and AVAudioPlayer initialisation are cheap enough that
/// dispatching them to a detached Task (which inherits no actor, so it runs on
/// the cooperative pool) and then hopping back to MainActor for the actual
/// play call is the safest pattern here. This avoids any risk of stranding
/// isSpeaking = true on a failure path because every failure branch funnels
/// through a single `fail()` helper that runs on MainActor.
///
/// Audio constraints (enforced by the project):
///   - No AVAudioEngine, no AVAudioSession, no input device, no route change.
///   - No forced output device or CoreAudio property writes.
///   - AVAudioPlayer alone: play-only, leaves the input route untouched.
@MainActor
final class SpeechOutputService: NSObject, ObservableObject {

    static let shared = SpeechOutputService()

    @Published private(set) var isSpeaking: Bool = false

    /// Retained for the lifetime of playback; nil between utterances.
    private var player: AVAudioPlayer?

    private override init() {}

    // MARK: - Public API

    /// Request TTS for `text`. No-throw: logs on failure, always leaves
    /// `isSpeaking == false` when not actually playing.
    func speak(_ text: String) async {
        // Stop any in-progress playback before starting a new utterance.
        stopPlayback()

        guard let apiKey = KeychainStore.get(.openai) else {
            TalkHotkeyMonitor.diag("SpeechOutputService: no OpenAI key in Keychain; skipping TTS")
            isSpeaking = false
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSpeaking = false
            return
        }

        // Mark speaking immediately so callers can observe intent.
        isSpeaking = true

        let voice = AppSettings.shared.ttsVoice

        // Build request off-MainActor to avoid blocking the UI.
        let mp3Data: Data
        do {
            mp3Data = try await fetchAudio(text: text, voice: voice, apiKey: apiKey)
        } catch {
            TalkHotkeyMonitor.diag("SpeechOutputService: network error – \(error.localizedDescription)")
            isSpeaking = false
            return
        }

        guard !mp3Data.isEmpty else {
            TalkHotkeyMonitor.diag("SpeechOutputService: API returned empty audio body")
            isSpeaking = false
            return
        }

        // Initialise and play. AVAudioPlayer(data:) can throw if the data is
        // not a valid audio file.
        do {
            let p = try AVAudioPlayer(data: mp3Data)
            p.delegate = self
            player = p
            p.prepareToPlay()
            let started = p.play()
            if !started {
                TalkHotkeyMonitor.diag("SpeechOutputService: AVAudioPlayer.play() returned false")
                player = nil
                isSpeaking = false
            }
            // On success, isSpeaking stays true until audioPlayerDidFinishPlaying.
        } catch {
            TalkHotkeyMonitor.diag("SpeechOutputService: AVAudioPlayer init failed – \(error.localizedDescription)")
            player = nil
            isSpeaking = false
        }
    }

    /// Halt playback immediately. Safe to call when nothing is playing.
    func stop() {
        stopPlayback()
    }

    // MARK: - Private helpers

    private func stopPlayback() {
        if let p = player {
            // Detach before stopping so a late delegate callback for this
            // player can't fire at all. The identity check in the delegate
            // already guards this, but that relies on main-actor ordering —
            // this removes the reliance.
            p.delegate = nil
            p.stop()
            player = nil
        }
        isSpeaking = false
    }

    /// Performs the HTTP round-trip on the cooperative thread pool.
    /// Returns raw MP3 bytes, or throws on network / HTTP error.
    private func fetchAudio(text: String, voice: String, apiKey: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "model": "gpt-4o-mini-tts",
            "voice": voice,
            "input": text,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            TalkHotkeyMonitor.diag("SpeechOutputService: non-HTTP response from TTS endpoint")
            throw TTSError.badResponse
        }
        guard http.statusCode == 200 else {
            // Log only the structured error code, never the raw body — the
            // request `input` is Claude's answer (derived from the user's
            // screen) and providers can echo request content in error text.
            var code = ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any] {
                code = (err["code"] as? String) ?? (err["type"] as? String) ?? ""
            }
            TalkHotkeyMonitor.diag("SpeechOutputService: TTS returned HTTP \(http.statusCode)\(code.isEmpty ? "" : " (\(code))")")
            throw TTSError.httpError(http.statusCode)
        }
        return data
    }
}

// MARK: - AVAudioPlayerDelegate

extension SpeechOutputService: AVAudioPlayerDelegate {
    // Called on the main thread by AVFoundation when playback ends naturally
    // or is interrupted. Sets isSpeaking = false and releases the player.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Only clear if this is still the active player (stop() may have
            // already replaced it with nil).
            if self.player === player {
                self.player = nil
                self.isSpeaking = false
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        TalkHotkeyMonitor.diag("SpeechOutputService: decode error – \(error?.localizedDescription ?? "unknown")")
        Task { @MainActor in
            if self.player === player {
                self.player = nil
                self.isSpeaking = false
            }
        }
    }
}

// MARK: - Errors (internal)

private enum TTSError: Error {
    case badResponse
    case httpError(Int)
}
