//
//  TalkSession.swift
//  Hush
//
//  The circle-to-ask orchestrator: hold ⌃⌥, circle part of the screen, speak a
//  question, hear the answer. Wires together TalkHotkeyMonitor,
//  CircleOverlayController, AudioCaptureService, LocalTranscriptionService,
//  ScreenCaptureService, ClaudeVisionClient and SpeechOutputService.
//
//  This type owns NOTHING that dictation owns. It calls the audio service's
//  start/stop only, and never touches the engine, route or session.
//

import AppKit
import AVFoundation
import Foundation

/// Drives one hold-to-ask session at a time.
///
/// `@MainActor` isolated because everything it touches is: `AppState.hudState`
/// feeds SwiftUI, `ClaudeVisionClient` and `SpeechOutputService` are both main
/// actor types, and AppKit window enumeration must happen on the main thread.
@MainActor
final class TalkSession {

    static let shared = TalkSession()

    /// Streamed answer text, one delta at a time, on the main queue.
    /// Task 8's answer bubble hooks in here; nil means "nowhere to draw yet".
    var onAnswerChunk: ((String) -> Void)?

    private weak var appState: AppState?

    /// The one and only re-entrancy guard. True from the moment `begin()`
    /// commits to a session until the async tail finishes — success, failure
    /// or thrown error. `ClaudeVisionClient.ask` is not reentrant and two
    /// overlapping runs would interleave both the streamed chunks and the
    /// spoken answer.
    private var isBusy = false

    /// Bumped on every error so a stale 3-second reset can't clear a NEWER
    /// error (or a live session's state) off the nudge.
    private var errorGeneration = 0

    /// True only while the hotkey is (believed to be) held down, i.e. between
    /// a successful `begin()` and `end()`.
    private var isHolding = false

    /// Watchdog for a LOST release. If the paired `onRelease` never arrives —
    /// fast user switch, app suspended mid-hold, monitor dropped — nothing
    /// else would clear `isBusy` or close the mic, and every later press would
    /// be ignored forever. Same reasoning as CircleOverlayController's own
    /// self-heal, which fires independently of this one.
    private var holdWatchdog: Timer?
    private var modifiersAbsentTicks = 0
    private static let watchdogInterval: TimeInterval = 0.5
    /// ~3s of the modifiers being absent. The real release path arrives within
    /// milliseconds, so this can never steal a live session.
    private static let watchdogGraceTicks = 6

    /// Recordings shorter than this are a fumbled hotkey, not a question.
    private static let minimumRecordingDuration: TimeInterval = 0.3

    /// Ceiling on how long we'll sit in `.speaking` waiting for playback to
    /// end. Purely a stranding guard — real answers are seconds long.
    private static let speechWatchdog: TimeInterval = 90

    /// Longest error text we'll put on the nudge (it renders on one line).
    private static let maxErrorLength = 60

    private init() {
        // Wire the streaming answer into the cursor-adjacent bubble here — the
        // one place `onAnswerChunk` is defined and fired — rather than in
        // AppDelegate, so the visual sink lives with the source it drains.
        onAnswerChunk = { chunk in
            AnswerBubbleController.shared.append(chunk)
        }
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Hotkey entry points

    /// ⌃⌥ pressed. Opens the circle overlay and the mic.
    func begin() {
        guard !isBusy else {
            TalkHotkeyMonitor.diag("SESSION press ignored — session already running")
            return
        }
        guard let appState = appState else {
            TalkHotkeyMonitor.diag("SESSION press ignored — no appState attached")
            return
        }

        // Keys before the mic: a user with no key should never see a recording
        // indicator, and should get the actionable message instead.
        guard KeychainStore.get(.anthropic) != nil else {
            TalkHotkeyMonitor.diag("SESSION blocked — no anthropic key")
            fail("add your api key in settings")
            return
        }

        // Read-only permission check. Recording without it yields silence,
        // which would look like "Hush ignored me".
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            TalkHotkeyMonitor.diag("SESSION blocked — mic permission not granted")
            fail("allow microphone access")
            return
        }

        // The audio service is SHARED with dictation, and its startRecording()
        // has no re-entry guard of its own: called while already recording it
        // installs a second tap on bus 0, which raises an ObjC exception that
        // `try` cannot catch. Reachable for real — hands-free dictation
        // (double-tap the record hotkey) keeps recording with nothing held
        // down, which is exactly when reaching for ⌃⌥ feels natural.
        // Dictation already guards the mirror case (AppDelegate checks
        // hudState == .idle before starting); this is the other half.
        guard !appState.audioService.isRecording else {
            TalkHotkeyMonitor.diag("SESSION press ignored — dictation is recording")
            return
        }

        // Committed. Anything below must clear isBusy on failure.
        isBusy = true

        // Barge-in: a previous answer may still be playing, and its bubble
        // may still be on screen.
        SpeechOutputService.shared.stop()
        AnswerBubbleController.shared.clear()

        CircleOverlayController.shared.begin()

        do {
            try appState.audioService.startRecording()
        } catch {
            CircleOverlayController.shared.end()
            isBusy = false
            TalkHotkeyMonitor.diag("SESSION mic failed to start — \(error.localizedDescription)")
            fail("couldn't start the mic")
            return
        }

        isHolding = true
        startHoldWatchdog()
        appState.hudState = .recording
        TalkHotkeyMonitor.diag("SESSION begin — listening")
    }

    /// ⌃⌥ released. Closes the overlay, stops the mic, runs the ask.
    ///
    /// Safe to call with no session running: a duplicate or lost flagsChanged
    /// event must not stop a *dictation* recording that shares the same audio
    /// service.
    func end() {
        guard isBusy else {
            TalkHotkeyMonitor.diag("SESSION release ignored — no session running")
            return
        }
        stopHoldWatchdog()
        isHolding = false

        // Cleanup runs unconditionally and FIRST. The overlay must come down
        // and the mic must close on every exit from a started session — a
        // stranded mic is the worst failure this file can produce, so no guard
        // is allowed to sit above this.
        let region = CircleOverlayController.shared.end()
        let recording = appState?.audioService.stopRecording()

        guard let appState = appState else {
            isBusy = false
            TalkHotkeyMonitor.diag("SESSION release — no appState (teardown); overlay and mic closed")
            return
        }

        guard let recording = recording else {
            isBusy = false
            appState.hudState = .idle
            TalkHotkeyMonitor.diag("SESSION release — no recording produced, back to idle")
            return
        }

        guard recording.duration >= Self.minimumRecordingDuration else {
            isBusy = false
            appState.hudState = .idle
            TalkHotkeyMonitor.diag(String(format: "SESSION release — recording too short (%.2fs), back to idle", recording.duration))
            return
        }

        appState.hudState = .transcribing
        TalkHotkeyMonitor.diag(String(
            format: "SESSION release — %.2fs audio, circle=%@",
            recording.duration,
            region == nil ? "none" : "yes"
        ))

        // Task inherits the main actor. `defer` here is what makes isBusy
        // impossible to strand: it runs on every exit, including a throw out
        // of any await above it.
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }

            do {
                try await self.run(audioURL: recording.url, region: region)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                TalkHotkeyMonitor.diag("SESSION error — \(message)")
                self.fail(message)
            }
        }
    }

    // MARK: - The flow

    private func run(audioURL: URL, region: CGRect?) async throws {
        guard let appState = appState else { return }

        let raw = try await appState.localService.transcribe(
            fileURL: audioURL,
            modelSize: AppSettings.shared.whisperKitModelSize,
            language: AppSettings.shared.primaryLanguage
        )
        let transcript = Self.cleanTranscript(raw)

        // Empty transcript is an ordinary outcome — held the hotkey, said
        // nothing. Silent return to idle: no error, no API call, no cost.
        guard !transcript.isEmpty else {
            TalkHotkeyMonitor.diag("SESSION transcript empty — no api call, back to idle")
            appState.hudState = .idle
            return
        }
        TalkHotkeyMonitor.diag("SESSION transcript ok — \(transcript.count) chars")

        let screens = try await ScreenCaptureService.captureAll(excluding: hushWindows())
        TalkHotkeyMonitor.diag("SESSION captured \(screens.count) screen(s)")

        let crop = region.flatMap { rect in
            screens.first { $0.displayFrame.intersects(rect) }
                .flatMap { ScreenCaptureService.crop($0, toGlobalRect: rect) }
        }
        TalkHotkeyMonitor.diag("SESSION crop=\(crop.map { "\($0.count) bytes" } ?? "none")")

        let answer = try await ClaudeVisionClient.shared.ask(
            transcript: transcript,
            screens: screens,
            croppedRegion: crop
        ) { [weak self] chunk in
            self?.onAnswerChunk?(chunk)
        }
        TalkHotkeyMonitor.diag("SESSION answer ok — \(answer.count) chars")

        // SpeechOutputService silently no-ops without an OpenAI key, so
        // awaitSpeechCompletion would return on its first poll and the user
        // would get a one-frame amber "Speaking" with no sound at all.
        guard KeychainStore.get(.openai) != nil else {
            TalkHotkeyMonitor.diag("SESSION no openai key — skipping speech, straight to idle")
            appState.hudState = .idle
            return
        }

        appState.hudState = .speaking
        await SpeechOutputService.shared.speak(answer)
        // `speak` returns once playback STARTS, so hold the speaking state
        // until the player actually finishes.
        await awaitSpeechCompletion()

        appState.hudState = .idle
        TalkHotkeyMonitor.diag("SESSION complete — idle")
    }

    // MARK: - Lost-release watchdog

    private func startHoldWatchdog() {
        stopHoldWatchdog()
        modifiersAbsentTicks = 0
        // No captures: the closure is @Sendable, and TalkSession is a
        // main-actor singleton, so reach it through `shared` instead.
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { _ in
            MainActor.assumeIsolated { TalkSession.shared.holdWatchdogTick() }
        }
        // .common so a menu- or resize-tracking loop can't silence it.
        RunLoop.main.add(timer, forMode: .common)
        holdWatchdog = timer
    }

    private func stopHoldWatchdog() {
        holdWatchdog?.invalidate()
        holdWatchdog = nil
        modifiersAbsentTicks = 0
    }

    private func holdWatchdogTick() {
        guard isBusy, isHolding else {
            stopHoldWatchdog()
            return
        }
        guard !NSEvent.modifierFlags.contains([.control, .option]) else {
            modifiersAbsentTicks = 0
            return
        }
        modifiersAbsentTicks += 1
        guard modifiersAbsentTicks >= Self.watchdogGraceTicks else { return }

        TalkHotkeyMonitor.diag("SESSION watchdog — release never arrived, aborting hold")
        stopHoldWatchdog()
        isHolding = false
        CircleOverlayController.shared.end()
        _ = appState?.audioService.stopRecording()
        isBusy = false
        appState?.hudState = .idle
    }

    // MARK: - Helpers

    /// Whisper emits bracket/parenthesis tags for silence ("[BLANK_AUDIO]",
    /// "(music playing)"). Those are not a question and must not reach the API.
    private static func cleanTranscript(_ text: String) -> String {
        var cleaned = text
        if let regex = try? NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)") {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(location: 0, length: cleaned.utf16.count),
                withTemplate: ""
            )
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every window Hush owns, so its own overlay/nudge/menu never appears in
    /// the screenshots sent to Claude.
    private func hushWindows() -> [NSWindow] {
        CircleOverlayController.shared.panelWindows
            + NotchNudgeController.shared.panelWindows
            + NudgeMenuController.shared.panelWindows
            + AnswerBubbleController.shared.panelWindows
    }

    /// Polls rather than observing `$isSpeaking`: one Bool read every 100ms
    /// for the duration of a short utterance, with a hard ceiling so a lost
    /// AVAudioPlayer delegate callback can never pin the session open.
    private func awaitSpeechCompletion() async {
        let deadline = Date().addingTimeInterval(Self.speechWatchdog)
        while SpeechOutputService.shared.isSpeaking, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if SpeechOutputService.shared.isSpeaking {
            TalkHotkeyMonitor.diag("SESSION speech watchdog fired — forcing stop")
            SpeechOutputService.shared.stop()
        }
    }

    /// Shows a short error on the nudge and returns to idle after 3 seconds,
    /// mirroring AppState's existing recovery pattern.
    private func fail(_ message: String) {
        guard let appState = appState else { return }

        var short = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if short.count > Self.maxErrorLength {
            short = String(short.prefix(Self.maxErrorLength)) + "…"
        }
        if short.isEmpty { short = "something went wrong" }

        errorGeneration += 1
        let generation = errorGeneration
        appState.hudState = .error(short)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.errorGeneration == generation else { return }
            if case .error = appState.hudState {
                appState.hudState = .idle
            }
        }
    }
}
