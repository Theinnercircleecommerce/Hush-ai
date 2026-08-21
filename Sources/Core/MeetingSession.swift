//
//  MeetingSession.swift
//  Hush
//
//  Orchestrates one meeting recording: mic + system audio + caption OCR →
//  two transcripts → merge → one recap call → saved Meeting row.
//  TalkSession's equivalent for meetings.
//
//  Owns a PRIVATE AudioCaptureService instance. AppState's instance belongs
//  to dictation/circle-to-ask; sharing it would let TalkSession's cancel
//  path silently end a meeting's mic file. Overlap is prevented by mutual
//  guards, never by sharing state.
//

import AppKit
import Foundation

@MainActor
final class MeetingSession: ObservableObject {

    static let shared = MeetingSession()

    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Non-fatal problem with the CURRENT recording ("system audio stopped
    /// mid-call") or a transient post-save note ("saved — no mic audio was
    /// captured"). Rendered under the Record Call pill; nil hides it.
    @Published private(set) var liveWarning: String?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Meetings shorter than this are discarded without an API call. Low
    /// enough that a short test recording still produces a row — a 30s floor
    /// silently ate every trial run.
    static let minimumMeetingSeconds: TimeInterval = 5
    /// Meetings deserve the accurate model regardless of the dictation
    /// setting; the spec pins large-v3-turbo.
    static let whisperModel = "large-v3-turbo"

    private let micService = AudioCaptureService()
    private let systemService = SystemAudioCaptureService()
    private let nameReader = SpeakerNameReader()
    private let transcriber = LocalTranscriptionService()

    /// Fires every 2s while recording; feeds systemService.health() through
    /// CaptureWatchdog. Main-actor only.
    private var watchdogTimer: Timer?
    /// Keeps the Mac (and display — caption OCR needs frames) awake while
    /// recording. Without it a call longer than the sleep timeout stops
    /// capturing halfway through with no error anywhere.
    private var sleepActivity: NSObjectProtocol?

    private init() {}

    func toggle(appState: AppState) {
        switch state {
        case .recording:
            stop()
        case .processing:
            break   // pill is disabled; ignore races
        case .idle, .failed:
            start(appState: appState)
        }
    }

    private func start(appState: AppState) {
        // Mic ownership: never start while dictation/circle-to-ask holds the
        // mic. The reverse guard lives in AppState/TalkSession.
        guard !appState.audioService.isRecording else {
            state = .failed("finish dictating first")
            return
        }
        nameReader.reset()
        systemService.onFrame = { [weak self] pixelBuffer, t in
            self?.nameReader.process(pixelBuffer: pixelBuffer, at: t)
        }
        // `windowNumber` is an Int and macOS hands out NEGATIVE numbers for
        // off-screen and system-owned windows — and `NSApp.windows` includes
        // those, unlike the curated list ScreenCaptureService is given.
        // `CGWindowID` is a UInt32, so a plain `CGWindowID(...)` conversion
        // TRAPS on the first negative one ("Not enough bits to represent the
        // passed value") and kills the app the instant Record Call is pressed.
        // `init(exactly:)` returns nil there instead; a window we can't
        // address by ID is one we simply don't exclude.
        //
        // Read on the main actor: NSWindow must not cross into the capture
        // service, which is nonisolated and runs on background queues.
        let hushWindowIDs = NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) }
        TalkHotkeyMonitor.diag("MEETING start — \(hushWindowIDs.count)/\(NSApp.windows.count) own windows excluded")
        Task {
            do {
                try await systemService.start(excludeWindowIDs: hushWindowIDs)
                try micService.startRecording()
                TalkHotkeyMonitor.diag("MEETING recording — mic + system audio live")
                let startedAt = Date()
                state = .recording(startedAt: startedAt)
                liveWarning = nil
                beginSleepBlocker()
                startWatchdog(startedAt: startedAt)
            } catch {
                TalkHotkeyMonitor.diag("MEETING start failed — \(error.localizedDescription)")
                let systemURL = await systemService.stop()
                let mic = micService.stopRecording()
                if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
                if let mic { try? FileManager.default.removeItem(at: mic.url) }
                endSleepBlocker()
                stopWatchdog()
                state = .failed(error.localizedDescription)
                scheduleFailureClear()
            }
        }
    }

    private func beginSleepBlocker() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Hush is recording a meeting")
    }

    private func endSleepBlocker() {
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func startWatchdog(startedAt: Date) {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.watchdogTick(startedAt: startedAt) }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// The mic leg self-heals inside AudioCaptureService (its own 0-frame
    /// watchdog and rebuild path) and is deliberately not watched here.
    /// This only covers the system leg, which had NO mid-call failure
    /// signal at all before — a dead SCStream looked exactly like a quiet
    /// room until stop().
    private func watchdogTick(startedAt: Date) {
        guard case .recording = state else { return }
        switch CaptureWatchdog.verdict(health: systemService.health(),
                                       startedAt: startedAt, now: Date()) {
        case .alive, .waitingForFirstBuffer:
            // A stream that recovers (permission re-granted mid-call)
            // unsticks the banner instead of leaving a stale scare on screen.
            if liveWarning != nil { liveWarning = nil }
        case .dead(let reason):
            if liveWarning != reason {
                liveWarning = reason
                TalkHotkeyMonitor.diag("MEETING watchdog — \(reason)")
            }
        }
    }

    /// Post-save note ("saved — no mic audio was captured"): visible long
    /// enough to read, then gone. Guarded so a later message is never wiped
    /// by an older timer.
    private func flashWarning(_ message: String) {
        liveWarning = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.liveWarning == message else { return }
            self.liveWarning = nil
        }
    }

    /// Auto-reverts a `.failed` state back to `.idle` after the owner has had
    /// a moment to read the message — same pattern as AppState's `.error`
    /// HUD state. Guards against clobbering a state change that happened in
    /// the meantime.
    private func scheduleFailureClear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, case .failed = self.state else { return }
            self.state = .idle
        }
    }

    private func stop() {
        guard case .recording(let startedAt) = state else { return }
        state = .processing
        stopWatchdog()
        endSleepBlocker()
        liveWarning = nil
        let duration = Date().timeIntervalSince(startedAt)
        let mic = micService.stopRecording()
        let ticks = nameReader.snapshotTicks()
        let names = nameReader.snapshotNames()

        Task {
            let systemURL = await systemService.stop()
            defer {
                if let mic { try? FileManager.default.removeItem(at: mic.url) }
                if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
            }

            // Every discard reason gets a visible message. A silent drop back
            // to .idle looks identical to "saved", which sent the owner
            // hunting through an empty Meetings tab.
            guard duration >= Self.minimumMeetingSeconds else {
                TalkHotkeyMonitor.diag("MEETING discarded — \(Int(duration))s, under the \(Int(Self.minimumMeetingSeconds))s floor")
                state = .failed("too short — record at least \(Int(Self.minimumMeetingSeconds))s")
                scheduleFailureClear()
                return
            }
            // One dead leg used to delete the OTHER leg's perfectly good
            // audio and fail the whole meeting. Now only a total loss fails.
            let legs = MeetingLegs.from(mic: mic?.url, system: systemURL)
            guard legs != .neither else {
                TalkHotkeyMonitor.diag("MEETING discarded — no audio captured on either leg")
                state = .failed("no audio captured")
                scheduleFailureClear()
                return
            }
            if let warning = legs.warningAfterSave {
                TalkHotkeyMonitor.diag("MEETING degraded — \(warning)")
            }

            do {
                let language = AppSettings.shared.primaryLanguage
                TalkHotkeyMonitor.diag("MEETING transcribing — \(Int(duration))s, \(ticks.count) speaker ticks, \(names.count) names")
                var micSegments: [TranscriptSegment] = []
                if let mic {
                    micSegments = try await transcriber.transcribeSegments(
                        fileURL: mic.url, modelSize: Self.whisperModel, language: language)
                }
                var systemSegments: [TranscriptSegment] = []
                if let systemURL {
                    systemSegments = try await transcriber.transcribeSegments(
                        fileURL: systemURL, modelSize: Self.whisperModel, language: language)
                }
                TalkHotkeyMonitor.diag("MEETING transcribed — \(micSegments.count) mic / \(systemSegments.count) system segments")

                let lines = TranscriptMerger.merge(micSegments: micSegments,
                                                   systemSegments: systemSegments,
                                                   speakerTicks: ticks)
                var participants = [TranscriptMerger.meSpeaker]
                participants.append(contentsOf: names)

                var meeting = Meeting(
                    id: UUID().uuidString,
                    startedAt: startedAt,
                    duration: duration,
                    title: DateFormatter.localizedString(from: startedAt, dateStyle: .medium, timeStyle: .short),
                    participants: Meeting.encode(participants),
                    transcript: Meeting.encode(lines),
                    recap: nil,
                    actionItems: nil,
                    recapFailed: true
                )
                do {
                    let result = try await MeetingRecapService.recap(lines: lines, participants: participants)
                    meeting.title = result.title
                    meeting.recap = result.recap
                    meeting.actionItems = Meeting.encode(result.actionItems)
                    meeting.recapFailed = false
                } catch {
                    // The transcript survives; recap can be retried from it.
                }
                MeetingStore.shared.save(meeting)
                state = .idle
                if let warning = legs.warningAfterSave { flashWarning(warning) }
            } catch {
                state = .failed(error.localizedDescription)
                scheduleFailureClear()
            }
        }
    }

    /// Re-runs the recap from a saved transcript. One API call, no
    /// re-transcription.
    func retryRecap(meetingID: String) {
        guard case .idle = state,
              var meeting = MeetingStore.shared.meetings.first(where: { $0.id == meetingID })
        else { return }
        state = .processing
        Task {
            do {
                let result = try await MeetingRecapService.recap(
                    lines: meeting.lines, participants: meeting.participantList)
                meeting.title = result.title
                meeting.recap = result.recap
                meeting.actionItems = Meeting.encode(result.actionItems)
                meeting.recapFailed = false
                MeetingStore.shared.save(meeting)
            } catch {
                // Row keeps recapFailed = true; user can retry again.
            }
            state = .idle
        }
    }
}
