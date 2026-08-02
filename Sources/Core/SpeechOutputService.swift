import AVFoundation
import Foundation

/// Converts Claude's text answer to speech via the OpenAI TTS API and plays
/// it through the system default output device.
///
/// Concurrency note: the class is marked @MainActor so every property access
/// and @Published mutation happens on the main thread automatically. The
/// network work and AVAudioPlayer initialisation are cheap enough that
/// awaiting them from the main actor (the URLSession call suspends without
/// blocking the thread) keeps the whole state machine single-threaded. Every
/// failure branch leaves `isSpeaking` consistent because state only changes
/// on the main actor, in one drain loop.
///
/// Segment queue (Phase 2): callers `enqueue(_:)` sentence-sized segments as
/// they arrive from the streaming answer. Segments play strictly in order,
/// back-to-back, and segment N+1's audio is fetched WHILE segment N plays
/// (prefetch) so there is no gap between sentences. `isSpeaking` is true from
/// the first segment's playback start until the queue drains; `stop()` clears
/// the whole queue, cancels any in-flight fetch, and halts playback.
///
/// Audio constraints (enforced by the project):
///   - No AVAudioEngine, no AVAudioSession, no input device, no route change.
///   - No forced output device or CoreAudio property writes.
///   - AVAudioPlayer alone: play-only, leaves the input route untouched.
@MainActor
final class SpeechOutputService: NSObject, ObservableObject {

    static let shared = SpeechOutputService()

    @Published private(set) var isSpeaking: Bool = false

    /// True from the first `enqueue` until the queue fully drains — covers the
    /// gap between enqueuing a segment and its playback actually starting (when
    /// `isSpeaking` is still false because the fetch is in flight). Callers that
    /// wait for speech to finish should poll THIS, not `isSpeaking`, so a
    /// not-yet-fetched first segment can't be mistaken for "done".
    var isActive: Bool { drainTask != nil || isSpeaking }

    /// Retained for the lifetime of playback; nil between utterances.
    private var player: AVAudioPlayer?

    /// Pending segment texts, in play order. `enqueue` appends; the drain loop
    /// removes from the front.
    private var pending: [String] = []

    /// The single drain loop. Non-nil while segments are being processed.
    /// `enqueue` starts it if absent; it clears itself when the queue drains.
    private var drainTask: Task<Void, Never>?

    /// Bumped by `stop()` (and every fresh drain) so a fetch or a
    /// wait-for-playback that outlives a stop can detect it was abandoned and
    /// exit without touching newer state.
    private var generation = 0

    /// Fulfilled by the AVAudioPlayer delegate when the current segment
    /// finishes, so the drain loop can await playback completion without
    /// polling.
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    private override init() {}

    // MARK: - Public API

    /// Append a text segment to the speech queue. Segments play strictly in
    /// order. No-throw: failures are logged and skipped, never crash.
    ///
    /// Marked `async` for API symmetry with callers that want to await the
    /// hand-off, but it returns immediately — the work happens in the drain
    /// loop. `isSpeaking` flips true as soon as the first segment's playback
    /// actually starts.
    func enqueue(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending.append(trimmed)
        startDrainIfNeeded()
    }

    /// Convenience single-shot: replace anything queued/playing with one
    /// utterance. Reimplemented on top of the queue.
    func speak(_ text: String) async {
        stop()
        await enqueue(text)
    }

    /// Halt playback immediately and abandon the whole queue. Safe to call
    /// when nothing is playing.
    func stop() {
        generation &+= 1
        pending.removeAll()
        drainTask?.cancel()
        drainTask = nil
        // Release any drain loop parked on playback completion.
        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume()
        }
        stopPlayback()
    }

    // MARK: - Drain loop

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        generation &+= 1
        let myGeneration = generation
        drainTask = Task { [weak self] in
            await self?.drain(generation: myGeneration)
        }
    }

    /// Processes `pending` front-to-back. Prefetches segment N+1's audio while
    /// segment N plays, so playback is gapless. Runs entirely on the main
    /// actor; the only suspension points are the network fetch and the
    /// wait-for-playback, neither of which blocks the thread.
    private func drain(generation myGeneration: Int) async {
        guard let apiKey = KeychainStore.get(.openai) else {
            TalkHotkeyMonitor.diag("SpeechOutputService: no OpenAI key in Keychain; skipping TTS")
            finishDrain(generation: myGeneration)
            return
        }
        let voice = AppSettings.shared.ttsVoice

        // Kick off the first fetch. `prefetch` holds the audio for the next
        // segment we intend to play.
        guard !pending.isEmpty else {
            finishDrain(generation: myGeneration)
            return
        }
        // `current` holds the in-flight fetch for the segment we're about to
        // play; there is at most one such fetch running at a time (this one),
        // plus at most one prefetch we start right before blocking on playback.
        var current: Task<Data, Error>? = fetchTask(text: pending.removeFirst(), voice: voice, apiKey: apiKey)

        while let fetch = current {
            // Await this segment's audio.
            let data: Data
            do {
                data = try await fetch.value
            } catch {
                if generation != myGeneration { return }
                TalkHotkeyMonitor.diag("SpeechOutputService: network error – \(error.localizedDescription)")
                data = Data()   // treat as empty → skip, but keep draining
            }
            if generation != myGeneration { return }

            // Start prefetching the NEXT segment before we block on playing
            // this one, so its audio is ready the moment this segment ends.
            if !pending.isEmpty {
                current = fetchTask(text: pending.removeFirst(), voice: voice, apiKey: apiKey)
            } else {
                current = nil
            }

            // Play the current segment and wait for it to finish before
            // starting the next — this is what enforces strict order and
            // back-to-back playback.
            if !data.isEmpty {
                await playAndWait(data, generation: myGeneration)
                if generation != myGeneration { return }
            }
        }

        finishDrain(generation: myGeneration)
    }

    /// Build request + perform the HTTP round-trip as a cancellable Task.
    private func fetchTask(text: String, voice: String, apiKey: String) -> Task<Data, Error> {
        Task.detached {
            try await Self.fetchAudio(text: text, voice: voice, apiKey: apiKey)
        }
    }

    /// Initialise the player, start playback, mark `isSpeaking`, and suspend
    /// until the delegate reports completion (or `stop()` releases us).
    private func playAndWait(_ data: Data, generation myGeneration: Int) async {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.prepareToPlay()
            let started = p.play()
            if !started {
                TalkHotkeyMonitor.diag("SpeechOutputService: AVAudioPlayer.play() returned false")
                player = nil
                return
            }
            isSpeaking = true
        } catch {
            TalkHotkeyMonitor.diag("SpeechOutputService: AVAudioPlayer init failed – \(error.localizedDescription)")
            player = nil
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // If a stop() slipped in between play() and here, don't park.
            if generation != myGeneration {
                cont.resume()
            } else {
                playbackContinuation = cont
            }
        }
    }

    /// Clears the drain bookkeeping and drops `isSpeaking` once the queue is
    /// empty. Only acts if it still owns the current generation, so a stale
    /// drain that lost a race to `stop()` (or a newer enqueue) is a no-op.
    private func finishDrain(generation myGeneration: Int) {
        guard generation == myGeneration else { return }
        drainTask = nil
        if pending.isEmpty {
            isSpeaking = false
        } else {
            // A segment arrived after we decided to finish; keep going.
            startDrainIfNeeded()
        }
    }

    // MARK: - Private helpers

    private func stopPlayback() {
        if let p = player {
            // Detach before stopping so a late delegate callback for this
            // player can't fire at all.
            p.delegate = nil
            p.stop()
            player = nil
        }
        isSpeaking = false
    }

    /// Performs the HTTP round-trip on the cooperative thread pool.
    /// Returns raw MP3 bytes, or throws on network / HTTP error.
    ///
    /// `static` + `nonisolated` so it runs off the main actor from a detached
    /// fetch Task without hopping back for each byte.
    private static func fetchAudio(text: String, voice: String, apiKey: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Claude's client uses 20s; without this the TTS fetch inherits the
        // 60s default and could hold `.speaking` for a minute on a hung POST.
        request.timeoutInterval = 20

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
    // or is interrupted. Releases the player and wakes the drain loop.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playbackDidFinish(player)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        TalkHotkeyMonitor.diag("SpeechOutputService: decode error – \(error?.localizedDescription ?? "unknown")")
        Task { @MainActor in
            self.playbackDidFinish(player)
        }
    }

    /// Wake the drain loop that's parked on this segment's playback. Only
    /// acts if `player` is still this one (stop() may have replaced it).
    private func playbackDidFinish(_ finished: AVAudioPlayer) {
        guard self.player === finished else { return }
        self.player = nil
        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume()
        }
    }
}

// MARK: - Errors (internal)

private enum TTSError: Error {
    case badResponse
    case httpError(Int)
}
