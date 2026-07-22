import Foundation
import AVFoundation

class AudioCaptureService: NSObject, ObservableObject {
    // AVAudioEngine (not AVAudioRecorder) so the mic is fully released on stop.
    // AVAudioRecorder's AudioQueue keeps the macOS orange mic indicator lit even
    // after stop()/dealloc; destroying the engine reliably drops it.
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0

    var currentFileURL: URL?
    var startTime: Date?

    func checkPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startRecording() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".caf"
        let fileURL = tempDir.appendingPathComponent(fileName)
        self.currentFileURL = fileURL

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        let file = try AVAudioFile(forWriting: fileURL, settings: inputFormat.settings)
        self.audioFile = file

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            try? self.audioFile?.write(from: buffer)

            // RMS level for the HUD waveform, mapped like the old dB metering (-50dB...0dB -> 0...1)
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameCount {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(frameCount))
            let db = 20 * log10(max(rms, 0.000_000_1))
            let level = max(0.0, min(1.0, (db + 50) / 50))
            DispatchQueue.main.async {
                self.audioLevel = level
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        startTime = Date()
        isRecording = true
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let engine = audioEngine, let start = startTime, let url = currentFileURL else {
            return nil
        }

        let duration = Date().timeIntervalSince(start)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil // Destroy the engine so macOS drops the mic privacy indicator
        audioFile = nil // Close the file so it's fully flushed for transcription

        isRecording = false
        audioLevel = 0.0

        return (url, duration)
    }
}
