# Notch Nudge (HUD Rebuild) — Phase 1 Design

Date: 2026-07-31
Status: Approved by Lord Berries (conversation, 2026-07-31)

## Context

Hush is evolving from a dictation-only app into a Clicky-style AI companion
(decision: Approach 1 — port capabilities into Hush, phase by phase, personal
use with the user's own API keys). Phase roadmap:

1. **Nudge rebuild (this spec)** — replace the floating HUD pill with a
   Clicky-style notch-anchored nudge. Visual only; no new capabilities.
2. Circle-to-ask: screen region selection + Claude vision + spoken replies.
3. Chat dropdown (double-tap hotkey) with screen context.
4. Cursor triangle companion.
5. Agents (bundled CLI runtime).

Reference material (read-only, in /tmp/clicky-refs/):
- `glide/apps/macos/Glide/GlideDynamicIslandManager.swift` — notch island
  panel, animatable notch shape, spring expand/collapse. Primary mechanical
  reference for this phase.
- `farzaa-clicky/leanring-buddy/OverlayWindow.swift` + `MenuBarPanelManager.swift`
  — farza's original MIT-licensed Clicky source (panel levels, collection
  behavior, non-activating panels).
- User screenshots of the real HeyClicky v1.0.44 nudge (idle pill,
  Listening, Thinking, chat input) — visual ground truth. The user acts as
  visual QA against the real app installed at /Applications/HeyClicky.app.

We reference mechanics from these repos but write our own implementation and
do not copy HeyClicky's bundled assets.

## Visual & interaction design

Four states, driven by the existing `HUDState` enum:

1. **Idle** — (amended 2026-07-31 after visual QA on real hardware) On the
   notched built-in display: NO pill — the notch itself simply reads a bit
   wider (black shelf, `notchWidth + 72` × `notchHeight + 1`, a
   pixel-measured match of HeyClicky's 250×33pt idle bar, flush with the
   notch bottom). On notchless displays only: thin translucent light-gray
   pill at the top edge.
2. **Listening** (maps to `.recording`) — the pill hands off to a notch
   expansion: a black panel that makes the notch appear wider, with rounded
   lower corners. "Listening" label on the left side of the notch, animated
   waveform dots on the right in teal, amplitude driven by the existing
   `audioLevel` RMS feed.
3. **Thinking** (maps to `.transcribing`) — same expanded notch shape,
   "Thinking" label, purple dots with a pulse animation.
4. **Error** — same expanded notch shape, short red-tinted message,
   auto-hides back to the idle pill.

Transitions: spring animations (Dynamic Island feel) — pill fades/retracts as
the notch expansion grows, and the reverse on completion.

Displays without a notch (external monitors): render the same states as a
floating black pill centered at the top edge.

Removed: the HUD position setting (top/bottom). The nudge lives at the top
only. All other settings (sounds, hotkeys, dictation behavior) unchanged.

## Technical design

New components, replacing `HUDWindowController`/`HUDView` usage:

- **`NotchNudgeController`** (AppKit): owns one borderless, non-activating,
  click-through `NSPanel` per screen.
  - Level: above the menu bar (glide uses `.mainMenu + 3`).
  - `collectionBehavior`: `[.canJoinAllSpaces, .stationary,
    .fullScreenAuxiliary, .ignoresCycle]` so it shows over fullscreen apps.
  - Sized/positioned from the real notch geometry via `NSScreen`
    safe-area/auxiliary-area APIs; fallback geometry for notchless displays.
- **`NudgeView`** (SwiftUI, hosted via `NSHostingView`): renders all four
  states, including an animatable notch outline shape (top corners square,
  bottom corners rounded, width/height animatable — same approach as glide's
  `GlideNotchShape`).
- **State flow unchanged**: `AppState.hudState` (existing enum: idle,
  recording, transcribing, error) keeps driving the UI. No changes to
  dictation, hotkeys, transcription, paste, or history logic. The enum gains
  no new cases in this phase; Phase 2 will add talk states.

Files expected to change: `Sources/UI/HUDView.swift` (replaced),
`Sources/UI/HUDWindowController.swift` (replaced), `Sources/Core/AppState.swift`
(controller wiring only), `Sources/UI/FullSettingsView.swift` +
`Sources/Models/Settings.swift` (remove position option).

## Error handling

- No notch detected (older MacBook / external display): fallback pill path.
- Multiple displays: panel per screen; active-state animation runs on the
  screen with the notch (built-in display) and the fallback pill elsewhere.
- Screen parameter changes (display added/removed, resolution change):
  rebuild panels on `NSApplication.didChangeScreenParametersNotification`.

## Testing

Manual, against the running app (no UI test target exists):
1. Build and run; verify idle pill position/translucency vs HeyClicky
   side by side (user is visual QA).
2. Dictate: verify Listening (teal dots animate with voice), Thinking
   (purple pulse), and return to idle.
3. Force an error (e.g. ultra-short recording path) and verify error state.
4. Fullscreen app: nudge still visible during dictation.
5. External monitor: fallback pill renders and animates.

## Estimate

2–3 working sessions (~2–3 days).
