# Phase 2 — Circle-to-Ask (Talk) — Design

Date: 2026-08-02. Status: Approved ("exactly what Clicky has").
Predecessors: Phase 1 nudge + Phase 1.5 notch panel (both shipped).

## The feature, exactly as Clicky does it

1. User holds the Talk hotkey (default `⌃⌥`, configurable).
2. A transparent overlay covers every screen. While the hotkey is held the
   user can drag the mouse to draw a freehand circle/loop around any region
   — the stroke is drawn live (teal, ~3pt, fades tail-first). Drawing is
   optional: holding and just speaking works too (whole screen as context).
3. Simultaneously the mic records; WhisperKit transcribes locally on release.
4. On release: capture every screen via ScreenCaptureKit (excluding Hush's
   own windows), downscale to max 1280px, JPEG 0.8. If a region was circled,
   ALSO crop that region and send it as a second, zoomed image plus the
   bounding-box coordinates.
5. Send screenshots + transcript to Claude (streaming) with a spoken-style
   system prompt (short, lowercase, conversational, describes what it sees,
   references the circled region when present).
6. The reply is spoken aloud via OpenAI TTS and shown as a small text bubble
   near the cursor (max ~340pt wide, fades after ~6s) — Clicky's behavior.
7. Nudge states drive the whole flow: Listening (teal) → Thinking (purple)
   → Speaking (new state, animated bars while audio plays) → idle.
8. Conversation memory: last 10 exchanges kept in RAM so follow-ups work
   ("what about that one?"). Cleared after 10 minutes idle.

## Fixed decisions (do not re-litigate)

- **One model: `claude-sonnet-4-6`.** No model picker. If it ever changes,
  it is one constant in the code.
- **Voice: OpenAI TTS** (`gpt-4o-mini-tts`, voice configurable in settings,
  default "alloy"). NOTE: OpenAI receives the ANSWER TEXT only — never
  audio, never screenshots. Claude receives screenshots + transcript.
- **Speech-to-text stays local** (WhisperKit) — voice audio never leaves
  the Mac. This is Hush's privacy edge and is non-negotiable.
- **Keys live in the macOS Keychain**, entered in the notch panel's
  Settings page. No backend, no accounts.
- Cost target ≈ 1.1¢ per question (~$10–20/month at vibe-coding volume).

## Architecture

New files under `Sources/`:

| File | Responsibility |
|---|---|
| `Core/KeychainStore.swift` | read/write/delete API keys in the Keychain |
| `Core/TalkHotkeyMonitor.swift` | CGEvent tap for hold-`⌃⌥` press/release |
| `UI/CircleOverlayController.swift` | one click-through-until-active transparent panel per screen; owns the stroke path |
| `UI/CircleOverlayView.swift` | draws the live stroke |
| `Core/ScreenCaptureService.swift` | ScreenCaptureKit multi-display capture, downscale, self-exclusion, region crop |
| `Core/ClaudeVisionClient.swift` | Anthropic Messages API, streaming SSE, base64 images, 10-exchange context |
| `Core/SpeechOutputService.swift` | OpenAI TTS request + AVAudioPlayer playback, `isSpeaking` published |
| `UI/AnswerBubbleController.swift` | cursor-adjacent text bubble, 340pt cap, 6s fade |
| `Core/TalkSession.swift` | orchestrates the whole flow and drives `AppState` |

Existing files touched: `HUDState` (add `.speaking`), `NudgeView` (render
it), `AppState` (talk state + wiring), `NudgeMenuView` (Settings rows:
API keys, voice, Talk hotkey; Home shortcuts row becomes enabled),
`Package.swift` unchanged (no new dependencies).

## Error handling

- Missing/invalid API key → nudge shows a red error, bubble explains, and
  Settings highlights the key row. Never crash, never retry-loop.
- Network failure/timeout (20s) → red error state, spoken nothing.
- Empty transcript (user held the key but said nothing) → silently return
  to idle, no API call (saves money).
- Screen-recording permission missing → error state + one-time prompt.
- TTS failure → still show the bubble; the answer isn't lost.

## Testing

Manual, with the user: hold-talk with and without circling, on both
displays, in fullscreen apps, with a wrong key, with no network, and a
follow-up question to verify conversation memory. Cost sanity: confirm
Anthropic console usage matches ~1¢/question.
