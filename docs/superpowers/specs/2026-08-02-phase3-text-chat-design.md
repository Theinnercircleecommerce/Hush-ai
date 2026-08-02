# Phase 3 — Text Chat — Design

Date: 2026-08-02. Status: Approved.
Predecessors: Phases 1, 1.5, 2 (all shipped).

## The feature, as Clicky does it

Double-tap `⌃` → the notch panel opens straight to a **Chat** page with the
input focused. Type a question, hit return, and Hush answers with the same
screen context and the same conversation memory as talk mode. Escape or
click-outside closes it.

1. **Trigger:** double-tap `⌃` (control alone, twice within 400ms, no other
   modifiers). Extends the existing `TalkHotkeyMonitor`, which already
   watches `.flagsChanged` via NSEvent monitors.
2. **Chat page** inside the existing notch panel — a new `NudgePage.chat`,
   mounted like every other page (opacity flip, pre-warmed):
   - Scrollable transcript of the current conversation (user turns right-
     aligned muted, Hush turns left-aligned white), auto-scrolls to bottom.
   - "ask hush…" rounded input at the bottom, focused on open, with a send
     arrow and a speaker toggle (speak-the-answer on/off, remembers state).
   - Empty state: the Hush glyph plus "ask me about what's on your screen".
3. **On send:** capture the screen (all displays, same service as Phase 2 —
   no circle region), stream the answer from Claude into the transcript,
   and speak it if the speaker toggle is on. Nudge shows Thinking, then
   Speaking when audio plays.
4. **Shared memory:** the chat and talk mode use the SAME
   `ClaudeVisionClient` history, so you can circle-and-ask out loud, then
   double-tap and type "now explain that in more detail" and it knows.
5. **Barge-in fix (folded in):** starting either mode while an answer is
   playing stops audio cleanly and begins the new turn.

## Fixed decisions

- Same single model (`claude-sonnet-4-6`), same Keychain keys, same TTS.
- The chat lives INSIDE the notch panel — no second window, no dock icon.
- Speaking in chat is OPT-IN per the toggle, default OFF (typing usually
  means the user wants quiet). The toggle persists in `AppSettings`.
- The panel already returns `canBecomeKey = true`, so typing works without
  activating the app; the user's app keeps focus otherwise.

## Behavior details that matter

- Double-tap must not fire while `⌃⌥` talk is in progress, and a `⌃` that
  is part of any other combo (⌃⌥, ⌃⌘, ⌃⇧…) must never count as a tap.
- Opening chat cancels the hover-close timer: the panel must STAY open
  while typing even if the mouse is elsewhere. It closes on Escape, on
  send-then-mouse-away, or on click-outside — never on mouse-out alone
  while the chat page is showing.
- While a request is in flight: input disabled, a small animated "thinking"
  row appears at the end of the transcript, Escape cancels the request.
- Errors (missing key, network, HTTP) render as a red row in the transcript
  rather than an alert; the input stays usable.

## Testing

Manual: double-tap opens focused; typing while the mouse is away keeps it
open; answers stream; speaker toggle works both ways; follow-up after a
voice question uses shared memory; Escape and click-outside close; talk
mode still works; dictation still works; geometry log clean.
