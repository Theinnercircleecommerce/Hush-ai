# Phase 3 — Text Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-tap `⌃` opens a Chat page in the notch panel with the input focused; type a question, get a streamed answer with screen context, optionally spoken. Shares conversation memory with talk mode. Barge-in polish folded in.

**Architecture:** Extend `TalkHotkeyMonitor` with double-tap detection (no new event machinery). Add `NudgePage.chat` to the existing mounted-pages panel. A new `ChatSession` orchestrator reuses Phase 2's `ScreenCaptureService`, `ClaudeVisionClient` (same history instance → shared memory), and `SpeechOutputService`.

**Tech Stack:** Swift 5.9 SwiftPM, SwiftUI + AppKit. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-02-phase3-text-chat-design.md`
**Context:** `docs/superpowers/HANDOVER.md` — read the Phase 2 section and the invariants list BEFORE starting.

## Global Constraints

- Build `swift build`; bundle+run `pkill -x Hush; ./build.sh && open Hush.app`. NEVER `xcodebuild`. No test target — manual verification with the user.
- No new dependencies in `Package.swift`. Single model constant stays `claude-sonnet-4-6`. Keys stay Keychain-only.
- USER RULE: ask before deleting any file.
- The user is QA; stop and ask where a step says to.

## ⚠️ DO-NOT-REGRESS

- **All Phase 2 invariants hold** (HANDOVER "Phase 2 invariants"): fresh AVAudioEngine per press — do NOT touch audio engine lifetime, BT-mic handling, or AVAudioSession; talk hotkey stays NSEvent monitors (never a CGEvent tap — that would demand Input Monitoring permission); overlay panels stay pre-warmed and click-through-always.
- **Notch/panel invariants hold**: safe-area disabled twice; menu panel window fixed-size and created once in `attach()`; hover hit-testing `zoneContains` unchanged; pages are MOUNTED + opacity-flipped, never insert/remove.
- Dictation (`fn` hotkey) and talk (`⌃⌥`) must both still work after every task.
- After UI-adjacent changes: `tail -2 "$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log"` → panel top == screenMaxY, hostingSafeArea zeros.

---

### Task 1: Double-tap `⌃` detection

**Files:** Modify `Sources/Core/TalkHotkeyMonitor.swift`.

**Interfaces produced:** `var onDoubleTapControl: (() -> Void)?` on `TalkHotkeyMonitor`.

- [ ] **Step 1: Read the file first.** It uses NSEvent global+local `.flagsChanged` monitors and a `handle(flags:)` method with an `isDown` flag for the `⌃⌥` combo. Extend that method — do NOT add a second monitor or a CGEvent tap.

- [ ] **Step 2: Add the detector.** New properties and logic inside `handle(flags:)`:

```swift
    var onDoubleTapControl: (() -> Void)?

    private var lastControlReleaseAt: TimeInterval = 0
    private var controlOnlyWasDown = false
    private static let doubleTapWindow: TimeInterval = 0.4
```

Inside `handle(flags:)`, AFTER the existing `⌃⌥` press/release handling, add control-only tap tracking:

```swift
        // Control ALONE (no option/command/shift) — tracked for double-tap.
        let controlOnly = flags.contains(.control)
            && !flags.contains(.option)
            && !flags.contains(.command)
            && !flags.contains(.shift)

        if controlOnly {
            controlOnlyWasDown = true
        } else if controlOnlyWasDown {
            controlOnlyWasDown = false
            // A control that was part of ⌃⌥ (talk) must never count as a tap.
            guard !isDown else { lastControlReleaseAt = 0; return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastControlReleaseAt <= Self.doubleTapWindow {
                lastControlReleaseAt = 0
                DispatchQueue.main.async { [weak self] in self?.onDoubleTapControl?() }
            } else {
                lastControlReleaseAt = now
            }
        }
```

(Read the existing `handle` carefully: `isDown` is the `⌃⌥` state. If the existing code names it differently, use the real name.)

- [ ] **Step 3: Temporary proof** — in `AppDelegate`, set `TalkHotkeyMonitor.shared.onDoubleTapControl = { TalkHotkeyMonitor.diag("DOUBLE TAP") }` (reuse the existing `diag` helper that writes to the temp log). Build, relaunch, and verify with `tail -f "$(getconf DARWIN_USER_TEMP_DIR)/hush-talk.log"`: double-tapping `⌃` logs once; a single tap does not; `⌃⌥` talk does not; `⌃C`/`⌃⌘` do not.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/TalkHotkeyMonitor.swift Sources/AppDelegate.swift
git commit -m "feat: double-tap control detection on the talk hotkey monitor"
```

---

### Task 2: Chat page UI (no AI yet)

**Files:** Create `Sources/UI/ChatView.swift`; modify `Sources/UI/NudgeMenuView.swift`, `Sources/Models/Settings.swift`.

**Interfaces produced:**
```swift
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    enum Role { case user, hush, error }
    let role: Role
    var text: String
}
@MainActor final class ChatModel: ObservableObject {
    static let shared = ChatModel()
    @Published var messages: [ChatMessage] = []
    @Published var draft: String = ""
    @Published var isThinking: Bool = false
    func appendUser(_ text: String) -> UUID
    func beginHushMessage() -> UUID          // appends an empty .hush message
    func append(_ chunk: String, to id: UUID)
    func fail(_ message: String)             // appends an .error message
    func clear()
}
struct ChatView: View { init(onSend: @escaping (String) -> Void, onCancel: @escaping () -> Void) }
```

- [ ] **Step 1: Settings flag** — add to `Sources/Models/Settings.swift`, matching the existing `@Published`/`didSet`/init pattern exactly:

```swift
    @Published var speakChatAnswers: Bool {
        didSet { UserDefaults.standard.set(speakChatAnswers, forKey: "speakChatAnswers") }
    }
```
init: `self.speakChatAnswers = defaults.object(forKey: "speakChatAnswers") as? Bool ?? false`

- [ ] **Step 2: Build `ChatView.swift`** — read `NudgeMenuView.swift` first and REUSE its existing colors, row helpers, and fonts; do not invent a new visual language.
  - `ScrollViewReader` + `ScrollView` transcript. User rows: right-aligned, gray, 13pt. Hush rows: left-aligned, white, 13pt, `.textSelection(.enabled)`. Error rows: left-aligned, red 12pt. Auto-scroll to the last id on `messages` change and on `isThinking` change.
  - Thinking row while `isThinking`: three small pulsing dots (reuse the nudge's pulse-dot style).
  - Bottom input: rounded dark capsule, `TextField("ask hush…", text: $model.draft)`, `.focused($inputFocused)`, submits on return via `.onSubmit`; disabled while `isThinking`. Trailing: speaker toggle button (`speaker.wave.2.fill` / `speaker.slash.fill`) bound to `settings.speakChatAnswers`, then an up-arrow send button (disabled when draft is blank).
  - Empty state when `messages.isEmpty`: centered muted "ask me about what's on your screen".
  - `.onExitCommand { onCancel() }` for Escape.
  - Expose a way for the controller to focus the field on open: `.onReceive(NotificationCenter.default.publisher(for: .hushChatDidOpen)) { inputFocused = true }`. Declare `extension Notification.Name { static let hushChatDidOpen = Notification.Name("HushChatDidOpen") }` in this file.

- [ ] **Step 3: Register the page** — in `NudgeMenuView.swift`:
  - Add `case chat` to `NudgePage`; `title` → `"Chat"`; `panelSize` → a new `NudgeMenuLayout.chatSize = CGSize(width: 510, height: 420)` (add the constant next to the existing sizes in `NudgeMenuController.swift`).
  - Mount it with the same `pageLayer(...)` call the other pages use: `pageLayer(ChatView(onSend: { ... }, onCancel: { ... }), for: .chat)`. For now `onSend` just appends the user message and a placeholder hush message; Task 3 replaces it.
  - The tab bar / header treats `.chat` like the other sub-pages (back arrow returns to `.home`).

- [ ] **Step 4:** Build, relaunch. Temporarily wire the double-tap from Task 1 to open the panel on `.chat` so it can be seen (the controller work is Task 3 — a crude `NudgeMenuController.shared.open(on:)` + page set is fine here). Verify with the user: layout matches the panel's look, typing works, Escape closes.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/ChatView.swift Sources/UI/NudgeMenuView.swift Sources/UI/NudgeMenuController.swift Sources/Models/Settings.swift
git commit -m "feat: chat page UI inside the notch panel"
```

---

### Task 3: Open-to-chat + keep-open-while-typing

**Files:** Modify `Sources/UI/NudgeMenuController.swift`.

**Interfaces produced:** `func openChat()` on `NudgeMenuController`.

- [ ] **Step 1: Add `openChat()`** — opens the panel on the cursor's screen directly to `.chat`, sized `chatSize`, and posts `.hushChatDidOpen` so the field focuses. Reuse the existing open path (do NOT write a second one): set the page BEFORE opening so the panel opens at the right size, then `open(on: screenUnderCursor)`, then post the notification after the open animation (`DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)`).
- [ ] **Step 2: Suppress mouse-out close while chatting** — in the hover tick's close branch, skip the `outsideTicks` close when the current page is `.chat`. Click-outside and Escape still close (Escape calls the same `close()`). Chat must also close when a talk session starts (the existing `hudState != .idle` observer already calls `close()` — verify it still fires and that the page resets to `.home` on the next open).
- [ ] **Step 3: Wire the hotkey** — in `AppDelegate`, replace the Task 1 temporary handler with `TalkHotkeyMonitor.shared.onDoubleTapControl = { NudgeMenuController.shared.openChat() }`.
- [ ] **Step 4:** Build, relaunch, verify with the user: double-tap `⌃` anywhere → panel opens to Chat with the cursor blinking in the field; move the mouse to the other side of the screen and keep typing → stays open; Escape closes; click-outside closes; `⌃⌥` talk closes it and works normally.
- [ ] **Step 5: Commit**

```bash
git add Sources/UI/NudgeMenuController.swift Sources/AppDelegate.swift
git commit -m "feat: double-tap control opens the chat page focused"
```

---

### Task 4: ChatSession — screen context, streaming answer, optional speech

**Files:** Create `Sources/Core/ChatSession.swift`; modify `Sources/UI/NudgeMenuView.swift` (wire `onSend`), `Sources/Core/ClaudeVisionClient.swift` (only if a text-mode system prompt variant is needed — see Step 2).

**Interfaces produced:**
```swift
@MainActor final class ChatSession {
    static let shared: ChatSession
    func attach(appState: AppState)
    func send(_ text: String)
    func cancel()
}
```

- [ ] **Step 1: Implement `send(_:)`** — read `Sources/Core/TalkSession.swift` first and mirror its structure, error handling, and logging (`diag`) conventions:

```
send(text):
  guard !isBusy, !text.trimmed.isEmpty
  isBusy = true
  SpeechOutputService.shared.stop()            // barge-in
  let userID = ChatModel.shared.appendUser(text)
  ChatModel.shared.draft = ""
  ChatModel.shared.isThinking = true
  appState.hudState = .transcribing            // "Thinking" in the nudge
  task = Task {
    defer { isBusy = false; ChatModel.shared.isThinking = false }
    do {
      let screens = try await ScreenCaptureService.captureAll(excluding: hushWindows)
      var answerID: UUID? = nil
      let answer = try await ClaudeVisionClient.shared.ask(
          transcript: text, screens: screens, croppedRegion: nil) { chunk in
        if answerID == nil {
          ChatModel.shared.isThinking = false
          answerID = ChatModel.shared.beginHushMessage()
        }
        ChatModel.shared.append(chunk, to: answerID!)
        if AppSettings.shared.speakChatAnswers {
          // Reuse TalkSession's sentence-splitting approach: enqueue whole
          // sentences as they complete, never partial words.
        }
      }
      if AppSettings.shared.speakChatAnswers {
        // flush any trailing partial sentence via SpeechOutputService.enqueue
        appState.hudState = .speaking            // until SpeechOutputService.isSpeaking flips false
      } else {
        appState.hudState = .idle
      }
    } catch is CancellationError {
      appState.hudState = .idle
    } catch {
      ChatModel.shared.fail(<short human message from the ClaudeError case>)
      appState.hudState = .idle
    }
  }
```

Requirements: `hushWindows` must include the nudge panel, the menu panel AND the chat's own panel (it's the same menu panel — verify `ScreenCaptureService.captureAll(excluding:)` is passed the same window list `TalkSession` passes, plus nothing new). `cancel()` cancels `task` and stops speech. Sentence-splitting for TTS must reuse whatever helper `TalkSession` already has — if it's private, extract it to a shared internal helper rather than duplicating the logic.

- [ ] **Step 2: System prompt for typed questions** — the Phase 2 prompt says "your reply will be spoken aloud". For typed chat the answer is READ, so a spoken-only prompt is wrong when the speaker toggle is off. Add an optional `style` parameter to `ClaudeVisionClient.ask` (`enum AnswerStyle { case spoken, written }`, defaulting to `.spoken` so Phase 2 call sites are unchanged) that swaps the last two prompt lines: for `.written`, allow short paragraphs and inline code, still no markdown headers, still concise (2–5 sentences). Chat passes `.written` when `speakChatAnswers` is off and `.spoken` when it's on.

- [ ] **Step 3: Wire the view** — `NudgeMenuView`'s `pageLayer(ChatView(onSend:onCancel:))` now calls `ChatSession.shared.send(text)` and `ChatSession.shared.cancel()`; `AppDelegate` calls `ChatSession.shared.attach(appState:)` next to the `TalkSession.shared.attach(...)` call.

- [ ] **Step 4: Build, relaunch, FULL test with the user:**
  1. Double-tap `⌃`, ask "what app am I looking at?" → streams a correct answer.
  2. Speaker toggle ON → the same question is also spoken; nudge shows Speaking.
  3. Ask a follow-up with no new context ("say that shorter") → correct, proving memory.
  4. **Shared memory:** ask something out loud with `⌃⌥`, then double-tap and type "explain that more" → it knows.
  5. Escape mid-answer → cancels cleanly, input usable again.
  6. Wrong key / airplane mode → red row in the transcript, no crash.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ChatSession.swift Sources/Core/ClaudeVisionClient.swift Sources/UI/NudgeMenuView.swift Sources/AppDelegate.swift
git commit -m "feat: chat sends screen context to Claude and streams the answer"
```

---

### Task 5: Barge-in polish

**Files:** Modify `Sources/Core/TalkSession.swift`.

- [ ] **Step 1:** Today `begin()` stops playback but there is no smooth interrupt. Make pressing `⌃⌥` while `SpeechOutputService.shared.isActive` do: stop speech immediately, clear the answer bubble, AND skip any residual "Speaking" state so the nudge goes straight to Listening with no visible flicker. Verify the existing `isBusy` guard doesn't reject the new press because the previous session hasn't finished its speech phase — if it does, split the guard so "speaking" is interruptible but "capturing/transcribing/streaming" is not.
- [ ] **Step 2:** Test with the user: ask something long, and while it's talking press `⌃⌥` and ask something else → audio cuts instantly, nudge shows Listening, second answer plays normally.
- [ ] **Step 3: Commit** `git commit -m "polish: interrupting a spoken answer starts the next question cleanly"`

---

### Task 6: QA + docs

- [ ] **Step 1: Full sweep** — chat (open/type/stream/speak/cancel/errors), talk mode, dictation, hover panel, all settings rows, both displays, fullscreen app, geometry log clean, cost check in the Anthropic console.
- [ ] **Step 2: Home shortcuts row** — the "Text" entry in `NudgeMenuView`'s shortcuts array flips from disabled to enabled showing `⌃` `2×`.
- [ ] **Step 3: Update `docs/superpowers/HANDOVER.md`** — mark Phase 3 SHIPPED in the roadmap table, add a Phase 3 section (files, flow, decisions) and any new invariants discovered (e.g. "chat page suppresses mouse-out close", "ask() takes an AnswerStyle").
- [ ] **Step 4: Final commit** `git commit -m "polish: phase 3 QA fixes and handover update"`
