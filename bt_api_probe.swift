import Foundation
import AVFoundation
import CoreAudio

// Which capture API can bring a Bluetooth mic up BY ITSELF?
//
// Symptom that prompted this: with AirPods, Hush's AVAudioEngine tap binds the
// right device at the right rate (24 kHz) and receives ZERO frames — unless
// System Settings > Sound has the input meter open, i.e. some other process is
// already holding the mic and has forced the headset into call mode. Then it
// works. So the question isn't "which device" but "which API actually asks
// macOS to bring up the SCO link".
//
// A = AVAudioEngine  (what Hush uses today)
// B = AVCaptureSession (what conferencing apps use)
//
// Run with the AirPods connected and System Settings CLOSED:
//   swiftc bt_api_probe.swift -o /tmp/btapi && /tmp/btapi

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
    withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    return name as String
}

// MARK: - A: AVAudioEngine

func testEngine(seconds: TimeInterval) -> (Double, Int) {
    let engine = AVAudioEngine()
    var deviceID = defaultInputDeviceID()
    if let unit = engine.inputNode.audioUnit {
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0,
                             &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
    let format = engine.inputNode.outputFormat(forBus: 0)
    var frames = 0
    let lock = NSLock()
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        lock.lock(); frames += Int(buffer.frameLength); lock.unlock()
    }
    engine.prepare()
    do { try engine.start() } catch {
        print("  engine.start() failed: \(error)")
        return (format.sampleRate, -1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    lock.lock(); let got = frames; lock.unlock()
    return (format.sampleRate, got)
}

// MARK: - B: AVCaptureSession

final class Counter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let lock = NSLock()
    var frames = 0
    var rate: Double = 0
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        frames += CMSampleBufferGetNumSamples(sampleBuffer)
        if rate == 0, let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            rate = asbd.pointee.mSampleRate
        }
        lock.unlock()
    }
}

func testCaptureSession(seconds: TimeInterval) -> (Double, Int) {
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
    // Match the CoreAudio default input device by name.
    let wanted = deviceName(defaultInputDeviceID())
    let device = discovery.devices.first { $0.localizedName == wanted } ?? discovery.devices.first
    guard let device = device else { print("  no AVCaptureDevice found"); return (0, -1) }
    print("  capture device: \(device.localizedName)")

    let session = AVCaptureSession()
    guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
        print("  couldn't create input"); return (0, -1)
    }
    session.addInput(input)
    let output = AVCaptureAudioDataOutput()
    let counter = Counter()
    output.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "probe.capture"))
    guard session.canAddOutput(output) else { print("  couldn't add output"); return (0, -1) }
    session.addOutput(output)

    session.startRunning()
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    session.stopRunning()

    counter.lock.lock(); let got = counter.frames; let rate = counter.rate; counter.lock.unlock()
    return (rate, got)
}

// MARK: - Run

let dev = defaultInputDeviceID()
print("default input: \(deviceName(dev)) (id \(dev))")
print("")
print("A — AVAudioEngine (what Hush uses):")
let (rateA, framesA) = testEngine(seconds: 3.0)
print("  format: \(rateA) Hz, frames: \(framesA)")
print("")
Thread.sleep(forTimeInterval: 1.5)
print("B — AVCaptureSession:")
let (rateB, framesB) = testCaptureSession(seconds: 3.0)
print("  format: \(rateB) Hz, frames: \(framesB)")
print("")
print("VERDICT:")
if framesA <= 0 && framesB > 0 {
    print("  AVCaptureSession works, AVAudioEngine does not — switch Hush's capture API.")
} else if framesA > 0 && framesB > 0 {
    print("  Both work — the mic is up right now; the failure is timing/state, not the API.")
} else if framesA <= 0 && framesB <= 0 {
    print("  Neither API can open this mic — the block is below the app (OS/Bluetooth).")
} else {
    print("  AVAudioEngine works but AVCaptureSession does not (A=\(framesA) B=\(framesB)).")
}
