import Foundation
import AVFoundation
import CoreAudio

class AudioCaptureService: NSObject, ObservableObject {
    // AVAudioEngine (not AVAudioRecorder) so the mic is fully released on stop.
    // AVAudioRecorder's AudioQueue keeps the macOS orange mic indicator lit even
    // after stop()/dealloc; destroying the engine reliably drops it.
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    /// Envelope follower state for the HUD level. Touched only on the audio
    /// tap thread while recording, and reset on the main thread between takes.
    private var smoothedLevel: Float = 0
    /// Frames the tap actually delivered this take. Zero means the tap was
    /// installed against a format the bound device never produces — the
    /// Bluetooth failure mode — and is worth a diag line, because the
    /// resulting .caf is a valid-looking header with no audio in it.
    private var capturedFrames: Int64 = 0

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
        guard !isRecording else {
            throw NSError(domain: "AudioCaptureService", code: 1, userInfo: [NSLocalizedDescriptionKey: "already recording"])
        }
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + ".caf"
        let fileURL = tempDir.appendingPathComponent(fileName)
        self.currentFileURL = fileURL

        smoothedLevel = 0
        capturedFrames = 0
        let engine = AVAudioEngine()
        let boundDevice = applySelectedMicrophone(to: engine)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        TalkHotkeyMonitor.diag("REC start — device=\(boundDevice.map(String.init) ?? "none") format=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch")

        let file = try AVAudioFile(forWriting: fileURL, settings: inputFormat.settings)
        self.audioFile = file

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            try? self.audioFile?.write(from: buffer)
            self.capturedFrames += Int64(buffer.frameLength)

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
            // Normal speech on a laptop or earbud mic lands around -48…-15 dBFS.
            // The old -50…0 mapping squeezed all of that into the bottom third of
            // the range, so levels 0.0 / 0.12 / 0.20 drew IDENTICAL bars and the
            // HUD looked frozen while talking. Map the range people actually
            // speak in instead.
            let raw = max(0.0, min(1.0, (db + 52) / 37))
            // Fast attack, slow release: bars snap up on a syllable and glide
            // back instead of strobing at buffer rate (~47 updates/sec).
            let follow: Float = raw > self.smoothedLevel ? 0.6 : 0.15
            self.smoothedLevel += (raw - self.smoothedLevel) * follow
            let level = self.smoothedLevel
            DispatchQueue.main.async {
                self.audioLevel = level
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Same late-listener hazard as stopRecording: a failed start still
            // registered CoreAudio callbacks, so park the engine instead of
            // letting it free on throw.
            engine.inputNode.removeTap(onBus: 0)
            self.audioFile = nil
            Self.retireEngine(engine)
            TalkHotkeyMonitor.diag("REC start FAILED — \((error as NSError).code)")
            throw error
        }
        self.audioEngine = engine

        startTime = Date()
        isRecording = true
    }

    /// Stopped engines parked here until their CoreAudio callbacks have
    /// drained. Main-thread only.
    private static var retiredEngines: [ObjectIdentifier: AVAudioEngine] = [:]

    private static func retireEngine(_ engine: AVAudioEngine) {
        let key = ObjectIdentifier(engine)
        retiredEngines[key] = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            retiredEngines.removeValue(forKey: key)
        }
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let engine = audioEngine, let start = startTime, let url = currentFileURL else {
            return nil
        }

        let duration = Date().timeIntervalSince(start)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        audioFile = nil // Close the file so it's fully flushed for transcription

        // Don't let the engine deallocate yet. Bluetooth headsets renegotiate
        // their link (A2DP↔SCO) right around stop, and AVAudioIOUnit's property
        // listener fires on its own dispatch queue AFTER we drop our reference —
        // objc_msgSend on the freed engine, SIGSEGV (crash 2026-08-15 14:45,
        // faulting thread "AVAudioIOUnit"). Park the stopped engine for 10s so
        // late listener callbacks land on a live object. The engine is already
        // stopped, so the mic privacy indicator still drops immediately.
        Self.retireEngine(engine)

        isRecording = false
        audioLevel = 0.0
        smoothedLevel = 0

        TalkHotkeyMonitor.diag("REC stop — \(String(format: "%.2f", duration))s, \(capturedFrames) frames captured")

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

    /// Fires `handler` on the main queue whenever a device is plugged in,
    /// unplugged, or a Bluetooth set connects/disconnects. Returns a token the
    /// caller must hand back to `stopWatchingDevices` to unregister.
    static func watchDevices(_ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        return block
    }

    static func stopWatchingDevices(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
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

    /// The device CoreAudio currently considers the system input.
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

    /// Points the engine's input node at a real input device. Call BEFORE
    /// reading the input format, installing the tap, or starting the engine.
    ///
    /// This ALWAYS binds, even when the user hasn't picked a mic. Leaving the
    /// engine to choose is what broke Bluetooth headsets: AirPods publish two
    /// separate CoreAudio devices — a 48 kHz output-only one and a lower-rate
    /// input-only one — and an unbound input node latches onto the 48 kHz
    /// output side. `outputFormat(forBus:)` then reports 48 kHz, the tap is
    /// installed expecting audio the mic never produces, and the take lands as
    /// a 4096-byte header with zero frames. Binding to the resolved input
    /// device makes the reported format match the hardware that actually feeds
    /// the tap.
    @discardableResult
    func applySelectedMicrophone(to engine: AVAudioEngine) -> AudioDeviceID? {
        let uid = AppSettings.shared.selectedMicrophoneID
        // A stale UID (device unplugged, headset disconnected) resolves to nil —
        // fall through to the system default rather than leaving it unbound.
        let resolved = uid.isEmpty ? nil : Self.audioDeviceID(forUID: uid)
        guard var deviceID = resolved ?? Self.defaultInputDeviceID(),
              let unit = engine.inputNode.audioUnit else { return nil }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr ? deviceID : nil
    }
}
