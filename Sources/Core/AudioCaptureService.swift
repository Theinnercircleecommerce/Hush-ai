import Foundation
import AVFoundation
import CoreAudio

class AudioCaptureService: NSObject, ObservableObject {
    // AVAudioEngine (not AVAudioRecorder) so the mic is fully released on stop.
    // AVAudioRecorder's AudioQueue keeps the macOS orange mic indicator lit even
    // after stop()/dealloc; destroying the engine reliably drops it.
    //
    // Everything that touches CoreAudio HAL (device binding, format reads,
    // engine start/stop) runs on `captureQueue`, NEVER the main thread. A
    // Bluetooth headset renegotiating A2DP↔SCO can wedge those calls for tens
    // of seconds; when they ran on the main thread that was a full app freeze
    // (sampled 2026-08-15: main thread stuck under engine start while the SCO
    // link came up).
    private let captureQueue = DispatchQueue(label: "com.hush.audio-capture")

    /// Take lifecycle, guarded by `stateLock`. `takeID` pairs each start with
    /// its stop and invalidates stale watchdogs.
    private enum EngineState { case idle, opening, running }
    private let stateLock = NSLock()
    private var engineState: EngineState = .idle
    private var stopRequested = false
    private var takeID: UInt64 = 0

    /// captureQueue-only.
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?

    /// Envelope follower state for the HUD level. Touched only on the audio
    /// tap thread while recording, and reset between takes.
    private var smoothedLevel: Float = 0
    /// Frames the tap actually delivered this take (guarded by stateLock).
    /// Zero shortly after start means the tap was installed against a format
    /// the bound device never produces — the Bluetooth failure mode, where the
    /// engine reports the stale A2DP rate before the SCO mic link is up — and
    /// triggers the watchdog rebuild.
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
        self.startTime = Date()
        self.isRecording = true

        stateLock.lock()
        takeID &+= 1
        let take = takeID
        engineState = .opening
        stopRequested = false
        capturedFrames = 0
        stateLock.unlock()
        smoothedLevel = 0

        captureQueue.async { [weak self] in
            self?.openEngine(take: take, fileURL: fileURL, attempt: 1)
        }
    }

    /// captureQueue-only. Opens the mic and starts the engine; reschedules
    /// itself (a fresh engine, same file) if the tap turns out to be dead.
    private func openEngine(take: UInt64, fileURL: URL, attempt: Int) {
        stateLock.lock()
        let abandoned = stopRequested || take != takeID
        stateLock.unlock()
        if abandoned { finishIdle() ; return }

        let engine = AVAudioEngine()
        // After a dead first take the saved mic selection is the prime suspect
        // (it can resolve to the output half of a Bluetooth headset) — retries
        // trust the system default input instead.
        let boundDevice = applySelectedMicrophone(to: engine, preferDefault: attempt > 1)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        TalkHotkeyMonitor.diag("REC start(\(attempt)) — device=\(boundDevice.map(String.init) ?? "none") format=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let file = try? AVAudioFile(forWriting: fileURL, settings: inputFormat.settings) else {
            TalkHotkeyMonitor.diag("REC start(\(attempt)) FAILED — bad format or file")
            Self.retireEngine(engine)
            finishIdle()
            return
        }
        self.audioFile = file

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            try? self.audioFile?.write(from: buffer)
            self.stateLock.lock()
            self.capturedFrames += Int64(buffer.frameLength)
            self.stateLock.unlock()

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
            try engine.start() // the wedge zone: can block for seconds on Bluetooth
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.audioFile = nil
            Self.retireEngine(engine)
            TalkHotkeyMonitor.diag("REC start(\(attempt)) FAILED — \((error as NSError).code)")
            finishIdle()
            return
        }

        stateLock.lock()
        let stopMeanwhile = stopRequested || take != takeID
        if !stopMeanwhile { engineState = .running }
        stateLock.unlock()

        if stopMeanwhile {
            // The user released (or a new take began) while start was blocked.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioFile = nil
            Self.retireEngine(engine)
            finishIdle()
            TalkHotkeyMonitor.diag("REC start(\(attempt)) — finished after stop, discarded")
            return
        }
        self.audioEngine = engine

        // Dead-tap watchdog. After a Bluetooth headset falls back to A2DP, the
        // engine can report a stale rate (44.1k) while the mic will only ever
        // deliver SCO-rate audio — the tap then never fires. If no frames have
        // arrived shortly after start, rebuild from scratch: by then the SCO
        // link is up and the fresh engine reads the real rate. The file is
        // recreated by the retry, so no audio is lost — none had arrived.
        guard attempt < 3 else { return }
        captureQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let dead = self.engineState == .running && take == self.takeID
                && !self.stopRequested && self.capturedFrames == 0
            self.stateLock.unlock()
            guard dead, let stale = self.audioEngine else { return }
            TalkHotkeyMonitor.diag("REC watchdog — 0 frames after 0.4s, rebuilding engine")
            stale.inputNode.removeTap(onBus: 0)
            stale.stop()
            self.audioEngine = nil
            self.audioFile = nil
            Self.retireEngine(stale)
            self.stateLock.lock()
            self.engineState = .opening
            self.stateLock.unlock()
            self.openEngine(take: take, fileURL: fileURL, attempt: attempt + 1)
        }
    }

    private func finishIdle() {
        stateLock.lock()
        engineState = .idle
        stateLock.unlock()
    }

    /// Stopped engines parked here until their CoreAudio callbacks have
    /// drained. Bluetooth headsets renegotiate A2DP↔SCO right around stop,
    /// and AVAudioIOUnit's property listener fires on its own dispatch queue
    /// AFTER the last reference would drop — objc_msgSend on a freed engine,
    /// SIGSEGV (crash 2026-08-15 14:45, faulting thread "AVAudioIOUnit").
    /// Parking the stopped engine for 10s lets late callbacks land on a live
    /// object; the engine is stopped, so the mic indicator drops immediately.
    private static let retireLock = NSLock()
    private static var retiredEngines: [ObjectIdentifier: AVAudioEngine] = [:]

    private static func retireEngine(_ engine: AVAudioEngine) {
        let key = ObjectIdentifier(engine)
        retireLock.lock()
        retiredEngines[key] = engine
        retireLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            retireLock.lock()
            retiredEngines.removeValue(forKey: key)
            retireLock.unlock()
        }
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let start = startTime, let url = currentFileURL else {
            return nil
        }
        isRecording = false
        audioLevel = 0.0
        let duration = Date().timeIntervalSince(start)

        stateLock.lock()
        stopRequested = true
        let state = engineState
        let frames = capturedFrames
        stateLock.unlock()

        if state != .running {
            // Engine still opening (or already torn down). The opener sees
            // stopRequested and discards on its own — do NOT wait on the
            // capture queue here: that call may be wedged mid-SCO-negotiation
            // for seconds, and blocking on it is the old main-thread freeze.
            TalkHotkeyMonitor.diag("REC stop — \(String(format: "%.2f", duration))s, engine not running (\(state)), no audio")
            return nil
        }

        // Engine is running, so the queue is free: teardown is fast, and doing
        // it synchronously guarantees the file is flushed before transcription
        // opens it.
        captureQueue.sync {
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                self.audioEngine = nil
                Self.retireEngine(engine)
            }
            self.audioFile = nil
        }
        finishIdle()
        smoothedLevel = 0

        TalkHotkeyMonitor.diag("REC stop — \(String(format: "%.2f", duration))s, \(frames) frames captured")
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

    /// True when the device exposes at least one INPUT channel. Bluetooth
    /// headsets publish two CoreAudio devices — a 48 kHz output-only one and a
    /// lower-rate input-only one — and after a reconnect a saved mic UID can
    /// resolve to the OUTPUT half. Binding the input unit to that device
    /// "works" (engine starts, format reads 48 kHz) but the tap never receives
    /// a single frame.
    static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, listPtr) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    /// Points the engine's input node at a real input device. Call BEFORE
    /// reading the input format, installing the tap, or starting the engine.
    ///
    /// This ALWAYS binds — an unbound input node latches onto whatever device
    /// the HAL suggests, which for Bluetooth headsets is often the 48 kHz
    /// output-only half (zero-frame takes, 4096-byte header-only .caf files).
    /// Candidates are tried in order and anything without input channels is
    /// skipped. `preferDefault` drops the user's saved selection to the back —
    /// the watchdog uses it after a dead take, when the saved UID is the prime
    /// suspect.
    @discardableResult
    func applySelectedMicrophone(to engine: AVAudioEngine, preferDefault: Bool = false) -> AudioDeviceID? {
        let uid = AppSettings.shared.selectedMicrophoneID
        let selected = uid.isEmpty ? nil : Self.audioDeviceID(forUID: uid)
        var candidates = [selected, Self.defaultInputDeviceID()]
        if preferDefault { candidates.reverse() }
        guard var deviceID = candidates.compactMap({ $0 }).first(where: { Self.hasInputChannels($0) }),
              let unit = engine.inputNode.audioUnit else {
            TalkHotkeyMonitor.diag("REC bind — no device with input channels (selected uid \(uid.isEmpty ? "unset" : "set"))")
            return nil
        }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr ? deviceID : nil
    }
}
