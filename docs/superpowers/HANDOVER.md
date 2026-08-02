# Hush → Clicky-Style Companion: Project Handover

Updated: 2026-08-02. Read this first in any new session, then the dossier:
`docs/superpowers/research/2026-07-31-clicky-research-dossier.md`.

## What Hush is becoming

Hush (local WhisperKit dictation app, SwiftPM, macOS 14+) is being evolved
into a HeyClicky-style AI companion that lives in the MacBook notch.
Personal build for Lord Berries: his own API keys (Anthropic + OpenAI,
stored in Keychain), NO backend, voice audio NEVER leaves the Mac
(STT stays local WhisperKit — this privacy edge over Clicky is deliberate).

## Full roadmap and status

| Phase | What | Status |
|---|---|---|
| 1 | Notch nudge (idle shelf/pill, Listening/Thinking states) | ✅ SHIPPED |
| 1.5 | Notch panel = entire UI (hover-open, Home/Agents tabs, settings, sub-pages; dashboard deleted) | ✅ SHIPPED |
| 2 | Circle-to-ask: hold hotkey → circle screen region → ask aloud → Claude answers, spoken via OpenAI TTS | ✅ SHIPPED |
| 3 | Text chat (double-tap ctrl): "ask Hush…" input with screen context; answer bubble near cursor (~340px, ~6s fade) | not started |
| 4 | Cursor triangle companion (follows mouse, flies to [POINT:x,y:label] coords from Claude) | not started |
| 5 | Agents (spawn local Claude Code CLI subprocess; Agents tab placeholder already in panel) | not started |
| later | Realtime voice (OpenAI gpt-realtime, voice "cedar"), wake word | optional |

Target hotkey map (mirrors HeyClicky): hold `ctrl+option` = talk/circle ·
double-tap `ctrl` = text chat · `fn+ctrl` = dictate (works today) ·
double-tap = hands-free (works today).

## What is already built (Phases 1 + 1.5, all on master)

- **Nudge**: black notch extension. Idle = notch +72pt wide shelf (pill on
  notchless externals). Recording = "Listening" + teal bars (notch+260,
  flush bottom). Transcribing = "Thinking" + purple dots. Errors red.
  Files: `Sources/UI/NudgeView.swift`, `NudgeShape.swift`,
  `NotchNudgeController.swift`.
- **Notch panel** (the whole app UI): hover the notch/pill → panel grows
  out. Home | Agents tab bar + gear. Home = Clicky-style (shortcuts list
  driven by a data array, skills column, integrations bar, cursor button).
  Settings = sectioned rows (Dictation, Shortcuts, Sound, Microphone
  picker — properly wired via CoreAudio, System, Library: History/
  Insights/Scratchpad sub-pages, Check for Updates, Quit, version).
  Dictionary/Snippets pages REMOVED (stored data still applies silently).
  Files: `Sources/UI/NudgeMenuController.swift`, `NudgeMenuView.swift`.
- **Dashboard window: deleted.** Onboarding window remains.
- Dictation pipeline untouched throughout: WhisperKit local STT, optional
  Ollama cleanup, paste via Cmd+V, SQLite history.

## Phase 2 — Circle-to-ask (SHIPPED)

Owner-confirmed working: hold `⌃⌥` → circle a screen region → speak → hear
the answer. Written answer bubble is opt-in via a settings toggle
(`AppSettings.showAnswerBubble`, default OFF — voice-only by default).

**The full chain, component by component:**
- `Sources/Core/TalkHotkeyMonitor.swift` — hold-to-talk detector for the
  modifier-only `⌃⌥` combo. NSEvent global+local `.flagsChanged` monitors,
  NOT a CGEvent tap → Input Monitoring permission is NOT required
  (Accessibility trust alone delivers the events; verified empirically).
  onPress/onRelease drive the session.
- `Sources/UI/CircleOverlayController.swift` — one borderless transparent
  panel per display, pre-warmed once and reused forever. `begin()` on press
  samples the cursor at 60fps and draws the stroke; `end()` returns the
  padded bounding box in global AppKit coords. Panels are click-through at
  ALL times (drawing needs no mouse button — hold `⌃⌥` and move, like
  HeyClicky); they only display ink, never capture input. Debounced
  self-heal takes the overlay down if the paired release is ever lost.
- `Sources/Core/AudioCaptureService.swift` — SHARED with dictation. Records
  via a **fresh AVAudioEngine per press** (see invariant below).
- `Sources/Core/LocalTranscriptionService.swift` — WhisperKit, **on-device**.
  The spoken question NEVER leaves the Mac.
- `Sources/Core/ScreenCaptureService.swift` — captures all displays
  (excluding Hush's own windows) and crops to the circled region.
- `Sources/Core/ClaudeVisionClient.swift` — streams the answer from Claude
  (`claude-sonnet-4-6`, the single model constant), user's key from Keychain.
- `Sources/Core/SpeechOutputService.swift` — OpenAI TTS, playback-only via
  AVAudioPlayer (no engine/session/route APIs). Plays an ORDERED SEGMENT
  QUEUE: `enqueue(_:)` sentence-sized segments, drained strictly in order,
  back-to-back, with segment N+1 prefetched while segment N plays (gapless).
  `isSpeaking`/`isActive` span first segment to queue drain; `stop()` clears
  the queue + cancels the in-flight fetch + halts playback. 20s fetch timeout.
- `Sources/Core/TalkSession.swift` — the orchestrator. Wires all the above.
  Starts screen capture BEFORE transcription (overlaps + fresh screenshot),
  skips the API on an empty transcript (no charge), and **speaks the first
  sentence while the rest of the answer still streams** (sentence-pipelined
  TTS) so time-to-first-word is one sentence + one TTS fetch, not the whole
  answer + whole fetch. `@MainActor`; single re-entrancy guard (`isBusy`)
  plus a lost-release watchdog.
- `Sources/UI/AnswerBubbleController.swift` — cursor-adjacent streaming
  answer bubble, shown only when `showAnswerBubble` is on.

**Phase 2 invariants (do not regress):**
- **API keys live in the Keychain ONLY** (`KeychainStore`), never on disk in
  plaintext. Anthropic + OpenAI.
- **STT stays local** (WhisperKit). The voice audio never leaves the Mac —
  this privacy edge over Clicky is deliberate.
- **Single model constant**: `claude-sonnet-4-6`. One place, no per-call
  overrides.
- **Overlay panels are pre-warmed and click-through-always.** Built once,
  reused; they display ink only, never eat clicks.
- **Fresh AVAudioEngine per press.** Engine reuse and Bluetooth-mic
  avoidance were tried and BROKE recording (dead tap, 4KB files) and were
  fully reverted in commit `896e82f`. **Do NOT retry** engine reuse, BT-mic
  redirection, AVAudioSession/route changes, or AudioUnitUninitialize.
- **Talk hotkey is NSEvent monitors, not a CGEvent tap** → Input Monitoring
  is NOT required.
- **Build signs with the Apple Development identity and syncs /Applications**
  (`./build.sh`). Unified logging is invisible for this bundle, so Phase-2
  diagnostics append to a temp file (`hush-talk.log`).
- **Written answer is opt-in** via `AppSettings.showAnswerBubble` (default
  off; voice-only).

**Known deliberate gap: barge-in.** Pressing `⌃⌥` again while an answer is
still being spoken does stop the current playback (`begin()` calls
`SpeechOutputService.stop()` and clears the bubble), but there is no smooth
"interrupt and immediately re-listen" flow beyond that hard stop. Left as a
future refinement.

## Hard-won invariants — regressions here have burned us before

1. Safe-area must stay disabled TWICE for any notch-area panel:
   `hosting.safeAreaRegions = []` AND `.ignoresSafeArea()` — else macOS
   silently shoves content 32pt down on the notched screen only.
2. Menu panel WINDOW is fixed-size, created ONCE in `attach()`, never
   frame-animated; all grow/shrink is SwiftUI springs inside
   `NudgeMenuView`. (NSPanel frame animation over live SwiftUI stutters.)
3. Hover hit-testing: top edge INCLUSIVE (`zoneContains` — cursor pins at
   exactly maxY). Zones match the visible target only (notch width /
   188pt pill); bigger swallows Chrome tabs, smaller is unhittable.
4. View state switching = mounted views + opacity flips, never
   insert/remove transitions (they strand ghosts in non-activating panels).
5. Close-animation completions are generation-guarded so a reopen during
   close can't leave the panel hidden-but-"open".
6. Geometry self-check: app writes NUDGE-GEO lines on launch to
   `$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log` — after any nudge
   change verify: panel top == screenMaxY, hostingSafeArea all zeros.
   (Temporary — remove in a final cleanup pass someday.)

## Working conventions (how Lord Berries runs this project)

- Cycle per feature: I analyze/design → write spec + PLAN with full code
  into `docs/superpowers/plans/` (guarded with DO-NOT-REGRESS headers) →
  he hands the plan to an Opus/Sonnet session to execute → he tests by
  hand and reports back in plain words → fix rounds until it feels like
  the real HeyClicky (he runs it side-by-side; he is visual QA).
- Build: `swift build`; bundle+run: `pkill -x Hush; ./build.sh && open Hush.app`.
  NEVER `xcodebuild` (invalidates TCC). No test target; verification is
  manual.
- USER RULES: never delete/move files without asking him first (plans put
  explicit ask-gates before deletions). Projects stay in
  `/Users/jberries/AI files`. Explain things clearly — he's a vibe coder.
  Don't capture his screen with screencapture — blocked & unwanted; use
  code probes (CGWindowList, self-logging) or ask for screenshots.
- When he reports a visual bug, get evidence before editing: read the
  actual code state (other sessions modify it between our turns), use the
  geometry log, measure his screenshots (pixel-measure with PIL against a
  known-size element; screenshots are 2× Retina).
- His device: M2 MacBook Air 13" (notch 179×32pt in his scaled mode) +
  a 3440×1440 external ultrawide (no notch → pill UI).

## Key documents

- **Dossier** (read before Phase 2–5 work):
  `docs/superpowers/research/2026-07-31-clicky-research-dossier.md` —
  all research: HeyClicky architecture (OpenAI Realtime router + Claude
  vision + bundled Codex agents + Deepgram dictation), reference-repo
  re-clone commands (farzaa/clicky is MIT open source; glide has the
  cursor companion + TTS pipeline; openclicky has circle-select + agents),
  app-bundle intel (/Applications/HeyClicky.app — readable agent rulebook
  in Resources/ClickyModelInstructions.md), per-phase pointers, their
  weaknesses we exploit.
- UI/behavior research:
  `docs/superpowers/research/2026-08-01-heyclicky-ui-behavior-research.txt`
- Executed plans (history + patterns): `docs/superpowers/plans/` —
  notch-nudge, notch-settings-panel, notch-menu-polish,
  notch-menu-seamless, dashboard-into-notch, home-declutter-agents-tab.
- Specs: `docs/superpowers/specs/`.

## Immediate next steps (new session starts here)

1. **Write Phase 2 spec + plan** (circle-to-ask). Design decisions already
   made: hold-hotkey → transparent overlay captures a drawn circle →
   screenshot cropped to region + full screen → Claude (streaming,
   user's key from Keychain) → answer spoken via OpenAI TTS + shown as
   text; question transcribed locally by WhisperKit. Sequence the plan so
   the KEYLESS half ships first (overlay + circle drawing + capture +
   local STT); API halves gated on keys. Overlay windows must follow the
   same safe-area + click-through patterns as the nudge (farzaa-clicky's
   OverlayWindow.swift is the reference).
2. **User to-dos**: create Anthropic + OpenAI API keys (~$5 credit each —
   NOT per session; a one-time balance, cents per question). Two pending
   deletions awaiting his OK: untracked `mic_probe.swift`, old Hush copy
   in /Applications.
3. New settings needed in the panel when Phase 2 lands: API keys entry
   (Keychain-backed), voice picker, talk hotkey row (the Home shortcuts
   array already has a disabled "Talk" row waiting).
