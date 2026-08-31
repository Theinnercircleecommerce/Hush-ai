import Foundation
import AVFoundation
import CoreAudio

// A/B probe for the Bluetooth dead-tap bug.
//
// Theory: AirPods publish TWO CoreAudio devices — an output-only device at
// 48 kHz and an input-only device at a lower rate. AudioCaptureService only
// binds the engine's input unit when the user has explicitly picked a mic
// (`guard !uid.isEmpty` in applySelectedMicrophone). With no mic picked, the
// engine chooses its own device, lands on the 48 kHz OUTPUT side, and the tap
// is installed with a format the mic never produces — so zero buffers arrive
// and the .caf is a 4096-byte header.
//
// Run this with the Bluetooth headphones set as system input:
//   swiftc bt_mic_probe.swift -o /tmp/btprobe && /tmp/btprobe

func defaultInputDeviceID() -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    return deviceID
}

func deviceName(_ id: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
    return name as String
}

func nominalRate(_ id: AudioDeviceID) -> Double {
    var rate = Double(0)
    var size = UInt32(MemoryLayout<Double>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
    return rate
}

/// Records for `seconds` and returns (format the tap was installed with, frames actually received).
func runTake(label: String, bindDefaultInput: Bool, seconds: TimeInterval) -> (Double, Int) {
    let engine = AVAudioEngine()

    if bindDefaultInput, let unit = engine.inputNode.audioUnit {
        var deviceID = defaultInputDeviceID()
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        print("  bound input unit to device \(deviceID) — status \(status)")
    }

    let format = engine.inputNode.outputFormat(forBus: 0)
    var frames = 0
    let lock = NSLock()

    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        lock.lock(); frames += Int(buffer.frameLength); lock.unlock()
    }

    engine.prepare()
    do {
        try engine.start()
    } catch {
        print("  engine.start() FAILED: \(error)")
        return (format.sampleRate, -1)
    }
    Thread.sleep(forTimeInterval: seconds)
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    lock.lock(); let got = frames; lock.unlock()
    return (format.sampleRate, got)
}

let devID = defaultInputDeviceID()
print("default input device: \(deviceName(devID)) (id \(devID))")
print("its nominal input rate: \(nominalRate(devID)) Hz")
print("")

print("A — CURRENT SHIPPED PATH (no explicit device binding):")
let (fmtA, framesA) = runTake(label: "A", bindDefaultInput: false, seconds: 2.0)
print("  tap format: \(fmtA) Hz")
print("  frames received: \(framesA)")
print("")

Thread.sleep(forTimeInterval: 1.0)

print("B — PROPOSED FIX (bind input unit to default input device first):")
let (fmtB, framesB) = runTake(label: "B", bindDefaultInput: true, seconds: 2.0)
print("  tap format: \(fmtB) Hz")
print("  frames received: \(framesB)")
print("")

print("VERDICT:")
if framesA == 0 && framesB > 0 {
    print("  CONFIRMED. Current path gets zero buffers; explicit binding fixes it.")
} else if framesA > 0 && framesB > 0 {
    print("  Both paths captured audio — the dead tap did NOT reproduce this run.")
} else if framesA == 0 && framesB == 0 {
    print("  Both paths got zero buffers — binding is not the (only) cause. Different bug.")
} else {
    print("  Unexpected: A=\(framesA) B=\(framesB)")
}
