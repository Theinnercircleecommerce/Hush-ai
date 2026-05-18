import AppKit
let symbols = ["waveform.path", "lines.measurement.horizontal"]
for s in symbols {
    let img = NSImage(systemSymbolName: s, accessibilityDescription: nil)
    print("\(s): \(img != nil)")
}
