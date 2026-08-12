# Meeting Recap (Phase 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record a Google Meet call (mic + system audio), attribute lines to named speakers via on-device caption OCR, and produce a Claude recap with per-person action items — all stored locally.

**Architecture:** One new `SCStream` captures system audio and low-rate screen frames; frames feed Vision OCR that reads speaker names off Meet's captions. A `MeetingSession` orchestrator owns its own mic recorder, transcribes both audio files with WhisperKit, merges by timestamp, makes one non-streaming Claude call, and saves to a new `meeting` table. UI is one new nudge-menu page plus repurposing a dead placeholder button.

**Tech Stack:** Swift 5.9 SPM executable, AVFoundation, ScreenCaptureKit, Vision, WhisperKit 0.9, GRDB 6, raw URLSession (no HTTP libs).

**Spec:** `docs/superpowers/specs/2026-08-12-meeting-recap-design.md` — read it first.

## Global Constraints

- **Do not modify `AudioCaptureService.swift`'s recording logic.** Fresh `AVAudioEngine` per press is load-bearing (commit 896e82f reverted an "improvement" that silently broke recording). `MeetingSession` creates its **own instance** of the class; the class itself is untouched.
- **Do not touch `ClaudeVisionClient.swift`.** The recap uses a new, separate service.
- **Never write meeting content (transcripts, names, recaps) to any log file.** Lengths and error codes only.
- Build check: `swift build 2>&1 | tail -5`. Tests: `swift test 2>&1 | tail -15`. Do **not** run `build.sh` with `HUSH_INSTALL=1`; never copy anything to `/Applications`.
- The nudge panel window is fixed-size; all animation is SwiftUI-internal. Do not animate any `NSPanel`/window frame.
- Commit after every task with the exact message given.
- macOS deployment target is 14.0 — all APIs used here (SCStream audio capture, `CMSampleBuffer.withAudioBufferList`, `TimelineView`) exist on 14.0.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Models/MeetingModels.swift` (new) | Value types: `TranscriptSegment`, `SpeakerTick`, `AttributedLine`, `ActionItem`, `MeetingRecapResult` |
| `Sources/Core/TranscriptMerger.swift` (new) | Pure merge of two segment lists + speaker timeline |
| `Sources/Core/SpeakerNameReader.swift` (new) | `CaptionParser` (pure) + Vision OCR wrapper over frames |
| `Sources/Models/Meeting.swift` (new) | GRDB record + `createTable` |
| `Sources/Core/MeetingStore.swift` (new) | Save/fetch/delete meetings; `@Published` list |
| `Sources/Core/MeetingRecapService.swift` (new) | One non-streaming Claude call; prompt build + JSON parse |
| `Sources/Core/SystemAudioCaptureService.swift` (new) | SCStream → 16 kHz mono CAF + 0.5 fps frames |
| `Sources/Core/MeetingSession.swift` (new) | Orchestrator + state machine for the pill |
| `Sources/Core/HistoryStore.swift` (modify) | Register migration `v4` |
| `Sources/Core/AppState.swift`, `Sources/Core/TalkSession.swift` (modify) | Mic-ownership guards |
| `Sources/UI/NudgeMenuView.swift` (modify) | `.meetings` page, LIBRARY row, Record Call pill, meetings list/detail |
| `Tests/HushTests/*` (new) | Unit tests for the pure logic |
| `Package.swift` (modify) | Add test target |

---

### Task 1: Test target + meeting value types

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Models/MeetingModels.swift`
- Test: `Tests/HushTests/MeetingModelsTests.swift`

**Interfaces:**
- Produces: `TranscriptSegment(start:end:text:)`, `SpeakerTick(t:name:)`, `AttributedLine(t:speaker:text:)`, `ActionItem(owner:task:)`, `MeetingRecapResult(title:recap:actionItems:)` — all `Codable`, `Equatable`. Every later task consumes these exact names.

- [ ] **Step 1: Add the test target to Package.swift**

Append to the `targets:` array (after the executable target):

```swift
        .testTarget(
            name: "HushTests",
            dependencies: ["Hush"],
            path: "Tests"
        )
```

- [ ] **Step 2: Write the failing test**

Create `Tests/HushTests/MeetingModelsTests.swift`:

```swift
import XCTest
@testable import Hush

final class MeetingModelsTests: XCTestCase {
    func testAttributedLineRoundTripsThroughJSON() throws {
        let lines = [
            AttributedLine(t: 0.0, speaker: "Me", text: "hello"),
            AttributedLine(t: 3.2, speaker: "Sarah", text: "hi there"),
        ]
        let data = try JSONEncoder().encode(lines)
        let decoded = try JSONDecoder().decode([AttributedLine].self, from: data)
        XCTAssertEqual(decoded, lines)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test 2>&1 | tail -15`
Expected: FAIL — `cannot find 'AttributedLine' in scope`.

- [ ] **Step 4: Create the models**

Create `Sources/Models/MeetingModels.swift`:

```swift
//
//  MeetingModels.swift
//  Hush
//
//  Value types shared by the meeting-recap pipeline (Phase 6).
//

import Foundation

/// One Whisper segment from one audio file. Times are seconds from that
/// file's start.
struct TranscriptSegment: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// "At time t, Meet's caption named this speaker." Emitted only when the
/// name changes, so consecutive ticks always differ.
struct SpeakerTick: Codable, Equatable {
    let t: TimeInterval
    let name: String
}

/// One attributed line of the merged meeting transcript.
struct AttributedLine: Codable, Equatable {
    let t: TimeInterval
    let speaker: String
    let text: String
}

/// One commitment extracted by the recap call.
struct ActionItem: Codable, Equatable {
    let owner: String
    let task: String
}

/// Parsed result of the recap call.
struct MeetingRecapResult: Equatable {
    let title: String
    let recap: String
    let actionItems: [ActionItem]
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed`. (First run compiles the whole app + WhisperKit — several minutes is normal.)

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/Models/MeetingModels.swift Tests/HushTests/MeetingModelsTests.swift
git commit -m "feat: meeting value types + first test target"
```

---

### Task 2: TranscriptMerger

**Files:**
- Create: `Sources/Core/TranscriptMerger.swift`
- Test: `Tests/HushTests/TranscriptMergerTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment`, `SpeakerTick`, `AttributedLine` (Task 1).
- Produces: `TranscriptMerger.merge(micSegments:systemSegments:speakerTicks:) -> [AttributedLine]`, `TranscriptMerger.speaker(at:in:) -> String`, constants `TranscriptMerger.meSpeaker == "Me"`, `TranscriptMerger.unknownSpeaker == "Someone else"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/HushTests/TranscriptMergerTests.swift`:

```swift
import XCTest
@testable import Hush

final class TranscriptMergerTests: XCTestCase {

    func testMicSegmentsAreAlwaysMe() {
        let lines = TranscriptMerger.merge(
            micSegments: [TranscriptSegment(start: 1, end: 3, text: "my line")],
            systemSegments: [],
            speakerTicks: [SpeakerTick(t: 0, name: "Sarah")]
        )
        XCTAssertEqual(lines, [AttributedLine(t: 1, speaker: "Me", text: "my line")])
    }

    func testSystemSegmentTakesTickActiveAtMidpoint() {
        // Segment spans 4...10, midpoint 7. Sarah spoke at t=2, Tom at t=6.
        // Tom is active at the midpoint even though Sarah was active at start.
        let lines = TranscriptMerger.merge(
            micSegments: [],
            systemSegments: [TranscriptSegment(start: 4, end: 10, text: "ship friday")],
            speakerTicks: [SpeakerTick(t: 2, name: "Sarah"), SpeakerTick(t: 6, name: "Tom")]
        )
        XCTAssertEqual(lines, [AttributedLine(t: 4, speaker: "Tom", text: "ship friday")])
    }

    func testNoTickBeforeMidpointFallsBackToSomeoneElse() {
        let lines = TranscriptMerger.merge(
            micSegments: [],
            systemSegments: [TranscriptSegment(start: 0, end: 2, text: "early words")],
            speakerTicks: [SpeakerTick(t: 5, name: "Sarah")]
        )
        XCTAssertEqual(lines.first?.speaker, "Someone else")
    }

    func testOutputIsChronologicalAcrossBothStreams() {
        let lines = TranscriptMerger.merge(
            micSegments: [TranscriptSegment(start: 5, end: 6, text: "me later")],
            systemSegments: [TranscriptSegment(start: 1, end: 2, text: "them first")],
            speakerTicks: [SpeakerTick(t: 0, name: "Sarah")]
        )
        XCTAssertEqual(lines.map(\.text), ["them first", "me later"])
    }

    func testBlankSegmentsAreDropped() {
        let lines = TranscriptMerger.merge(
            micSegments: [TranscriptSegment(start: 0, end: 1, text: "   ")],
            systemSegments: [TranscriptSegment(start: 2, end: 3, text: "")],
            speakerTicks: []
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func testUnsortedTicksAreHandled() {
        XCTAssertEqual(
            TranscriptMerger.speaker(at: 7, in: [SpeakerTick(t: 6, name: "Tom"), SpeakerTick(t: 2, name: "Sarah")].sorted { $0.t < $1.t }),
            "Tom"
        )
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TranscriptMergerTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'TranscriptMerger' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/Core/TranscriptMerger.swift`:

```swift
//
//  TranscriptMerger.swift
//  Hush
//
//  Pure merge of the meeting's two transcripts. Mic segments are the owner;
//  system segments are attributed via the caption-derived speaker timeline.
//

import Foundation

enum TranscriptMerger {

    static let meSpeaker = "Me"
    static let unknownSpeaker = "Someone else"

    /// System segments take the name of the tick active at the segment's
    /// MIDPOINT, not its start — Meet's captions lag speech by about a
    /// second, so start-time matching mis-assigns the first words of a turn.
    static func merge(micSegments: [TranscriptSegment],
                      systemSegments: [TranscriptSegment],
                      speakerTicks: [SpeakerTick]) -> [AttributedLine] {
        let ticks = speakerTicks.sorted { $0.t < $1.t }
        var lines: [AttributedLine] = []

        for seg in micSegments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(AttributedLine(t: seg.start, speaker: meSpeaker, text: text))
        }
        for seg in systemSegments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let midpoint = (seg.start + seg.end) / 2
            lines.append(AttributedLine(t: seg.start,
                                        speaker: speaker(at: midpoint, in: ticks),
                                        text: text))
        }
        return lines.sorted { $0.t < $1.t }
    }

    /// Latest tick at or before `t`, or `unknownSpeaker` when none precedes it.
    /// `sortedTicks` must be ascending by `t`.
    static func speaker(at t: TimeInterval, in sortedTicks: [SpeakerTick]) -> String {
        var current = unknownSpeaker
        for tick in sortedTicks {
            if tick.t <= t { current = tick.name } else { break }
        }
        return current
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TranscriptMergerTests 2>&1 | tail -5`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/TranscriptMerger.swift Tests/HushTests/TranscriptMergerTests.swift
git commit -m "feat: transcript merger with midpoint speaker attribution"
```

---

### Task 3: CaptionParser + SpeakerNameReader

**Files:**
- Create: `Sources/Core/SpeakerNameReader.swift`
- Test: `Tests/HushTests/CaptionParserTests.swift`

**Interfaces:**
- Consumes: `SpeakerTick` (Task 1).
- Produces: `CaptionParser.speakerName(fromOCRLine:) -> String?` (pure, tested); `SpeakerNameReader` class with `process(pixelBuffer:at:)`, `snapshotTicks() -> [SpeakerTick]`, `snapshotNames() -> [String]`, `reset()` (OCR wrapper, owner-QA only).

- [ ] **Step 1: Write the failing tests**

Create `Tests/HushTests/CaptionParserTests.swift`:

```swift
import XCTest
@testable import Hush

final class CaptionParserTests: XCTestCase {

    func testPlainCaptionLine() {
        XCTAssertEqual(CaptionParser.speakerName(fromOCRLine: "Sarah Chen: we should ship on friday"), "Sarah Chen")
    }

    func testWhitespaceAroundNameIsStripped() {
        XCTAssertEqual(CaptionParser.speakerName(fromOCRLine: "  Tom : sounds good"), "Tom")
    }

    func testLineWithoutColonIsNotACaption() {
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: "Meeting details"))
    }

    func testEmptyNameIsRejected() {
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: ": stray colon"))
    }

    func testSentenceBeforeColonIsRejected() {
        // OCR grabbed body text containing a colon — five+ words is a
        // sentence, not a name.
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: "here is the thing we discussed: budgets"))
    }

    func testAbsurdlyLongNameIsRejected() {
        let junk = String(repeating: "x", count: 60)
        XCTAssertNil(CaptionParser.speakerName(fromOCRLine: "\(junk): hi"))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CaptionParserTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'CaptionParser' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/Core/SpeakerNameReader.swift`:

```swift
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter CaptionParserTests 2>&1 | tail -5`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/SpeakerNameReader.swift Tests/HushTests/CaptionParserTests.swift
git commit -m "feat: caption parser + on-device speaker name OCR"
```

---

### Task 4: Meeting record, migration v4, MeetingStore

**Files:**
- Create: `Sources/Models/Meeting.swift`, `Sources/Core/MeetingStore.swift`
- Modify: `Sources/Core/HistoryStore.swift` (after the `v3` migration block, ~line 66)
- Test: `Tests/HushTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: `AttributedLine`, `ActionItem` (Task 1); `HistoryStore.shared.dbQueue`.
- Produces: `Meeting` GRDB record with fields `id: String`, `startedAt: Date`, `duration: Double`, `title: String`, `participants: String` (JSON `[String]`), `transcript: String` (JSON `[AttributedLine]`), `recap: String?`, `actionItems: String?` (JSON `[ActionItem]`), `recapFailed: Bool`; helpers `participantList: [String]`, `lines: [AttributedLine]`, `actionItemList: [ActionItem]`, `static func createTable(_ db: Database)`. `MeetingStore(dbQueue:)` with `@Published meetings: [Meeting]`, `save(_:)`, `delete(id:)`, `refresh()`, `static let shared`.

- [ ] **Step 1: Write the failing test**

Create `Tests/HushTests/MeetingStoreTests.swift`:

```swift
import XCTest
import GRDB
@testable import Hush

final class MeetingStoreTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()   // in-memory
        try queue.write { db in try Meeting.createTable(db) }
        return queue
    }

    func testSaveAndFetchRoundTrip() throws {
        let queue = try makeQueue()
        let lines = [AttributedLine(t: 0, speaker: "Me", text: "hi")]
        let meeting = Meeting(
            id: "m1",
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            duration: 120,
            title: "Standup",
            participants: Meeting.encode(["Me", "Sarah"]),
            transcript: Meeting.encode(lines),
            recap: "we said hi",
            actionItems: Meeting.encode([ActionItem(owner: "Sarah", task: "send deck")]),
            recapFailed: false
        )
        try queue.write { db in try meeting.save(db) }

        let fetched = try queue.read { db in try Meeting.fetchOne(db, key: "m1") }
        XCTAssertEqual(fetched?.title, "Standup")
        XCTAssertEqual(fetched?.participantList, ["Me", "Sarah"])
        XCTAssertEqual(fetched?.lines, lines)
        XCTAssertEqual(fetched?.actionItemList, [ActionItem(owner: "Sarah", task: "send deck")])
    }

    func testDelete() throws {
        let queue = try makeQueue()
        let store = MeetingStore(dbQueue: queue)
        let meeting = Meeting(
            id: "m2", startedAt: Date(), duration: 60, title: "t",
            participants: "[]", transcript: "[]",
            recap: nil, actionItems: nil, recapFailed: true
        )
        store.save(meeting)
        store.delete(id: "m2")
        let count = try queue.read { db in try Meeting.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MeetingStoreTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'Meeting' in scope`.

- [ ] **Step 3: Create the record**

Create `Sources/Models/Meeting.swift`:

```swift
//
//  Meeting.swift
//  Hush
//
//  One recorded meeting. Transcript, participants, and action items are
//  stored as JSON strings — GRDB columns stay flat, Codable does the rest.
//

import Foundation
import GRDB

struct Meeting: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord {
    var id: String
    var startedAt: Date
    var duration: Double
    var title: String
    var participants: String     // JSON [String]
    var transcript: String       // JSON [AttributedLine]
    var recap: String?           // markdown; nil when recapFailed
    var actionItems: String?     // JSON [ActionItem]
    var recapFailed: Bool

    static let databaseTableName = "meeting"

    /// Called from HistoryStore's v4 migration AND from tests, so the test
    /// schema can never drift from the shipped one.
    static func createTable(_ db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("id", .text).primaryKey()
            t.column("startedAt", .datetime).notNull()
            t.column("duration", .double).notNull()
            t.column("title", .text).notNull()
            t.column("participants", .text).notNull()
            t.column("transcript", .text).notNull()
            t.column("recap", .text)
            t.column("actionItems", .text)
            t.column("recapFailed", .boolean).notNull()
        }
        try db.create(index: "meeting_on_startedAt",
                      on: databaseTableName,
                      columns: ["startedAt"])
    }

    // MARK: - JSON helpers

    static func encode<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    var participantList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(participants.utf8))) ?? []
    }
    var lines: [AttributedLine] {
        (try? JSONDecoder().decode([AttributedLine].self, from: Data(transcript.utf8))) ?? []
    }
    var actionItemList: [ActionItem] {
        guard let actionItems else { return [] }
        return (try? JSONDecoder().decode([ActionItem].self, from: Data(actionItems.utf8))) ?? []
    }
}
```

- [ ] **Step 4: Create the store**

Create `Sources/Core/MeetingStore.swift`:

```swift
//
//  MeetingStore.swift
//  Hush
//
//  Same threading shape as HistoryStore/UsageStore: writes on the GRDB
//  queue, @Published state assigned on the main thread.
//

import Foundation
import GRDB
import Combine

final class MeetingStore: ObservableObject {

    static let shared = MeetingStore(dbQueue: HistoryStore.shared.dbQueue)

    /// Newest first.
    @Published private(set) var meetings: [Meeting] = []

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        refresh()
    }

    func refresh() {
        let rows = (try? dbQueue.read { db in
            try Meeting.order(Column("startedAt").desc).fetchAll(db)
        }) ?? []
        if Thread.isMainThread {
            meetings = rows
        } else {
            DispatchQueue.main.async { self.meetings = rows }
        }
    }

    func save(_ meeting: Meeting) {
        try? dbQueue.write { db in try meeting.save(db) }
        refresh()
    }

    func delete(id: String) {
        _ = try? dbQueue.write { db in try Meeting.deleteOne(db, key: id) }
        refresh()
    }
}
```

- [ ] **Step 5: Register migration v4**

In `Sources/Core/HistoryStore.swift`, directly after the `v3` migration's closing brace (the block ending with `usageEvent_on_timestamp` index creation, ~line 66), add:

```swift
            // Phase 6: recorded meetings. Table shape lives in Meeting.swift
            // so tests build the identical schema.
            migrator.registerMigration("v4") { db in
                try Meeting.createTable(db)
            }
```

- [ ] **Step 6: Run to verify tests pass**

Run: `swift test --filter MeetingStoreTests 2>&1 | tail -5`
Expected: 2 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Models/Meeting.swift Sources/Core/MeetingStore.swift Sources/Core/HistoryStore.swift Tests/HushTests/MeetingStoreTests.swift
git commit -m "feat: meeting table (migration v4) + MeetingStore"
```

---

### Task 5: MeetingRecapService

**Files:**
- Create: `Sources/Core/MeetingRecapService.swift`
- Test: `Tests/HushTests/MeetingRecapServiceTests.swift`

**Interfaces:**
- Consumes: `AttributedLine`, `ActionItem`, `MeetingRecapResult` (Task 1); `KeychainStore.get(.anthropic)`; `UsageStore.shared.recordClaude(model:inputTokens:outputTokens:)`.
- Produces: `MeetingRecapService.recap(lines:participants:) async throws -> MeetingRecapResult`; pure helpers `formatTranscript(_:) -> String` and `parse(_:) -> MeetingRecapResult?`; `MeetingRecapError` enum.

**Why not `ClaudeVisionClient`:** it records every exchange into circle-to-ask's follow-up history; a meeting transcript must never leak into a later circle-to-ask context. This service is non-streaming, stateless, and images-free.

- [ ] **Step 1: Write the failing tests**

Create `Tests/HushTests/MeetingRecapServiceTests.swift`:

```swift
import XCTest
@testable import Hush

final class MeetingRecapServiceTests: XCTestCase {

    func testFormatTranscriptUsesMinutesSecondsAndSpeaker() {
        let text = MeetingRecapService.formatTranscript([
            AttributedLine(t: 192, speaker: "Sarah", text: "ship friday"),
        ])
        XCTAssertEqual(text, "[03:12] Sarah: ship friday")
    }

    func testParseCleanJSON() {
        let result = MeetingRecapService.parse(
            #"{"title": "Launch sync", "recap": "we agreed to ship.", "action_items": [{"owner": "Sarah", "task": "send deck"}]}"#
        )
        XCTAssertEqual(result?.title, "Launch sync")
        XCTAssertEqual(result?.actionItems, [ActionItem(owner: "Sarah", task: "send deck")])
    }

    func testParseTolieratesMarkdownFences() {
        let fenced = """
        ```json
        {"title": "t", "recap": "r", "action_items": []}
        ```
        """
        XCTAssertEqual(MeetingRecapService.parse(fenced)?.recap, "r")
    }

    func testParseMissingRequiredKeyReturnsNil() {
        XCTAssertNil(MeetingRecapService.parse(#"{"recap": "no title here"}"#))
    }

    func testParseMalformedActionItemsAreSkippedNotFatal() {
        let result = MeetingRecapService.parse(
            #"{"title": "t", "recap": "r", "action_items": [{"owner": "Sarah"}, {"owner": "Tom", "task": "book room"}]}"#
        )
        XCTAssertEqual(result?.actionItems, [ActionItem(owner: "Tom", task: "book room")])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter MeetingRecapServiceTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'MeetingRecapService' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/Core/MeetingRecapService.swift`:

```swift
//
//  MeetingRecapService.swift
//  Hush
//
//  One non-streaming Claude call per meeting: labelled transcript in,
//  {title, recap, action items} out. Deliberately separate from
//  ClaudeVisionClient — that client streams, keeps circle-to-ask follow-up
//  history, and meeting transcripts must never enter that history.
//

import Foundation

enum MeetingRecapError: LocalizedError {
    case missingKey
    case http(Int, String)
    case network(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "add your anthropic api key in settings"
        case .http(let status, let body):
            let shown = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            return shown.isEmpty ? "claude returned an error (\(status))"
                                 : "claude returned an error (\(status)): \(shown)"
        case .network(let error): return "couldn't reach claude: \(error.localizedDescription)"
        case .badResponse: return "claude's recap couldn't be read"
        }
    }
}

enum MeetingRecapService {

    static let model = "claude-sonnet-4-6"
    static let maxTokens = 2000
    /// A long transcript takes a while to ingest; the 20 s circle-to-ask
    /// timeout is far too tight here.
    static let timeout: TimeInterval = 120

    static let systemPrompt = """
    You summarize meeting transcripts. The speaker "Me" is the user of this \
    app; other speakers are named as Google Meet's captions showed them, and \
    "Someone else" marks lines that couldn't be attributed. Reply with ONLY a \
    JSON object, no markdown fences, exactly this shape:
    {"title": "...", "recap": "...", "action_items": [{"owner": "...", "task": "..."}]}
    - "title": at most 8 words naming the meeting's subject.
    - "recap": 5-10 plain-text sentences covering topics, decisions, and outcomes.
    - "action_items": every commitment made, one entry per task, owner exactly \
    as named in the transcript. Empty array if none.
    """

    /// "[03:12] Sarah: ship friday" — one line per attributed line.
    static func formatTranscript(_ lines: [AttributedLine]) -> String {
        lines.map { line in
            let minutes = Int(line.t) / 60
            let seconds = Int(line.t) % 60
            return String(format: "[%02d:%02d] %@: %@", minutes, seconds, line.speaker, line.text)
        }.joined(separator: "\n")
    }

    /// Extracts the outermost JSON object; tolerates fences and stray prose.
    static func parse(_ text: String) -> MeetingRecapResult? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String,
              let recap = object["recap"] as? String
        else { return nil }

        let items = (object["action_items"] as? [[String: Any]] ?? []).compactMap { item -> ActionItem? in
            guard let owner = item["owner"] as? String,
                  let task = item["task"] as? String else { return nil }
            return ActionItem(owner: owner, task: task)
        }
        return MeetingRecapResult(title: title, recap: recap, actionItems: items)
    }

    static func recap(lines: [AttributedLine],
                      participants: [String]) async throws -> MeetingRecapResult {
        guard let apiKey = KeychainStore.get(.anthropic) else {
            throw MeetingRecapError.missingKey
        }

        let userMessage = "Participants: \(participants.joined(separator: ", "))\n\nTranscript:\n"
            + formatTranscript(lines)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MeetingRecapError.network(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw MeetingRecapError.http(status, String(data: data.prefix(8192), encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingRecapError.badResponse
        }

        // Anthropic bills whatever it generated — record before parse can fail.
        if let usage = object["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            await MainActor.run {
                UsageStore.shared.recordClaude(model: model, inputTokens: input, outputTokens: output)
            }
        }

        let text = ((object["content"] as? [[String: Any]]) ?? [])
            .compactMap { $0["text"] as? String }
            .joined()
        guard let result = parse(text) else { throw MeetingRecapError.badResponse }
        return result
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter MeetingRecapServiceTests 2>&1 | tail -5`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/MeetingRecapService.swift Tests/HushTests/MeetingRecapServiceTests.swift
git commit -m "feat: non-streaming meeting recap client"
```

---

### Task 6: transcribeSegments on LocalTranscriptionService

**Files:**
- Modify: `Sources/Core/LocalTranscriptionService.swift`

**Interfaces:**
- Consumes: existing private `whisperKitTask` setup (duplicate the model-resolution block exactly as `transcribe` does — do not refactor the existing method).
- Produces: `transcribeSegments(fileURL:modelSize:language:) async throws -> [TranscriptSegment]`.

No unit test — WhisperKit needs a downloaded model. Verified by compile here and owner QA in Task 10.

- [ ] **Step 1: Add the method**

Append inside `class LocalTranscriptionService`, after the existing `transcribe` method:

```swift
    /// Like `transcribe`, but returns per-segment timestamps for the meeting
    /// merger. WhisperKit windows long audio internally (30 s frames) and
    /// reports absolute segment times, so no external chunking is needed.
    func transcribeSegments(fileURL: URL,
                            modelSize: String,
                            language: String? = nil) async throws -> [TranscriptSegment] {
        var actualModel = modelSize
        let allowedModels = ["tiny", "tiny.en", "base", "base.en", "small", "small.en", "distil-large-v3", "large-v3", "large-v3-turbo"]
        if !allowedModels.contains(actualModel) {
            actualModel = "base"
        }

        if currentModelSize != actualModel || whisperKitTask == nil {
            whisperKitTask?.cancel()
            currentModelSize = actualModel
            whisperKitTask = Task {
                let processor = AudioProcessor()
                processor.audioEngine = nil // Destroy AVAudioEngine so macOS drops the mic privacy indicator

                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let downloadBase = appSupport.appendingPathComponent("HushAI_WhisperKit", isDirectory: true)
                try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

                return try await WhisperKit(model: actualModel, downloadBase: downloadBase, audioProcessor: processor)
            }
        }

        let pipe: WhisperKit
        do {
            pipe = try await whisperKitTask!.value
        } catch {
            throw LocalTranscriptionError.initializationFailed(error.localizedDescription)
        }

        var options = DecodingOptions()
        if let l = language, !l.isEmpty, l != "Auto-detect" {
            options.language = l
        }

        let results = try await pipe.transcribe(audioPath: fileURL.path, decodeOptions: options)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                // Strip Whisper's special tokens like <|startoftranscript|>.
                let text = seg.text
                    .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(start: TimeInterval(seg.start),
                                                  end: TimeInterval(seg.end),
                                                  text: text))
            }
        }
        return segments
    }
```

- [ ] **Step 2: Compile**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` If `result.segments` or `seg.start`/`seg.end` fail to compile, check WhisperKit 0.9's `TranscriptionResult`/`TranscriptionSegment` definitions in `~/.build/checkouts/WhisperKit/Sources/WhisperKit/Core/Models.swift` (fields are `segments`, `start: Float`, `end: Float`, `text: String`) and adjust casts only.

- [ ] **Step 3: Commit**

```bash
git add Sources/Core/LocalTranscriptionService.swift
git commit -m "feat: segment-timestamped transcription for meetings"
```

---

### Task 7: SystemAudioCaptureService

**Files:**
- Create: `Sources/Core/SystemAudioCaptureService.swift`

**Interfaces:**
- Consumes: `ScreenCaptureError` (defined in `ScreenCaptureService.swift`).
- Produces: `SystemAudioCaptureService` class: `var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?`, `func start(excluding: [NSWindow]) async throws`, `func stop() async -> URL?` (returns the 16 kHz mono CAF of system audio).

Not unit-testable (needs live SCStream) — compile check here, owner QA in Task 10.

- [ ] **Step 1: Implement**

Create `Sources/Core/SystemAudioCaptureService.swift`:

```swift
//
//  SystemAudioCaptureService.swift
//  Hush
//
//  Records system-output audio (the other meeting participants) to a
//  16 kHz mono CAF, and delivers one screen frame every ~2 s for caption
//  OCR. One SCStream, two outputs. Completely separate from
//  AudioCaptureService — the mic path is not touched.
//
//  16 kHz mono because raw 48 kHz stereo float is ~1.3 GB/hour and
//  WhisperKit resamples to 16 kHz mono anyway.
//

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class SystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {

    /// Called on the frame queue with each ~2 s frame and its offset from
    /// capture start.
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?

    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var startDate: Date?
    private(set) var fileURL: URL?

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false)!
    private let audioQueue = DispatchQueue(label: "com.hush.meeting.audio")
    private let frameQueue = DispatchQueue(label: "com.hush.meeting.frames")

    func start(excluding windows: [NSWindow]) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError(message: "enable screen recording for Hush in system settings")
        }
        guard let display = content.displays.first else {
            throw ScreenCaptureError(message: "enable screen recording for Hush in system settings")
        }

        let excludeIDs = Set(windows.map { CGWindowID($0.windowNumber) })
        let excluded = content.windows.filter { excludeIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // never record Hush's own TTS
        config.sampleRate = 48_000
        config.channelCount = 2
        // Frames feed OCR only; one every 2 s is plenty.
        config.minimumFrameInterval = CMTime(value: 2, timescale: 1)
        config.width = Int(display.width)           // full-res so captions OCR cleanly
        config.height = Int(display.height)
        config.queueDepth = 5

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-them.caf")
        audioFile = try AVAudioFile(forWriting: url,
                                    settings: outputFormat.settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        fileURL = url
        converter = nil

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
        startDate = Date()
    }

    /// Stops capture and closes the file. Returns the audio file URL, nil if
    /// capture never started.
    func stop() async -> URL? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        converter = nil
        // Closing the AVAudioFile (by releasing it) flushes the header.
        audioQueue.sync { self.audioFile = nil }
        startDate = nil
        return fileURL
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio: handleAudio(sampleBuffer)
        case .screen: handleFrame(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Capture died underneath us (display unplugged, permission pulled).
        // Keep what was written; MeetingSession finds out at stop().
        self.stream = nil
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let file = audioFile,
              let pcm = sampleBuffer.asPCMBuffer else { return }
        if converter == nil {
            converter = AVAudioConverter(from: pcm.format, to: outputFormat)
        }
        guard let converter else { return }

        let ratio = outputFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        if out.frameLength > 0 {
            try? file.write(from: out)
        }
    }

    private func handleFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let start = startDate,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, Date().timeIntervalSince(start))
    }
}

private extension CMSampleBuffer {
    /// SCStream delivers audio as CMSampleBuffer; AVAudioConverter wants
    /// AVAudioPCMBuffer. No-copy view over the sample buffer's audio list.
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { audioBufferList, _ in
            guard let absd = formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate,
                                             channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format,
                                    bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}
```

- [ ] **Step 2: Compile**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Core/SystemAudioCaptureService.swift
git commit -m "feat: system audio + frame capture for meetings"
```

---

### Task 8: MeetingSession orchestrator + mic-ownership guards

**Files:**
- Create: `Sources/Core/MeetingSession.swift`
- Modify: `Sources/Core/AppState.swift` (top of `startRecording()`, ~line 51), `Sources/Core/TalkSession.swift` (just before the existing guard at ~line 124)

**Interfaces:**
- Consumes: everything from Tasks 1–7; `AudioCaptureService` (own instance); `AppSettings.shared.primaryLanguage`; `AppState.audioService.isRecording`.
- Produces: `MeetingSession.shared` (`@MainActor ObservableObject`): `enum State { idle, recording(startedAt: Date), processing, failed(String) }`, `@Published state`, `var isRecording: Bool`, `func toggle(appState: AppState)`, `func retryRecap(meetingID: String)`. Task 9's UI binds to exactly these.

- [ ] **Step 1: Create MeetingSession**

Create `Sources/Core/MeetingSession.swift`:

```swift
//
//  MeetingSession.swift
//  Hush
//
//  Orchestrates one meeting recording: mic + system audio + caption OCR →
//  two transcripts → merge → one recap call → saved Meeting row.
//  TalkSession's equivalent for meetings.
//
//  Owns a PRIVATE AudioCaptureService instance. AppState's instance belongs
//  to dictation/circle-to-ask; sharing it would let TalkSession's cancel
//  path silently end a meeting's mic file. Overlap is prevented by mutual
//  guards, never by sharing state.
//

import AppKit
import Foundation

@MainActor
final class MeetingSession: ObservableObject {

    static let shared = MeetingSession()

    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Meetings shorter than this are discarded without an API call.
    static let minimumMeetingSeconds: TimeInterval = 30
    /// Meetings deserve the accurate model regardless of the dictation
    /// setting; the spec pins large-v3-turbo.
    static let whisperModel = "large-v3-turbo"

    private let micService = AudioCaptureService()
    private let systemService = SystemAudioCaptureService()
    private let nameReader = SpeakerNameReader()
    private let transcriber = LocalTranscriptionService()

    private init() {}

    func toggle(appState: AppState) {
        switch state {
        case .recording:
            stop()
        case .processing:
            break   // pill is disabled; ignore races
        case .idle, .failed:
            start(appState: appState)
        }
    }

    private func start(appState: AppState) {
        // Mic ownership: never start while dictation/circle-to-ask holds the
        // mic. The reverse guard lives in AppState/TalkSession.
        guard !appState.audioService.isRecording else {
            state = .failed("finish dictating first")
            return
        }
        nameReader.reset()
        systemService.onFrame = { [weak self] pixelBuffer, t in
            self?.nameReader.process(pixelBuffer: pixelBuffer, at: t)
        }
        Task {
            do {
                try await systemService.start(excluding: NSApp.windows)
                try micService.startRecording()
                state = .recording(startedAt: Date())
            } catch {
                _ = await systemService.stop()
                _ = micService.stopRecording()
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func stop() {
        guard case .recording(let startedAt) = state else { return }
        state = .processing
        let duration = Date().timeIntervalSince(startedAt)
        let mic = micService.stopRecording()
        let ticks = nameReader.snapshotTicks()
        let names = nameReader.snapshotNames()

        Task {
            let systemURL = await systemService.stop()
            defer {
                if let mic { try? FileManager.default.removeItem(at: mic.url) }
                if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
            }

            guard duration >= Self.minimumMeetingSeconds, let mic, let systemURL else {
                state = .idle
                return
            }

            do {
                let language = AppSettings.shared.primaryLanguage
                let micSegments = try await transcriber.transcribeSegments(
                    fileURL: mic.url, modelSize: Self.whisperModel, language: language)
                let systemSegments = try await transcriber.transcribeSegments(
                    fileURL: systemURL, modelSize: Self.whisperModel, language: language)

                let lines = TranscriptMerger.merge(micSegments: micSegments,
                                                   systemSegments: systemSegments,
                                                   speakerTicks: ticks)
                var participants = [TranscriptMerger.meSpeaker]
                participants.append(contentsOf: names)

                var meeting = Meeting(
                    id: UUID().uuidString,
                    startedAt: startedAt,
                    duration: duration,
                    title: DateFormatter.localizedString(from: startedAt, dateStyle: .medium, timeStyle: .short),
                    participants: Meeting.encode(participants),
                    transcript: Meeting.encode(lines),
                    recap: nil,
                    actionItems: nil,
                    recapFailed: true
                )
                do {
                    let result = try await MeetingRecapService.recap(lines: lines, participants: participants)
                    meeting.title = result.title
                    meeting.recap = result.recap
                    meeting.actionItems = Meeting.encode(result.actionItems)
                    meeting.recapFailed = false
                } catch {
                    // The transcript survives; recap can be retried from it.
                }
                MeetingStore.shared.save(meeting)
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-runs the recap from a saved transcript. One API call, no
    /// re-transcription.
    func retryRecap(meetingID: String) {
        guard case .idle = state,
              var meeting = MeetingStore.shared.meetings.first(where: { $0.id == meetingID })
        else { return }
        state = .processing
        Task {
            do {
                let result = try await MeetingRecapService.recap(
                    lines: meeting.lines, participants: meeting.participantList)
                meeting.title = result.title
                meeting.recap = result.recap
                meeting.actionItems = Meeting.encode(result.actionItems)
                meeting.recapFailed = false
                MeetingStore.shared.save(meeting)
            } catch {
                // Row keeps recapFailed = true; user can retry again.
            }
            state = .idle
        }
    }
}
```

- [ ] **Step 2: Guard dictation**

In `Sources/Core/AppState.swift`, at the very top of `func startRecording()` (~line 51), before anything else:

```swift
        if MeetingSession.shared.isRecording {
            hudState = .error("recording a meeting — stop it first")
            return
        }
```

- [ ] **Step 3: Guard circle-to-ask**

In `Sources/Core/TalkSession.swift`, immediately BEFORE the existing line ~124:

```swift
        guard !appState.audioService.isRecording else {
```

insert:

```swift
        // A meeting recording owns its own mic engine; talking over it would
        // interleave two sessions' audio UX. Refuse quietly.
        guard !MeetingSession.shared.isRecording else { return }
```

(If the surrounding method's control flow requires a different early-exit form than a bare `return` — e.g. it sets overlay state — match whatever the `audioService.isRecording` guard's else-branch does.)

- [ ] **Step 4: Compile and run full test suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build succeeds, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/MeetingSession.swift Sources/Core/AppState.swift Sources/Core/TalkSession.swift
git commit -m "feat: meeting session orchestrator + mic ownership guards"
```

---

### Task 9: UI — Record Call pill, Meetings page

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift` (four places: `NudgePage` enum ~line 14; `pageLayer` stack ~line 73; the placeholder button ~lines 318–334; LIBRARY section ~line 1128; plus new view code at the end of the struct)

**Interfaces:**
- Consumes: `MeetingSession.shared` (`state`, `toggle(appState:)`, `retryRecap(meetingID:)`), `MeetingStore.shared.meetings`, `Meeting` helpers (Task 4), `navRow`/`settingsSection`/`rowDivider`/`pageLayer` (existing private helpers in this file).
- Produces: user-visible feature. No new public API.

**Layout invariant:** the panel window stays fixed-size; `.meetings` uses the default `subpageSize` like every other LIBRARY page. Back-chevron behaviour is automatic (non-settings pages navigate back to `.settings`).

- [ ] **Step 1: Extend NudgePage**

At ~line 15, change:

```swift
    case home, agents, settings, history, insights, usage, scratchpad
```

to:

```swift
    case home, agents, settings, history, insights, usage, scratchpad, meetings
```

and add to the `title` switch:

```swift
        case .meetings: return "Meetings"
```

(`panelSize` needs no change — `default` already returns `subpageSize`.)

- [ ] **Step 2: Observe the new objects**

Next to the existing `@ObservedObject` properties (~line 51), add:

```swift
    @ObservedObject private var meeting = MeetingSession.shared
    @ObservedObject private var meetingStore = MeetingStore.shared
    @State private var selectedMeetingID: String?
```

- [ ] **Step 3: Mount the page**

In the `ZStack` of `pageLayer` calls (~line 73), after the `scratchpadView` line:

```swift
                    pageLayer(meetingsView, for: .meetings)
```

- [ ] **Step 4: Replace the Undock Cursor placeholder**

Replace the entire placeholder button (~lines 318–334, from `// Undock Cursor pill — yellow accent (placeholder)` through its `.buttonStyle(.plain)`) with:

```swift
                    // Record Call pill — meeting recording (Phase 6)
                    Button(action: { meeting.toggle(appState: appState) }) {
                        HStack(spacing: 5) {
                            switch meeting.state {
                            case .recording(let startedAt):
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                    Text(recordElapsed(from: startedAt, now: context.date))
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                }
                            case .processing:
                                ProgressView()
                                    .controlSize(.small)
                                Text("Processing…")
                                    .font(.system(size: 12, weight: .semibold))
                            default:
                                Image(systemName: "record.circle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Record Call")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .foregroundColor(recordPillForeground)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(recordPillFill)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(meeting.state == .processing)
```

- [ ] **Step 5: Add the pill helpers + meetings views**

At the end of the `NudgeMenuView` struct body (near the other private helpers), add:

```swift
    // MARK: - Record Call pill (Phase 6)

    private var recordPillFill: Color {
        switch meeting.state {
        case .recording: return Color(red: 0.85, green: 0.20, blue: 0.18)
        case .processing: return Color(red: 0.20, green: 0.20, blue: 0.22)
        default: return Color(red: 0.98, green: 0.80, blue: 0.10)
        }
    }

    private var recordPillForeground: Color {
        switch meeting.state {
        case .recording, .processing: return .white
        default: return Color(red: 0.10, green: 0.10, blue: 0.10)
        }
    }

    private func recordElapsed(from start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Meetings page (Phase 6)

    private var meetingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let selected = meetingStore.meetings.first(where: { $0.id == selectedMeetingID }) {
                    meetingDetail(selected)
                } else if meetingStore.meetings.isEmpty {
                    Text("No meetings yet — hit Record Call during your next call.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.50, green: 0.50, blue: 0.52))
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(meetingStore.meetings) { m in
                        Button(action: { selectedMeetingID = m.id }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(meetingSubtitle(m))
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(red: 0.50, green: 0.50, blue: 0.52))
                                }
                                Spacer()
                                if m.recapFailed {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onDisappear { selectedMeetingID = nil }
    }

    private func meetingSubtitle(_ m: Meeting) -> String {
        let date = DateFormatter.localizedString(from: m.startedAt, dateStyle: .medium, timeStyle: .short)
        let minutes = max(1, Int(m.duration) / 60)
        let others = m.participantList.filter { $0 != TranscriptMerger.meSpeaker }
        let people = others.isEmpty ? "" : " · " + others.joined(separator: ", ")
        return "\(date) · \(minutes) min\(people)"
    }

    private func meetingDetail(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: { selectedMeetingID = nil }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("All meetings").font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.gray)
            }
            .buttonStyle(.plain)

            Text(m.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            Text(meetingSubtitle(m))
                .font(.system(size: 10))
                .foregroundColor(Color(red: 0.50, green: 0.50, blue: 0.52))

            if let recap = m.recap {
                meetingSectionHeader("Recap", copyText: recap)
                Text(recap)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.85, green: 0.85, blue: 0.87))
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    Text("Recap failed.")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Button("Retry") { meeting.retryRecap(meetingID: m.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 0.98, green: 0.80, blue: 0.10))
                        .disabled(meeting.state == .processing)
                }
            }

            let items = m.actionItemList
            if !items.isEmpty {
                let itemsText = items.map { "\($0.owner): \($0.task)" }.joined(separator: "\n")
                meetingSectionHeader("Action items", copyText: itemsText)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.owner)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text(item.task)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 0.85, green: 0.85, blue: 0.87))
                    }
                }
            }

            let transcriptText = MeetingRecapService.formatTranscript(m.lines)
            meetingSectionHeader("Transcript", copyText: transcriptText)
            Text(transcriptText)
                .font(.system(size: 11).monospaced())
                .foregroundColor(Color(red: 0.70, green: 0.70, blue: 0.72))
                .textSelection(.enabled)

            Button(action: {
                meetingStore.delete(id: m.id)
                selectedMeetingID = nil
            }) {
                Text("Delete meeting")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    private func meetingSectionHeader(_ title: String, copyText: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(red: 0.50, green: 0.50, blue: 0.52))
            Spacer()
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
```

- [ ] **Step 6: Add the LIBRARY row**

At ~line 1130, after the History `navRow`:

```swift
                        rowDivider
                        navRow(icon: "person.2", title: "Meetings", page: .meetings)
```

- [ ] **Step 7: Compile and run tests**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build succeeds, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/UI/NudgeMenuView.swift
git commit -m "feat: Record Call pill + Meetings library page"
```

---

### Task 10: Build the app + owner QA handoff

**Files:**
- No code changes. Produces the dev build and the QA checklist.

- [ ] **Step 1: Full build**

Run: `./build.sh 2>&1 | tail -10`
Expected: signed `Hush.app` in the repo root. Do NOT set `HUSH_INSTALL=1`; never touch `/Applications`.

- [ ] **Step 2: Sanity-launch**

Run: `open ./Hush.app` and confirm the notch nudge appears and the menu opens with the yellow **Record Call** pill and the LIBRARY → Meetings row. Quit the app afterwards.

- [ ] **Step 3: Write the QA checklist for the owner**

Print this checklist in the final message (do not create a file for it):

1. Open `./Hush.app` (the repo build, not /Applications). First meeting downloads the `large-v3-turbo` model (~1.5 GB, one time) — expect a long first "Processing…".
2. Join a real Meet call with 2+ other people. Turn on Meet captions (`c` key).
3. Notch menu → Record Call. Pill goes red with a timer. Close the panel; recording must continue.
4. Mid-call: press Shift+A — expect the HUD error "recording a meeting — stop it first", and the meeting must survive.
5. Talk for at least a few minutes, have others talk, agree on 1–2 fake action items out loud by name.
6. Stop via the pill. Wait out "Processing…".
7. LIBRARY → Meetings → the new row: check names on transcript lines, recap quality, action-item owners.
8. Usage & cost page: one new Claude row (~$0.05).
9. `ls "$TMPDIR"` — no `*-them.caf` or meeting `.caf` files left behind.
10. Second short test: record for <30 s → nothing saved, no API call.

- [ ] **Step 4: Update HANDOVER**

Add a short Phase 6 status block to `docs/superpowers/HANDOVER.md` (built state: implemented, awaiting owner QA; pointer to the spec and this plan). Follow the file's existing format.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/HANDOVER.md
git commit -m "docs: phase 6 built, awaiting owner QA"
```

---

## Self-Review Notes

- **Spec coverage:** capture (Task 7), OCR names + fallback-to-context (Task 3 — when captions are off, `ticks` is empty, every system line becomes "Someone else", and the recap prompt still lists participants; degraded exactly as spec'd), transcription (Task 6), merge (Task 2), recap + usage logging (Task 5), storage v4 (Task 4), orchestration + guards + <30 s discard + file deletion + retry (Task 8), pill + Meetings page (Task 9), QA (Task 10).
- **Deliberate scope cuts, per spec:** no hotkey; no auto-detect; recap failure keeps transcript with Retry; participant-tile OCR fallback deferred (empty-ticks degradation covers captions-off).
- **Type consistency:** `TranscriptSegment/SpeakerTick/AttributedLine/ActionItem/MeetingRecapResult` defined once in Task 1; all later tasks use those exact names. `Meeting.encode` used by Tasks 4, 8. `MeetingSession.toggle(appState:)`/`retryRecap(meetingID:)` produced in Task 8, consumed in Task 9 with matching signatures.
