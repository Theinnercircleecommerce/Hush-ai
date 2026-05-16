import Foundation
import AVFoundation

class AudioCaptureService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    
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
        let fileName = UUID().uuidString + ".m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)
        self.currentFileURL = fileURL
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.record()
        
        startTime = Date()
        isRecording = true
        
        // Timer must be scheduled on the main thread's RunLoop
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.updateMeters()
            }
        }
    }
    
    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let recorder = audioRecorder, let start = startTime, let url = currentFileURL else {
            return nil
        }
        
        let duration = Date().timeIntervalSince(start)
        timer?.invalidate()
        timer = nil
        
        recorder.stop()
        isRecording = false
        audioLevel = 0.0
        
        return (url, duration)
    }
    
    private func updateMeters() {
        guard let recorder = audioRecorder, isRecording else { return }
        recorder.updateMeters()
        // Convert from dB to 0...1 scale roughly
        let db = recorder.averagePower(forChannel: 0)
        let level = max(0.0, min(1.0, CGFloat(db + 50) / 50.0))
        self.audioLevel = Float(level)
    }
}
