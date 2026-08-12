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

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Meetings shorter than this are discarded without an API call.
    static let minimumMeetingSeconds: TimeInterval = 30
    /// Meetings deserve the accurate model regardless of the dictation
    /// setting; the spec pins large-v3-turbo.
    static let whisperModel = "large-v3-turbo"

    private let micService = AudioCaptureService()
    private let systemService = SystemAudioCaptureService()
    private let nameReader = SpeakerNameReader()
    private let transcriber = LocalTranscriptionService()

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
        Task {
            do {
                try await systemService.start(excluding: NSApp.windows)
                try micService.startRecording()
                state = .recording(startedAt: Date())
            } catch {
                let systemURL = await systemService.stop()
                let mic = micService.stopRecording()
                if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
                if let mic { try? FileManager.default.removeItem(at: mic.url) }
                state = .failed(error.localizedDescription)
                scheduleFailureClear()
            }
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

            guard duration >= Self.minimumMeetingSeconds, let mic, let systemURL else {
                state = .idle
                return
            }

            do {
                let language = AppSettings.shared.primaryLanguage
                let micSegments = try await transcriber.transcribeSegments(
                    fileURL: mic.url, modelSize: Self.whisperModel, language: language)
                let systemSegments = try await transcriber.transcribeSegments(
                    fileURL: systemURL, modelSize: Self.whisperModel, language: language)

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
