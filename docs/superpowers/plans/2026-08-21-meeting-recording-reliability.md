# Meeting Recording Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A meeting recording never silently loses audio: one dead leg no longer deletes the other leg's file, a dead system-audio stream is reported *during* the call instead of at the end, and the Mac can't sleep mid-recording.

**Architecture:** All reliability decisions live in two new pure types (`MeetingLegs`, `CaptureWatchdog`) that are unit-tested; `SystemAudioCaptureService` gains thread-safe health counters, `MeetingSession` gains a 2-second watchdog timer + a published `liveWarning` string + a sleep-blocker activity, and `NudgeMenuView` renders the warning. Design cribbed from Wispr Flow's per-stream watchdogs (`firstFrameWatchdog`, `silentStreamStreakMs`) but implemented from scratch, local-only.

**Tech Stack:** Swift / SwiftPM, XCTest, AppKit + ScreenCaptureKit (existing services), no new dependencies.

## Global Constraints

- Do NOT touch `AudioCaptureService` (mic leg) — its BT watchdog/rebuild logic is load-bearing (see memory: "BT SCO: wait, don't rebuild"). The mic service already self-heals; this plan only handles the system leg and the stop path.
- SCStream delivers audio buffers continuously even when the room is silent — so "zero buffers" means the STREAM is dead, not that nobody is talking. The watchdog counts buffers, never loudness.
- `SystemAudioCaptureService` is nonisolated; its callbacks run on background queues. All new health state must be lock-guarded and never touch AppKit.
- `MeetingSession` is `@MainActor`; UI-facing state (`liveWarning`) changes only there.
- User-visible strings are lowercase-ish, short, and actionable (match existing "enable screen recording for Hush in system settings" style).
- Tests: `swift test` must pass after every task.
- Version bump to `1.0.36` happens in the release task ONLY (Info.plist `CFBundleShortVersionString`).
- Never install to /Applications; Lord Berries tests the local `Hush.app` and updates the installed copy via the in-app update button.

## File Structure

- Create `Sources/Core/MeetingLegs.swift` — pure enum: which audio files survived stop, and the user-facing note when one is missing.
- Create `Sources/Core/CaptureWatchdog.swift` — pure verdict function over a `CaptureHealth` snapshot: waiting / alive / dead(reason).
- Create `Tests/HushTests/MeetingLegsTests.swift`, `Tests/HushTests/CaptureWatchdogTests.swift`.
- Modify `Sources/Core/SystemAudioCaptureService.swift` — lock-guarded health counters + `health()` snapshot + `didStopWithError` records death.
- Modify `Sources/Core/MeetingSession.swift` — salvage stop path, watchdog timer, `liveWarning`, sleep blocker.
- Modify `Sources/UI/NudgeMenuView.swift` — one warning `Text` under the Record Call pill row.

---

### Task 1: `MeetingLegs` — salvage decision (pure)

**Files:**
- Create: `Sources/Core/MeetingLegs.swift`
- Test: `Tests/HushTests/MeetingLegsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `MeetingLegs.from(mic: URL?, system: URL?) -> MeetingLegs`, cases `.both(mic:system:)`, `.micOnly(URL)`, `.systemOnly(URL)`, `.neither`; `var warningAfterSave: String?` (nil for `.both`). Task 4 consumes both.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/HushTests/MeetingLegsTests.swift
import XCTest
@testable import Hush

final class MeetingLegsTests: XCTestCase {

    private let micURL = URL(fileURLWithPath: "/tmp/mic.caf")
    private let sysURL = URL(fileURLWithPath: "/tmp/sys.caf")

    func testBothPresent() {
        XCTAssertEqual(MeetingLegs.from(mic: micURL, system: sysURL),
                       .both(mic: micURL, system: sysURL))
        XCTAssertNil(MeetingLegs.from(mic: micURL, system: sysURL).warningAfterSave)
    }

    func testMicOnlyStillSaves() {
        let legs = MeetingLegs.from(mic: micURL, system: nil)
        XCTAssertEqual(legs, .micOnly(micURL))
        XCTAssertEqual(legs.warningAfterSave, "saved — no system audio was captured")
    }

    func testSystemOnlyStillSaves() {
        let legs = MeetingLegs.from(mic: nil, system: sysURL)
        XCTAssertEqual(legs, .systemOnly(sysURL))
        XCTAssertEqual(legs.warningAfterSave, "saved — no mic audio was captured")
    }

    func testNothingCaptured() {
        XCTAssertEqual(MeetingLegs.from(mic: nil, system: nil), .neither)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingLegsTests 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'MeetingLegs' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Core/MeetingLegs.swift
//
//  MeetingLegs.swift
//  Hush
//
//  Which of the meeting's two audio files actually survived stop. One
//  missing leg degrades the meeting (with a visible note); it no longer
//  discards the other leg's perfectly good audio. Only .none fails.
//

import Foundation

enum MeetingLegs: Equatable {
    case both(mic: URL, system: URL)
    case micOnly(URL)
    case systemOnly(URL)
    case neither

    static func from(mic: URL?, system: URL?) -> MeetingLegs {
        switch (mic, system) {
        case let (mic?, system?): return .both(mic: mic, system: system)
        case let (mic?, nil):     return .micOnly(mic)
        case let (nil, system?):  return .systemOnly(system)
        case (nil, nil):          return .neither
        }
    }

    /// Shown transiently after a degraded save. Nil when nothing was lost.
    var warningAfterSave: String? {
        switch self {
        case .both, .neither: return nil
        case .micOnly:     return "saved — no system audio was captured"
        case .systemOnly:  return "saved — no mic audio was captured"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingLegsTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/MeetingLegs.swift Tests/HushTests/MeetingLegsTests.swift
git commit -m "feat: MeetingLegs salvage decision — one dead leg no longer discards the meeting"
```

---

### Task 2: `CaptureWatchdog` — dead-stream verdict (pure)

**Files:**
- Create: `Sources/Core/CaptureWatchdog.swift`
- Test: `Tests/HushTests/CaptureWatchdogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct CaptureHealth { var buffersDelivered: Int64; var lastBufferAt: Date?; var streamDied: Bool }` (Equatable); `enum CaptureVerdict: Equatable { case waitingForFirstBuffer, alive, dead(String) }`; `CaptureWatchdog.verdict(health:startedAt:now:firstBufferGrace:stallLimit:) -> CaptureVerdict` with defaults `firstBufferGrace: 5`, `stallLimit: 10`. Tasks 3 and 4 consume these.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/HushTests/CaptureWatchdogTests.swift
import XCTest
@testable import Hush

final class CaptureWatchdogTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNoBuffersInsideGraceIsWaiting() {
        let health = CaptureHealth(buffersDelivered: 0, lastBufferAt: nil, streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(3)),
                       .waitingForFirstBuffer)
    }

    func testNoBuffersPastGraceIsDead() {
        let health = CaptureHealth(buffersDelivered: 0, lastBufferAt: nil, streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(6)),
                       .dead("no system audio arriving — check screen recording permission"))
    }

    func testFlowingBuffersAreAlive() {
        let health = CaptureHealth(buffersDelivered: 500, lastBufferAt: t0.addingTimeInterval(59), streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(60)),
                       .alive)
    }

    func testStalledBuffersAreDead() {
        // Buffers flowed for a minute, then nothing for 11s.
        let health = CaptureHealth(buffersDelivered: 500, lastBufferAt: t0.addingTimeInterval(60), streamDied: false)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(71)),
                       .dead("system audio stopped mid-call"))
    }

    func testStreamDeathBeatsEverything() {
        // Even with recent buffers, an SCStream error is terminal.
        let health = CaptureHealth(buffersDelivered: 500, lastBufferAt: t0.addingTimeInterval(60), streamDied: true)
        XCTAssertEqual(CaptureWatchdog.verdict(health: health, startedAt: t0, now: t0.addingTimeInterval(61)),
                       .dead("system audio stopped mid-call"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureWatchdogTests 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'CaptureHealth' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Core/CaptureWatchdog.swift
//
//  CaptureWatchdog.swift
//  Hush
//
//  Pure liveness verdict for the system-audio leg. SCStream delivers audio
//  buffers continuously even in a silent room, so "no buffers" means the
//  STREAM is broken (permission pulled, display change, SCStream error) —
//  never that nobody happens to be talking. Cribbed from Wispr Flow's
//  per-stream firstFrameWatchdog/silentStreamStreak design.
//
//  Pure so it is testable with plain dates; the timer that feeds it lives
//  in MeetingSession.
//

import Foundation

struct CaptureHealth: Equatable {
    var buffersDelivered: Int64
    var lastBufferAt: Date?
    var streamDied: Bool
}

enum CaptureVerdict: Equatable {
    case waitingForFirstBuffer
    case alive
    case dead(String)
}

enum CaptureWatchdog {
    /// - firstBufferGrace: SCStream normally lands its first audio buffer
    ///   well under a second after startCapture; 5s of nothing is broken.
    /// - stallLimit: buffers arrive tens of times per second; 10s of
    ///   silence after audio HAS flowed means the stream died quietly.
    static func verdict(health: CaptureHealth,
                        startedAt: Date,
                        now: Date,
                        firstBufferGrace: TimeInterval = 5,
                        stallLimit: TimeInterval = 10) -> CaptureVerdict {
        if health.streamDied {
            return .dead("system audio stopped mid-call")
        }
        guard health.buffersDelivered > 0 else {
            return now.timeIntervalSince(startedAt) < firstBufferGrace
                ? .waitingForFirstBuffer
                : .dead("no system audio arriving — check screen recording permission")
        }
        if let last = health.lastBufferAt, now.timeIntervalSince(last) > stallLimit {
            return .dead("system audio stopped mid-call")
        }
        return .alive
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureWatchdogTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/CaptureWatchdog.swift Tests/HushTests/CaptureWatchdogTests.swift
git commit -m "feat: CaptureWatchdog — pure liveness verdict for the system-audio leg"
```

---

### Task 3: Health counters in `SystemAudioCaptureService`

**Files:**
- Modify: `Sources/Core/SystemAudioCaptureService.swift`

**Interfaces:**
- Consumes: `CaptureHealth` from Task 2.
- Produces: `func health() -> CaptureHealth` (thread-safe, callable from any thread). Task 4 consumes it.

No new unit test — the counters are exercised through the pure `CaptureWatchdog` tests plus the manual end-to-end check in Task 6; the service itself needs live ScreenCaptureKit to run.

- [ ] **Step 1: Add lock-guarded health state**

In `SystemAudioCaptureService`, below the existing `private let frameQueue = ...` line, add:

```swift
    /// Health counters, read by MeetingSession's watchdog timer from the
    /// main actor while the stream callbacks write from their own queues.
    private let healthLock = NSLock()
    private var buffersDelivered: Int64 = 0
    private var lastBufferAt: Date?
    private var streamDied = false

    /// Thread-safe snapshot for CaptureWatchdog.
    func health() -> CaptureHealth {
        healthLock.lock()
        defer { healthLock.unlock() }
        return CaptureHealth(buffersDelivered: buffersDelivered,
                             lastBufferAt: lastBufferAt,
                             streamDied: streamDied)
    }
```

- [ ] **Step 2: Reset counters on start, record buffers, record death**

In `start(excludeWindowIDs:)`, immediately after `converter = nil`, add:

```swift
        healthLock.lock()
        buffersDelivered = 0
        lastBufferAt = nil
        streamDied = false
        healthLock.unlock()
```

In `handleAudio(_:)`, at the very top (before the `guard let file = audioFile` line — a buffer arriving proves the stream is alive even if the file write path has a problem), add:

```swift
        healthLock.lock()
        buffersDelivered += 1
        lastBufferAt = Date()
        healthLock.unlock()
```

In `stream(_:didStopWithError:)`, before `self.stream = nil`, add:

```swift
        healthLock.lock()
        streamDied = true
        healthLock.unlock()
        TalkHotkeyMonitor.diag("MEETING system stream DIED — \(error.localizedDescription)")
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Run full test suite**

Run: `swift test 2>&1 | tail -3`
Expected: `0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/SystemAudioCaptureService.swift
git commit -m "feat: system-audio capture tracks buffer liveness and stream death"
```

---

### Task 4: `MeetingSession` — salvage stop, watchdog timer, sleep blocker

**Files:**
- Modify: `Sources/Core/MeetingSession.swift`

**Interfaces:**
- Consumes: `MeetingLegs` (Task 1), `CaptureWatchdog`/`CaptureVerdict` (Task 2), `systemService.health()` (Task 3).
- Produces: `@Published private(set) var liveWarning: String?` — Task 5 renders it.

- [ ] **Step 1: Add published warning, timer, and sleep-blocker state**

Below `@Published private(set) var state: State = .idle`, add:

```swift
    /// Non-fatal problem with the CURRENT recording ("system audio stopped
    /// mid-call") or a transient post-save note ("saved — no mic audio was
    /// captured"). Rendered under the Record Call pill; nil hides it.
    @Published private(set) var liveWarning: String?
```

Below `private let transcriber = LocalTranscriptionService()`, add:

```swift
    /// Fires every 2s while recording; feeds systemService.health() through
    /// CaptureWatchdog. Main-actor only.
    private var watchdogTimer: Timer?
    /// Keeps the Mac (and display — caption OCR needs it) awake while
    /// recording. Wispr Flow holds the same assertion for its sessions.
    private var sleepActivity: NSObjectProtocol?
```

- [ ] **Step 2: Start the blocker + watchdog when recording starts**

In `start(appState:)`, inside the `Task { ... }` success path, replace:

```swift
                try await systemService.start(excludeWindowIDs: hushWindowIDs)
                try micService.startRecording()
                TalkHotkeyMonitor.diag("MEETING recording — mic + system audio live")
                state = .recording(startedAt: Date())
```

with:

```swift
                try await systemService.start(excludeWindowIDs: hushWindowIDs)
                try micService.startRecording()
                TalkHotkeyMonitor.diag("MEETING recording — mic + system audio live")
                let startedAt = Date()
                state = .recording(startedAt: startedAt)
                liveWarning = nil
                beginSleepBlocker()
                startWatchdog(startedAt: startedAt)
```

- [ ] **Step 3: Add the helper methods**

Above `private func scheduleFailureClear()`, add:

```swift
    private func beginSleepBlocker() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Hush is recording a meeting")
    }

    private func endSleepBlocker() {
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func startWatchdog(startedAt: Date) {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.watchdogTick(startedAt: startedAt) }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// The mic leg self-heals inside AudioCaptureService and is deliberately
    /// not watched here; this only covers the system leg, which had NO
    /// mid-call failure signal before.
    private func watchdogTick(startedAt: Date) {
        guard case .recording = state else { return }
        switch CaptureWatchdog.verdict(health: systemService.health(),
                                       startedAt: startedAt, now: Date()) {
        case .alive, .waitingForFirstBuffer:
            // Only clear a warning the watchdog itself set — a stream that
            // recovers (e.g. permission re-granted) unsticks the banner.
            if liveWarning != nil { liveWarning = nil }
        case .dead(let reason):
            if liveWarning != reason {
                liveWarning = reason
                TalkHotkeyMonitor.diag("MEETING watchdog — \(reason)")
            }
        }
    }

    /// Post-save note ("saved — no mic audio was captured"): visible long
    /// enough to read, then gone. Guarded so it never wipes a newer message.
    private func flashWarning(_ message: String) {
        liveWarning = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.liveWarning == message else { return }
            self.liveWarning = nil
        }
    }
```

- [ ] **Step 4: Stop the blocker + watchdog on every exit path**

In `start(appState:)`'s `catch` block, after `state = .failed(error.localizedDescription)`, add:

```swift
                endSleepBlocker()
                stopWatchdog()
```

At the top of `stop()`, after `state = .processing`, add:

```swift
        stopWatchdog()
        endSleepBlocker()
        liveWarning = nil
```

- [ ] **Step 5: Replace the discard-everything guard with salvage**

In `stop()`'s `Task { ... }`, replace:

```swift
            guard let mic, let systemURL else {
                TalkHotkeyMonitor.diag("MEETING discarded — missing audio (mic: \(mic != nil), system: \(systemURL != nil))")
                state = .failed(mic == nil ? "no mic audio captured" : "no system audio captured")
                scheduleFailureClear()
                return
            }
```

with:

```swift
            let legs = MeetingLegs.from(mic: mic?.url, system: systemURL)
            guard legs != .neither else {
                TalkHotkeyMonitor.diag("MEETING discarded — no audio captured on either leg")
                state = .failed("no audio captured")
                scheduleFailureClear()
                return
            }
            if let warning = legs.warningAfterSave {
                TalkHotkeyMonitor.diag("MEETING degraded — \(warning)")
            }
```

- [ ] **Step 6: Transcribe only the legs that exist**

Still in `stop()`'s `Task`, replace:

```swift
                let micSegments = try await transcriber.transcribeSegments(
                    fileURL: mic.url, modelSize: Self.whisperModel, language: language)
                let systemSegments = try await transcriber.transcribeSegments(
                    fileURL: systemURL, modelSize: Self.whisperModel, language: language)
```

with:

```swift
                var micSegments: [TranscriptSegment] = []
                if let mic {
                    micSegments = try await transcriber.transcribeSegments(
                        fileURL: mic.url, modelSize: Self.whisperModel, language: language)
                }
                var systemSegments: [TranscriptSegment] = []
                if let systemURL {
                    systemSegments = try await transcriber.transcribeSegments(
                        fileURL: systemURL, modelSize: Self.whisperModel, language: language)
                }
```

(`TranscriptMerger.merge` already handles an empty array for either side — covered by `TranscriptMergerTests`.)

- [ ] **Step 7: Flash the degraded-save note after saving**

Still in `stop()`'s `Task`, replace:

```swift
                MeetingStore.shared.save(meeting)
                state = .idle
```

with:

```swift
                MeetingStore.shared.save(meeting)
                state = .idle
                if let warning = legs.warningAfterSave { flashWarning(warning) }
```

- [ ] **Step 8: Build and run the full suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: `Build complete!` and `0 failures`

- [ ] **Step 9: Commit**

```bash
git add Sources/Core/MeetingSession.swift
git commit -m "feat: meeting session salvages single-leg audio, watches the system stream live, blocks sleep while recording"
```

---

### Task 5: Warning line in `NudgeMenuView`

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift` (Integrations section, the `HStack(spacing: 8)` row that contains the Record Call pill, ~line 305-380)

**Interfaces:**
- Consumes: `meeting.liveWarning` from Task 4.
- Produces: nothing downstream.

- [ ] **Step 1: Render the warning under the pill row**

Find the closing brace of the `HStack(spacing: 8) { ... }` that contains the "+" bar, the Record Call pill, and the circular "i" button. Immediately AFTER that `HStack`'s closing brace (still inside the surrounding `VStack` of the Integrations section), add:

```swift
                if let warning = meeting.liveWarning {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(warning)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                    }
                    .foregroundColor(Color(red: 0.95, green: 0.65, blue: 0.25))
                    .padding(.leading, 2)
                    .transition(.opacity)
                }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/NudgeMenuView.swift
git commit -m "feat: show live recording warnings under the Record Call pill"
```

---

### Task 6: End-to-end verification build (no release yet)

**Files:** none created; local `Hush.app` rebuilt.

- [ ] **Step 1: Full test suite one last time**

Run: `swift test 2>&1 | tail -3`
Expected: `0 failures`

- [ ] **Step 2: Rebuild the local dev app**

Run: `./build.sh 2>&1 | tail -3`
Expected: bundle created without errors. Do NOT copy it anywhere — Lord Berries launches `Hush.app` from the repo himself.

- [ ] **Step 3: Hand off for manual testing — STOP HERE**

Manual checks for Lord Berries (each maps to one fix):
1. Record a short call normally → meeting saves as before, no warning shown.
2. Start a recording, then revoke Screen Recording permission mid-call (System Settings → Privacy & Security) → within ~10s the orange "system audio stopped mid-call" line appears under the pill; stopping still SAVES a meeting with the note "saved — no system audio was captured".
3. Start a recording and leave the Mac untouched past its display-sleep timeout → display stays awake.

Release (Task 7) only proceeds on his explicit OK.

---

### Task 7: Release 1.0.36 (after manual OK only)

**Files:**
- Modify: `Info.plist` (CFBundleShortVersionString 1.0.35 → 1.0.36)

- [ ] **Step 1: Bump version**

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.36" Info.plist
```

- [ ] **Step 2: Run the release script**

Run: `./release.sh`
Expected: signed `Hush-1.0.36.dmg` + Sparkle deltas + appcast entry produced per the existing flow.

- [ ] **Step 3: Commit and push per the Hush release flow**

```bash
git add -A
git commit -m "release 1.0.36: stop losing meeting audio when one leg dies; live dead-stream warning; sleep blocker"
git push origin master
git push origin master:main
```

---

## Self-Review

1. **Spec coverage:** keep-audio-when-one-leg-fails → Tasks 1, 4 (steps 5-7). First-frame watchdog + live dead-stream detection → Tasks 2, 3, 4 (steps 1-4), 5. Sleep blocker → Task 4 (steps 1-4). Release → Tasks 6-7. No gaps.
2. **Placeholder scan:** every code step contains the full code; no TBDs.
3. **Type consistency:** `MeetingLegs.from(mic:system:)` / `.warningAfterSave` match between Tasks 1 and 4; `CaptureHealth` / `CaptureVerdict` / `CaptureWatchdog.verdict(health:startedAt:now:firstBufferGrace:stallLimit:)` match between Tasks 2, 3, 4; `health()` produced in Task 3 is what Task 4 calls; `liveWarning` produced in Task 4 is what Task 5 renders. `mic` in `stop()` is the `(url:duration:)` tuple, so Task 4 uses `mic?.url` — consistent with `AudioCaptureService.stopRecording()`.
