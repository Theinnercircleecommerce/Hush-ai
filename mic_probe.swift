import Foundation
import AVFoundation
import CoreAudio

// Returns true if the default input device is running (in use) by ANY process
func micInUse() -> Bool {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)

    var running = UInt32(0)
    var rSize = UInt32(MemoryLayout<UInt32>.size)
    var rAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(deviceID, &rAddr, 0, nil, &rSize, &running)
    return running != 0
}

print("baseline:            mic in use = \(micInUse())")

// Same capture pattern as AudioCaptureService.startRecording()
let url = FileManager.default.temporaryDirectory.appendingPathComponent("hush_probe.caf")
try? FileManager.default.removeItem(at: url)

var engine: AVAudioEngine? = AVAudioEngine()
let inputFormat = engine!.inputNode.outputFormat(forBus: 0)
print("input format:        \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")

var audioFile: AVAudioFile? = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
engine!.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
    try? audioFile?.write(from: buffer)
}
engine!.prepare()
try engine!.start()
Thread.sleep(forTimeInterval: 2.0)
print("while recording:     mic in use = \(micInUse())")

// Same teardown as AudioCaptureService.stopRecording()
engine!.inputNode.removeTap(onBus: 0)
engine!.stop()
engine = nil
audioFile = nil

for i in 1...3 {
    Thread.sleep(forTimeInterval: 1.0)
    print("after teardown +\(i)s:  mic in use = \(micInUse())")
}

let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
print("recorded file size:  \(size ?? 0) bytes at \(url.path)")
