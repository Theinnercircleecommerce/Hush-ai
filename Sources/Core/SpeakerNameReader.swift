//
//  SpeakerNameReader.swift
//  Hush
//
//  Turns screen frames into meeting participant names, entirely on-device
//  (Vision framework). No frame is ever stored or sent anywhere.
//
//  Two sources, neither of which the user has to set up:
//
//  1. Participant tile labels — Meet prints each person's name on their
//     video tile. Always visible, no setup. This is the primary source and
//     it is what makes the feature work with zero friction: join, hit
//     record, done.
//  2. Caption lines ("Name: spoken text") — ONLY if the user happens to
//     have Meet's captions turned on. Then we also get a per-moment
//     speaker timeline, which attributes each transcript line exactly.
//     A bonus, never a requirement.
//
//  With (1) alone, the recap call receives the participant list and infers
//  who said what from context ("Sarah, can you send the deck?"). With (2)
//  as well, attribution is exact.
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

/// Decides whether an OCR'd scrap of screen text is a participant's name
/// rather than Meet's own UI chrome.
enum ParticipantNameFilter {

    /// Meet's own on-screen text. Lowercased for comparison. "you" is how
    /// Meet labels the owner's own tile — that person is `Me`, never a
    /// remote participant.
    private static let uiChrome: Set<String> = [
        "you", "present", "presenting", "chat", "people", "activities",
        "details", "meeting details", "host controls", "more options",
        "leave call", "turn on captions", "turn off captions", "captions",
        "raise hand", "share screen", "present now", "mute", "unmute",
        "camera", "microphone", "settings", "whiteboard", "record meeting",
        "joining", "reconnecting", "waiting", "in the meeting", "everyone",
        "contributors", "search", "add people", "info", "security"
    ]

    /// True when `text` looks like a person's display name.
    ///
    /// Meet tile labels are short, capitalised, and free of punctuation and
    /// digits. Anything failing those tests is chrome, a timestamp, or body
    /// text the OCR happened to catch.
    static func isPlausibleName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return false }
        guard !uiChrome.contains(trimmed.lowercased()) else { return false }

        let words = trimmed.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }

        // Names carry no digits and none of the punctuation Meet's UI uses.
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let banned = CharacterSet(charactersIn: ":·•()[]{}<>/\\|@#$%^&*_=+")
        guard trimmed.rangeOfCharacter(from: banned) == nil else { return false }

        // Must start with a capital letter — Meet capitalises display names,
        // its own chrome labels are frequently lowercase mid-sentence text.
        guard let first = trimmed.first, first.isLetter, first.isUppercase else { return false }

        // Every word must be letter-led (rules out "- Sarah", "1080p").
        return words.allSatisfy { $0.first?.isLetter == true }
    }
}

/// Accumulates participant names (and, when captions happen to be on, a
/// speaker timeline) from frames delivered by `SystemAudioCaptureService`.
///
/// `process` is called on the capture's frame queue; snapshots are taken
/// from the main actor — hence the lock.
final class SpeakerNameReader {

    /// Bottom-centre strip where Meet renders captions, when they're on.
    /// Vision-normalized coordinates, origin bottom-left.
    static let captionRegion = CGRect(x: 0.15, y: 0.0, width: 0.7, height: 0.30)

    /// A name must be seen in this many separate frames before it counts as
    /// a participant. One-frame OCR misreads are common; a real tile label
    /// is on screen for the whole call, so this costs nothing real and
    /// discards nearly all noise.
    static let sightingsRequired = 3

    private var ticks: [SpeakerTick] = []
    private var lastName: String?
    /// Name -> how many frames it has been seen in.
    private var nameSightings: [String: Int] = [:]
    /// Preserves first-appearance order for `snapshotNames`.
    private var nameOrder: [String] = []
    private let lock = NSLock()

    /// OCRs one frame: harvests participant names from tile labels, and — if
    /// captions are on — appends a tick when the caption's speaker changed.
    func process(pixelBuffer: CVPixelBuffer, at t: TimeInterval) {
        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self,
                  let observations = request.results as? [VNRecognizedTextObservation] else { return }

            var captionName: String?
            var namesThisFrame: Set<String> = []

            // Topmost line first, so the caption check sees the newest
            // caption row before older ones scroll past.
            for obs in observations.sorted(by: { $0.boundingBox.minY > $1.boundingBox.minY }) {
                guard let line = obs.topCandidates(1).first?.string else { continue }

                // Caption line — only present when the user has captions on.
                if captionName == nil,
                   obs.boundingBox.minY < Self.captionRegion.maxY,
                   let name = CaptionParser.speakerName(fromOCRLine: line) {
                    captionName = name
                }

                // Tile label — the zero-setup path.
                if ParticipantNameFilter.isPlausibleName(line) {
                    namesThisFrame.insert(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            self.lock.lock()
            for name in namesThisFrame {
                let count = (self.nameSightings[name] ?? 0) + 1
                self.nameSightings[name] = count
                if count == Self.sightingsRequired { self.nameOrder.append(name) }
            }
            if let captionName, captionName != self.lastName {
                self.ticks.append(SpeakerTick(t: t, name: captionName))
                self.lastName = captionName
            }
            self.lock.unlock()
        }
        request.recognitionLevel = .fast
        // Whole frame: tile labels sit anywhere on screen, not just in the
        // caption strip.
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }

    /// Per-moment speaker timeline. Empty unless the user had captions on —
    /// `TranscriptMerger` then labels remote speech "Someone else" and the
    /// recap call attributes it from context using `snapshotNames()`.
    func snapshotTicks() -> [SpeakerTick] {
        lock.lock(); defer { lock.unlock() }
        return ticks
    }

    /// Participants seen on screen, in order of first appearance. Includes
    /// anyone a caption named, plus every tile label that cleared
    /// `sightingsRequired`.
    func snapshotNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var seen: [String] = []
        for tick in ticks where !seen.contains(tick.name) { seen.append(tick.name) }
        for name in nameOrder where !seen.contains(name) { seen.append(name) }
        return seen
    }

    func reset() {
        lock.lock()
        ticks = []
        lastName = nil
        nameSightings = [:]
        nameOrder = []
        lock.unlock()
    }
}
