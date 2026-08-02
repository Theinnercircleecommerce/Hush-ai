import Foundation
import AVFoundation
import CoreAudio

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

        // ONE engine for the app's lifetime (HeyClicky's proven pattern).
        // Creating a fresh engine per press forces a full input-device
        // teardown/renegotiation on every dictation, which mangles the start
        // sound and has wedged CoreAudio outright. stop() releases the mic;
        // the engine object itself is cheap to keep.
        let engine = audioEngine ?? AVAudioEngine()
        audioEngine = engine
        applySelectedMicrophone(to: engine)
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
        engine.stop() // Releases the mic; the engine is kept for reuse (see startRecording)
        audioFile = nil // Close the file so it's fully flushed for transcription

        isRecording = false
        audioLevel = 0.0

        return (url, duration)
    }
}

// MARK: - Microphone enumeration & selection

struct MicrophoneDevice: Identifiable, Hashable {
    let id: String   // CoreAudio/AVCaptureDevice unique ID
    let name: String
}

extension AudioCaptureService {
    static func availableMicrophones() -> [MicrophoneDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// Translates a CoreAudio UID string to an AudioDeviceID.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var cfUID = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr,
                &size, &deviceID
            )
        }
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }

    /// Points the engine's input node at the selected device. Call BEFORE
    /// installing the tap / starting the engine.
    func applySelectedMicrophone(to engine: AVAudioEngine) {
        let uid = AppSettings.shared.selectedMicrophoneID
        var resolvedID: AudioDeviceID?

        if !uid.isEmpty {
            // The user explicitly picked a mic — always honor it.
            resolvedID = Self.audioDeviceID(forUID: uid)
        } else if let defaultID = Self.defaultInputDeviceID(),
                  Self.isBluetoothTransport(defaultID),
                  let builtIn = Self.builtInInputDeviceID() {
            // "Default" resolved to a Bluetooth mic (e.g. AirPods). Opening a
            // BT mic drops the whole headset from high-quality listening into
            // call mode: system sounds go thin and distant, and the profile
            // switch has wedged CoreAudio entirely. Record from the built-in
            // mic instead; the headset keeps playing untouched.
            resolvedID = builtIn
        }

        guard var deviceID = resolvedID,
              let unit = engine.inputNode.audioUnit else { return }
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// The system default input device, or nil.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }

    /// True when the device reaches the Mac over Bluetooth (classic or LE).
    static func isBluetoothTransport(_ deviceID: AudioDeviceID) -> Bool {
        var transport: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The first input device built into the Mac, or nil.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for device in devices {
            var transport: UInt32 = 0
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            // Input side only: does it have input channels?
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }
            return device
        }
        return nil
    }
}
