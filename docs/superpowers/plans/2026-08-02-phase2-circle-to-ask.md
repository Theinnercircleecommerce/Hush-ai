# Phase 2 — Circle-to-Ask (Talk) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold `⌃⌥`, optionally circle part of the screen, speak a question — Hush answers out loud and shows the answer near the cursor. Exactly HeyClicky's talk feature.

**Architecture:** A `TalkSession` orchestrator drives: hotkey monitor → circle overlay + mic → local WhisperKit transcript → ScreenCaptureKit screenshots (+ cropped region) → Claude Sonnet 4.6 streaming → OpenAI TTS playback + cursor bubble. Nudge states (Listening/Thinking/Speaking) render throughout.

**Tech Stack:** Swift 5.9 SwiftPM, AppKit + SwiftUI + ScreenCaptureKit + AVFoundation + Security (Keychain). No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-08-02-phase2-circle-to-ask-design.md`
**Research:** `docs/superpowers/research/2026-07-31-clicky-research-dossier.md` (has re-clone commands for `/tmp/clicky-refs`; farza's `OverlayWindow.swift`, `ClaudeAPI.swift`, `CompanionScreenCaptureUtility.swift` are the reference implementations for tasks 3–5).

## Global Constraints

- Build `swift build`; bundle+run `pkill -x Hush; ./build.sh && open Hush.app`. NEVER `xcodebuild`. No test target — verification is manual with the user.
- No new dependencies in `Package.swift`.
- **Single model: `claude-sonnet-4-6`.** No model picker anywhere.
- **STT stays local** (existing `LocalTranscriptionService` + WhisperKit). Never send audio off the Mac.
- API keys ONLY in Keychain — never UserDefaults, never logged, never in git.
- USER RULE: ask before deleting files.
- Info.plist needs `NSScreenCaptureUsageDescription` if absent — check before Task 4.
- The user is visual/audio QA; stop and ask when a step says to.

## ⚠️ DO-NOT-REGRESS (Phases 1 + 1.5)

- Never modify sizing/safe-area/state logic in `NudgeView.swift`, `NudgeShape.swift`, `NotchNudgeController.swift`, or the panel mechanics in `NudgeMenuController.swift` beyond what a task explicitly says.
- Safe-area stays disabled twice on notch panels; menu panel stays fixed-size, created once in `attach()`; hover poll + `zoneContains` top-edge-inclusive logic untouched.
- After any UI-adjacent change: `tail -2 "$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log"` → panel top == screenMaxY, hostingSafeArea zeros.
- Dictation (`fn`-hotkey → WhisperKit → paste) must keep working unchanged at every step.

---

### Task 1: Keychain store + API key settings rows

**Files:** Create `Sources/Core/KeychainStore.swift`; modify `Sources/UI/NudgeMenuView.swift`.

**Interfaces produced:**
- `enum KeychainStore { static func set(_ value: String, for key: KeychainKey); static func get(_ key: KeychainKey) -> String?; static func delete(_ key: KeychainKey) }`
- `enum KeychainKey: String { case anthropic = "anthropic-api-key"; case openai = "openai-api-key" }`

- [ ] **Step 1: Create `KeychainStore.swift`**

```swift
import Foundation
import Security

enum KeychainKey: String {
    case anthropic = "anthropic-api-key"
    case openai = "openai-api-key"
}

/// Generic-password Keychain wrapper for Hush's API keys. Values never
/// touch UserDefaults, logs, or disk.
enum KeychainStore {
    private static let service = "com.hush.app.keys"

    static func set(_ value: String, for key: KeychainKey) {
        delete(key)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty else { return nil }
        return string
    }

    static func delete(_ key: KeychainKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 2: Add an "AI" section to the Settings page**

In `Sources/UI/NudgeMenuView.swift`, add a new settings section (place it directly above the SYSTEM section, matching the existing section/row helper style exactly — read the file first and reuse its helpers, do not invent new styling):

- Section caption: `AI`
- Row "Anthropic key" — `SecureField` bound to `@State private var anthropicKey`, placeholder `sk-ant-…`; on commit (`.onSubmit`) call `KeychainStore.set(anthropicKey, for: .anthropic)`. Show a green checkmark when `KeychainStore.get(.anthropic) != nil`, gray dot otherwise.
- Row "OpenAI key (voice)" — same pattern with `.openai`, placeholder `sk-…`.
- Row "Voice" — `Picker` bound to `settings.ttsVoice` with options: alloy, echo, fable, onyx, nova, shimmer (tags = lowercase strings).
- Row "Talk shortcut" — DISPLAY ONLY: fixed `⌃` `⌥` keycap chips (reuse the Home shortcuts keycap style) with caption "hold to talk". NOT a recorder — the monitor hard-watches ⌃⌥ in v1, so showing a recorder would lie about configurability.
- Load initial `@State` values in `.onAppear` from `KeychainStore.get(...)`, showing a masked placeholder (e.g. `"sk-ant-••••" + String(key.suffix(4))`) rather than the real key.

Add to `Sources/Models/Settings.swift`, following the existing `@Published`/`didSet`/init pattern exactly:

```swift
    @Published var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: "ttsVoice") }
    }
```
init line: `self.ttsVoice = defaults.string(forKey: "ttsVoice") ?? "alloy"`

- [ ] **Step 3:** `swift build 2>&1 | tail -3` → `Build complete!`; relaunch and have the user paste both keys into the panel and confirm the checkmarks turn green (keys persist across an app restart).

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/KeychainStore.swift Sources/UI/NudgeMenuView.swift Sources/Models/Settings.swift
git commit -m "feat: keychain-backed API key settings and voice picker"
```

---

### Task 2: Talk hotkey monitor (hold to talk)

**Files:** Create `Sources/Core/TalkHotkeyMonitor.swift`; modify `Sources/Core/Hotkeys.swift`.

**Interfaces produced:** `final class TalkHotkeyMonitor { static let shared; var onPress: (() -> Void)?; var onRelease: (() -> Void)?; func start() }`

- [ ] **Step 1: No KeyboardShortcuts registration.** The talk trigger is a
  modifier-only hold (`⌃⌥`), which the KeyboardShortcuts package cannot
  express — do NOT add a `.talk` name or recorder (a recorder that the
  monitor ignores would be a lie in the UI). The combo is a constant in
  `TalkHotkeyMonitor`; making it configurable is a future task.

- [ ] **Step 2: Create the monitor** — a listen-only CGEvent tap on `.flagsChanged`, firing `onPress` when BOTH control and option are down and `onRelease` when either lifts. (Pattern reference: `/tmp/clicky-refs/farzaa-clicky/leanring-buddy/GlobalPushToTalkShortcutMonitor.swift`.)

```swift
import Cocoa

/// Hold-to-talk monitor for modifier-only combos (⌃⌥), which
/// KeyboardShortcuts can't express. Listen-only tap: never swallows events.
final class TalkHotkeyMonitor {
    static let shared = TalkHotkeyMonitor()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var isDown = false

    private init() {}

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<TalkHotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(flags: event.flags)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Hush: talk hotkey tap could not be created (accessibility permission?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(flags: CGEventFlags) {
        let held = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        if held, !isDown {
            isDown = true
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if !held, isDown {
            isDown = false
            DispatchQueue.main.async { [weak self] in self?.onRelease?() }
        }
    }
}
```

- [ ] **Step 3: Temporary wiring proof** — in `Sources/AppDelegate.swift`, after the existing nudge setup, add:

```swift
        TalkHotkeyMonitor.shared.onPress = { NSLog("Hush: TALK press") }
        TalkHotkeyMonitor.shared.onRelease = { NSLog("Hush: TALK release") }
        TalkHotkeyMonitor.shared.start()
```

Build, relaunch, hold `⌃⌥`, and confirm the pair of log lines appears (`log stream --predicate 'process == "Hush"'` in a terminal, or temporarily write to the same temp-dir log file used by NUDGE-GEO). Then ask the user to confirm holding `⌃⌥` doesn't break normal typing anywhere.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/TalkHotkeyMonitor.swift Sources/Core/Hotkeys.swift Sources/AppDelegate.swift
git commit -m "feat: hold-to-talk hotkey monitor for control+option"
```

---

### Task 3: Circle overlay (draw on screen while holding)

**Files:** Create `Sources/UI/CircleOverlayController.swift`, `Sources/UI/CircleOverlayView.swift`.

**Interfaces produced:**
- `final class CircleOverlayController { static let shared; func begin(); func end() -> CGRect?; var isActive: Bool }`
  — `end()` returns the drawn stroke's bounding box in **global AppKit coordinates**, or `nil` if the user drew nothing (fewer than 5 points).

- [ ] **Step 1: Overlay view** — SwiftUI view holding `@Published`-driven points; draws a smoothed path.

```swift
import SwiftUI

final class StrokeModel: ObservableObject {
    @Published var points: [CGPoint] = []   // view-local coordinates
    func reset() { points.removeAll() }
}

struct CircleOverlayView: View {
    @ObservedObject var model: StrokeModel

    private static let ink = Color(red: 0.29, green: 0.87, blue: 0.83)

    var body: some View {
        Canvas { context, _ in
            guard model.points.count > 1 else { return }
            var path = Path()
            path.move(to: model.points[0])
            for point in model.points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(Self.ink),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
```

- [ ] **Step 2: Controller** — one borderless transparent panel per screen at `.screenSaver` level. **While active (`begin()`…`end()`), `ignoresMouseEvents = false`** so the user's drag DRAWS instead of also selecting/dragging content in the app underneath; after `end()` set it back to `true` (click-through when dormant). The panels never become key or main (`canBecomeKey = false`) so focus stays with the user's app. A 60fps timer samples `NSEvent.mouseLocation` while active — only append points while the primary mouse button is down (`NSEvent.pressedMouseButtons & 1 != 0`), so hovering without clicking draws nothing — appending to the stroke of whichever screen contains the cursor.

Key requirements the implementer must satisfy:
- Panels created ONCE at `begin()` if absent, reused after (same pre-warm principle as the menu panel); hidden on `end()`, never destroyed.
- `hosting.safeAreaRegions = []` on every hosting view (DO-NOT-REGRESS rule 1).
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `canBecomeKey = false`.
- Convert global mouse point → view-local for the owning screen with
  `CGPoint(x: global.x - screen.frame.minX, y: screen.frame.maxY - global.y)`
  (AppKit is bottom-left origin; SwiftUI Canvas is top-left).
- `end()` computes the bounding box of the accumulated GLOBAL points
  (keep a parallel global-point array), expands it by 12pt padding, clamps
  to the owning screen's frame, and returns it. Fewer than 5 points → `nil`.
- After `end()`, animate the stroke out (0.25s fade) then clear the model.

- [ ] **Step 3: Temporary proof** — wire `TalkHotkeyMonitor.onPress` → `CircleOverlayController.shared.begin()` and `onRelease` → log the returned rect. Build, relaunch, hold `⌃⌥` and draw: the teal stroke must appear on the screen you're drawing on, disappear on release, and log a sensible rect. Ask the user to confirm it draws smoothly and doesn't block clicks.

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/CircleOverlayController.swift Sources/UI/CircleOverlayView.swift Sources/AppDelegate.swift
git commit -m "feat: live circle overlay while holding the talk hotkey"
```

---

### Task 4: Screen capture + region crop

**Files:** Create `Sources/Core/ScreenCaptureService.swift`; check `Info.plist`.

**Interfaces produced:**
```swift
struct CapturedScreen {
    let jpeg: Data
    let label: String           // "screen 1 of 2 (cursor here)"
    let isCursorScreen: Bool
    let displayFrame: CGRect    // AppKit global, bottom-left origin
    let pixelSize: CGSize       // screenshot pixels
}
enum ScreenCaptureService {
    static func captureAll(excluding windows: [NSWindow]) async throws -> [CapturedScreen]
    static func crop(_ screen: CapturedScreen, toGlobalRect rect: CGRect) -> Data?
}
```

- [ ] **Step 1:** Ensure `Info.plist` has `NSScreenCaptureUsageDescription` = "Hush captures your screen only when you hold the talk shortcut, so it can answer questions about what you see." (Add if missing; it is required or the app is killed on first capture.)

- [ ] **Step 2: Implement the service** using ScreenCaptureKit. Requirements (reference: `/tmp/clicky-refs/farzaa-clicky/leanring-buddy/CompanionScreenCaptureUtility.swift`):
- `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`, then one `SCContentFilter(display:excludingWindows:)` per display, excluding Hush's own windows (map the passed `NSWindow`s to `SCWindow` by `windowID`).
- Capture with `SCScreenshotManager.captureImage(contentFilter:configuration:)`.
- Downscale so the long edge ≤ 1280px, encode JPEG quality 0.8.
- Sort so the cursor's screen is first; label strings as shown above.
- `crop(_:toGlobalRect:)`: convert the global AppKit rect into screenshot pixel space — x scale = `pixelSize.width / displayFrame.width`, y flipped (`(displayFrame.maxY - rect.maxY) * yScale`) — clamp to bounds, crop, re-encode JPEG 0.8. Return `nil` if the rect doesn't intersect that screen.

- [ ] **Step 3: Temporary proof** — on hotkey release, capture and write the images to the temp dir; open them and confirm they show the right screens and that the crop matches what was circled. Remove the file-writing after verification.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/ScreenCaptureService.swift Info.plist
git commit -m "feat: multi-display screen capture with circled-region crop"
```

---

### Task 5: Claude vision client (streaming)

**Files:** Create `Sources/Core/ClaudeVisionClient.swift`.

**Interfaces produced:**
```swift
final class ClaudeVisionClient {
    static let shared: ClaudeVisionClient
    /// Streams answer text chunks; throws ClaudeError on failure.
    func ask(transcript: String,
             screens: [CapturedScreen],
             croppedRegion: Data?,
             onChunk: @escaping (String) -> Void) async throws -> String
    func resetConversation()
}
enum ClaudeError: LocalizedError { case missingKey, http(Int, String), network(Error), empty }
```

- [ ] **Step 1: Implement.** Requirements:
- Endpoint `https://api.anthropic.com/v1/messages`, headers `x-api-key` (from `KeychainStore.get(.anthropic)` — throw `.missingKey` if nil), `anthropic-version: 2023-06-01`, `content-type: application/json`.
- Body: `model: "claude-sonnet-4-6"`, `max_tokens: 1024`, `stream: true`, `system: <prompt below>`, `messages: <history + this turn>`.
- User content blocks, in order: the cropped region image FIRST (when present, with a text block `"the user circled this region"`), then each full screen image, then a text block with the transcript. Image blocks:
  `{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"<base64>"}}`.
- Streaming: `URLSession.bytes(for:)`, parse `data: ` SSE lines, decode `content_block_delta` → `delta.text`, call `onChunk` on the main queue, accumulate and return the full text.
- Keep the last 10 exchanges (user transcript + assistant text only — never re-send images) in an in-memory array; `resetConversation()` clears it. Auto-clear if the last exchange is older than 10 minutes.
- 20s timeout; map non-200 to `.http(status, body)`; empty result to `.empty`.

- [ ] **Step 2: System prompt** — use exactly this (adapted from farza's, spoken-style):

```swift
private let systemPrompt = """
you're hush, a friendly assistant that lives in the user's menu bar. the \
user just spoke to you and you can see their screen(s). your reply will be \
spoken aloud, so write the way you'd actually talk.

- default to one or two sentences. be direct and dense.
- all lowercase, casual, warm. no emojis, no markdown, no lists.
- write for the ear, not the eye. short sentences.
- reference specific things you can see on their screen.
- when the user circled a region, focus your answer on that region.
- don't read code or errors out verbatim — describe what they mean.
- if you can't see what they're asking about, say so briefly.
"""
```

- [ ] **Step 3: Temporary proof** — on release, run the full chain and log the streamed answer. Ask the user to hold, circle something, ask a question, and confirm the logged answer is accurate and conversational. Also test: no key → clean `.missingKey`; airplane mode → clean network error.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/ClaudeVisionClient.swift
git commit -m "feat: streaming Claude vision client for circle-to-ask"
```

---

### Task 6: Speech output (OpenAI TTS)

**Files:** Create `Sources/Core/SpeechOutputService.swift`.

**Interfaces produced:**
```swift
final class SpeechOutputService: NSObject, ObservableObject {
    static let shared: SpeechOutputService
    @Published private(set) var isSpeaking: Bool
    func speak(_ text: String) async     // no-throw: logs and no-ops on failure
    func stop()
}
```

- [ ] **Step 1: Implement.**
- POST `https://api.openai.com/v1/audio/speech`, `Authorization: Bearer <KeychainStore.get(.openai)>`, JSON `{"model":"gpt-4o-mini-tts","voice":<settings.ttsVoice>,"input":<text>,"response_format":"mp3"}`.
- Missing key or non-200 → log, set `isSpeaking = false`, return (the bubble still shows the answer; never crash).
- Play with `AVAudioPlayer` held as a property (so it isn't deallocated mid-playback); `isSpeaking = true` on start, `false` in `audioPlayerDidFinishPlaying`.
- `stop()` halts playback immediately (used when a new talk session starts).
- All `@Published` mutations on the main thread.

- [ ] **Step 2: Proof** — temporary call `SpeechOutputService.shared.speak("hey, this is hush")` at launch; confirm audio plays and the voice matches the Settings picker. Remove the temporary call.

- [ ] **Step 3: Commit**

```bash
git add Sources/Core/SpeechOutputService.swift
git commit -m "feat: OpenAI TTS speech output with voice setting"
```

---

### Task 7: TalkSession orchestrator + Speaking nudge state

**Files:** Create `Sources/Core/TalkSession.swift`; modify `Sources/Models/HUDState.swift`, `Sources/UI/NudgeView.swift`, `Sources/Core/AppState.swift`, `Sources/AppDelegate.swift`.

- [ ] **Step 1: Add the state** — in `Sources/Models/HUDState.swift` add `case speaking` to `HUDState`.

- [ ] **Step 2: Render it** — in `NudgeView.swift`, extend the existing `label`/`dots` switches ONLY (touch nothing else): `.speaking` → label `"Speaking"`, dots = `NudgeBarsView` in a warm amber (`Color(red: 1.0, green: 0.72, blue: 0.30)`) driven by a gentle looping animation (reuse `NudgePulseDotsView` if simpler). Sizing/shape/safe-area code stays untouched.

- [ ] **Step 3: Implement `TalkSession`** — a `@MainActor final class` with `static let shared`, holding a reference to `AppState`. Flow:

```
onPress:
  guard keys present (else appState.hudState = .error("add your api key in settings"); return)
  SpeechOutputService.shared.stop()
  CircleOverlayController.shared.begin()
  audioService.startRecording()
  appState.hudState = .recording        // "Listening"

onRelease:
  let region = CircleOverlayController.shared.end()
  let audio = audioService.stopRecording()
  appState.hudState = .transcribing     // "Thinking"
  Task {
    let transcript = try await transcription.transcribe(fileURL: audio.url,
                       modelSize: settings.whisperKitModelSize, language: settings.primaryLanguage)
    guard !transcript.trimmed.isEmpty else { appState.hudState = .idle; return }   // no API call
    let screens = try await ScreenCaptureService.captureAll(excluding: hushWindows)
    let crop = region.flatMap { r in screens.first { $0.displayFrame.intersects(r) }
                                     .flatMap { ScreenCaptureService.crop($0, toGlobalRect: r) } }
    var answer = ""
    answer = try await ClaudeVisionClient.shared.ask(transcript: transcript, screens: screens,
                                                     croppedRegion: crop) { chunk in
        AnswerBubbleController.shared.append(chunk)      // Task 8; no-op stub until then
    }
    appState.hudState = .speaking
    await SpeechOutputService.shared.speak(answer)
    appState.hudState = .idle
  }
```

Error handling: wrap the `Task` body in do/catch; on any error set `appState.hudState = .error(<short human message>)` and return to `.idle` after 3 seconds (mirror the existing error-recovery pattern already in `AppState`). `hushWindows` = the nudge panel, menu panel, and overlay panels — expose a getter on each controller returning its `NSWindow`s.

Re-entrancy: ignore `onPress` if a session is already running (`isBusy` flag).

- [ ] **Step 4: Wire in `AppDelegate`** — replace the temporary logging handlers from Tasks 2–6 with:

```swift
        TalkSession.shared.attach(appState: self.appState)
        TalkHotkeyMonitor.shared.onPress = { TalkSession.shared.begin() }
        TalkHotkeyMonitor.shared.onRelease = { TalkSession.shared.end() }
        TalkHotkeyMonitor.shared.start()
```

- [ ] **Step 5: Build, relaunch, FULL manual test with the user** — hold `⌃⌥`, circle a UI element, ask "what is this?", release. Expect: teal stroke → "Listening" → "Thinking" → spoken answer with "Speaking" bars → idle. Verify dictation still works untouched. Verify the geometry log is clean.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/
git commit -m "feat: circle-to-ask end to end — hold, circle, speak, hear the answer"
```

---

### Task 8: Answer bubble near the cursor

**Files:** Create `Sources/UI/AnswerBubbleController.swift`; modify `Sources/Core/TalkSession.swift` (already calls it).

**Interfaces produced:** `final class AnswerBubbleController { static let shared; func append(_ chunk: String); func clear() }`

- [ ] **Step 1: Implement** — a borderless non-activating click-through `NSPanel` at `.screenSaver` level, created once and reused, hosting a SwiftUI text view: max width 340pt, dark rounded background (match the notch panel's fill), white 13pt text, 12pt padding, subtle shadow. Appears at the cursor position + (20, -30), clamped to stay fully on the cursor's screen. `append` shows the panel on the first chunk and grows the text live; `clear` fades out (0.3s). Auto-clear 6 seconds after the LAST chunk (reset the timer on every append).

- [ ] **Step 2:** In `TalkSession`, call `AnswerBubbleController.shared.clear()` at the start of `begin()`.

- [ ] **Step 3:** Build, relaunch, test with the user — the answer should stream into a bubble next to the pointer while it's being spoken, then fade.

- [ ] **Step 4: Commit**

```bash
git add Sources/UI/AnswerBubbleController.swift Sources/Core/TalkSession.swift
git commit -m "feat: cursor-adjacent streaming answer bubble"
```

---

### Task 9: Polish + QA

- [ ] **Step 1: Enable the Home shortcut row** — in `NudgeMenuView.swift`, the shortcuts array entry for "Talk" flips from disabled/"coming soon" to enabled, showing the real `⌃⌥` keycaps.
- [ ] **Step 2: Full sweep with the user**
  1. Talk with a circle; talk without a circle (whole screen).
  2. Follow-up question referencing the previous answer (conversation memory).
  3. Both displays; a fullscreen app.
  4. Wrong/empty API key → clean error, no crash.
  5. Airplane mode → clean error.
  6. Hold and say nothing → silent return to idle, no charge.
  7. Dictation unaffected; nudge geometry log clean; hover panel unaffected.
  8. Check the Anthropic console: cost per question ≈ 1¢.
- [ ] **Step 3:** Fix reported issues, rebuild, re-verify.
- [ ] **Step 4: Update docs** — add a Phase 2 section to `docs/superpowers/HANDOVER.md` (built state + new invariants: keys in Keychain only, STT stays local, single model constant, overlay panels pre-warmed) and tick Phase 2 in the roadmap table.
- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "polish: phase 2 QA fixes and handover update"
```
