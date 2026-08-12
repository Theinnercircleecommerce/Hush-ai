//
//  SystemAudioCaptureService.swift
//  Hush
//
//  Records system-output audio (the other meeting participants) to a
//  16 kHz mono CAF, and delivers one screen frame every ~2 s for caption
//  OCR. One SCStream, two outputs. Completely separate from
//  AudioCaptureService — the mic path is not touched.
//
//  16 kHz mono because raw 48 kHz stereo float is ~1.3 GB/hour and
//  WhisperKit resamples to 16 kHz mono anyway.
//

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Called on the frame queue with each ~2 s frame and its offset from
    /// capture start.
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?

    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var startDate: Date?
    private(set) var fileURL: URL?

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false)!
    private let audioQueue = DispatchQueue(label: "com.hush.meeting.audio")
    private let frameQueue = DispatchQueue(label: "com.hush.meeting.frames")

    /// - Parameter excludeWindowIDs: Hush's own window numbers, ALREADY read on
    ///   the main actor by the caller.
    ///
    ///   An `NSWindow` must never be passed in here. This type is nonisolated
    ///   (its stream callbacks are background queues), so reading an AppKit
    ///   property inside it runs off the main thread and kills the process
    ///   with no crash report and no stderr. `ScreenCaptureService` dodges
    ///   this by being `@MainActor` outright; this one can't be, so the
    ///   boundary is enforced by taking plain IDs instead.
    func start(excludeWindowIDs: [CGWindowID]) async throws {
        TalkHotkeyMonitor.diag("MEETING capture — requesting shareable content")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            TalkHotkeyMonitor.diag("MEETING capture FAILED — screen recording not permitted")
            throw ScreenCaptureError(message: "enable screen recording for Hush in system settings")
        }
        guard let display = content.displays.first else {
            TalkHotkeyMonitor.diag("MEETING capture FAILED — no displays")
            throw ScreenCaptureError(message: "enable screen recording for Hush in system settings")
        }

        let excludeIDs = Set(excludeWindowIDs)
        let excluded = content.windows.filter { excludeIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // never record Hush's own TTS
        config.sampleRate = 48_000
        config.channelCount = 2
        // Frames feed OCR only; one every 2 s is plenty.
        config.minimumFrameInterval = CMTime(value: 2, timescale: 1)
        config.width = Int(display.width)           // full-res so captions OCR cleanly
        config.height = Int(display.height)
        config.queueDepth = 5

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-them.caf")
        audioFile = try AVAudioFile(forWriting: url,
                                    settings: outputFormat.settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        fileURL = url
        converter = nil

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
        startDate = Date()
    }

    /// Stops capture and closes the file. Returns the audio file URL, nil if
    /// capture never started.
    func stop() async -> URL? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        converter = nil
        // Closing the AVAudioFile (by releasing it) flushes the header.
        audioQueue.sync { self.audioFile = nil }
        startDate = nil
        return fileURL
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio: handleAudio(sampleBuffer)
        case .screen: handleFrame(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Capture died underneath us (display unplugged, permission pulled).
        // Keep what was written; MeetingSession finds out at stop().
        self.stream = nil
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let file = audioFile,
              let pcm = sampleBuffer.asPCMBuffer else { return }
        if converter == nil {
            converter = AVAudioConverter(from: pcm.format, to: outputFormat)
        }
        guard let converter else { return }

        let ratio = outputFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        if out.frameLength > 0 {
            try? file.write(from: out)
        }
    }

    private func handleFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let start = startDate,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, Date().timeIntervalSince(start))
    }
}

private extension CMSampleBuffer {
    /// SCStream delivers audio as CMSampleBuffer; AVAudioConverter wants
    /// AVAudioPCMBuffer. No-copy view over the sample buffer's audio list.
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { audioBufferList, _ in
            guard let absd = formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate,
                                             channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format,
                                    bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}
