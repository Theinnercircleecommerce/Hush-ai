//
//  SpeakerNameReader.swift
//  Hush
//
//  Turns screen frames into a timeline of (t, speakerName) ticks by OCR'ing
//  the caption strip Google Meet draws near the bottom of the screen.
//  Entirely on-device (Vision framework); no frame is ever stored or sent
//  anywhere.
//

import Foundation
import Vision
import CoreVideo

/// Pure parsing of one OCR'd line. Meet renders captions as
/// "Name: spoken text".
enum CaptionParser {
    /// Returns the speaker name, or nil when the line isn't a caption.
    static func speakerName(fromOCRLine line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { return nil }
        // A name is a few words; a colon inside sentence text is not.
        guard name.split(separator: " ").count <= 4 else { return nil }
        return name
    }
}

/// Accumulates speaker ticks from frames delivered by
/// `SystemAudioCaptureService`. `process` is called on the capture's frame
/// queue; snapshots are taken from the main actor — hence the lock.
final class SpeakerNameReader {

    /// Bottom-centre strip where Meet renders captions. Vision-normalized
    /// coordinates, origin bottom-left.
    static let captionRegion = CGRect(x: 0.15, y: 0.0, width: 0.7, height: 0.30)

    private var ticks: [SpeakerTick] = []
    private var lastName: String?
    private let lock = NSLock()

    /// OCRs one frame; appends a tick when the caption's speaker changed.
    func process(pixelBuffer: CVPixelBuffer, at t: TimeInterval) {
        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self,
                  let observations = request.results as? [VNRecognizedTextObservation] else { return }
            // Topmost caption line first — its leading token is the name.
            for obs in observations.sorted(by: { $0.boundingBox.minY > $1.boundingBox.minY }) {
                guard let line = obs.topCandidates(1).first?.string,
                      let name = CaptionParser.speakerName(fromOCRLine: line) else { continue }
                self.lock.lock()
                if name != self.lastName {
                    self.ticks.append(SpeakerTick(t: t, name: name))
                    self.lastName = name
                }
                self.lock.unlock()
                break
            }
        }
        request.recognitionLevel = .fast
        request.regionOfInterest = Self.captionRegion
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }

    func snapshotTicks() -> [SpeakerTick] {
        lock.lock(); defer { lock.unlock() }
        return ticks
    }

    /// Distinct speaker names seen so far, in order of first appearance.
    func snapshotNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var seen: [String] = []
        for tick in ticks where !seen.contains(tick.name) { seen.append(tick.name) }
        return seen
    }

    func reset() {
        lock.lock(); ticks = []; lastName = nil; lock.unlock()
    }
}
