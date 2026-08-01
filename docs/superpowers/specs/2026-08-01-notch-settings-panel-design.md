# Notch Settings Panel (Phase 1.5) — Design

Date: 2026-08-01. Status: Approved by Lord Berries (conversation).
Predecessor: Phase 1 nudge (`2026-07-31-notch-nudge-design.md`) — DONE.

## What we're building

The standalone Settings tab in the dashboard is replaced by a Clicky-style
**two-view mini-app that springs out of the notch** (or out of the top pill
on notchless displays):

1. **Home view** — opens when the user hovers over the nudge. Compact
   (~510×260): top bar ("Home" label left, gear button right), quick stats
   (words today, day streak), a shortcuts cheat-sheet (Dictate hotkey now;
   later phases append Talk/Text rows), and an "Open Dashboard" button.
2. **Settings view** — opens when the gear is clicked; same panel springs
   taller (~510×640, scrollable). Dark sectioned rows mirroring HeyClicky's
   settings layout (user screenshots 2026-08-01 19:20/19:21):
   - DICTATION: Whisper model size, language, AI cleanup toggle (+ Ollama
     model name when cleanup is on)
   - SHORTCUTS: KeyboardShortcuts recorder row
   - SOUND: start/stop sound pickers
   - MICROPHONE: device picker, properly wired (today's "Change" button is
     a stub) — shows current device name like HeyClicky's "AirPods Max"
   - SYSTEM: launch at login, show in dock, menu-bar icon style
   - SUPPORT: Check for Updates row
   - Bottom: red "Quit Hush" row, version footer (e.g. "v1.0.21")
   - Experimental toggles (command mode, press enter, bulk import) fold
     into DICTATION section as secondary rows.

Deliberately NOT included (no equivalents in Hush): Agents tab, Plan/
Upgrade block, Community links, Log Out / Delete Account.

## Interaction rules

- Hover over the notch shelf / pill zone → Home view springs open.
  Closes on: click anywhere outside, or dictation starting. Click-outside
  uses a global monitor with a short grace delay (farzaa-clicky pattern)
  so system dialogs aren't interrupted. (Mouse-exit auto-close is optional
  QA polish, only if the user asks for it.)
- Gear toggles Home ↔ Settings within the same panel (animated height).
- The panel is non-activating (never steals focus from the app below) but
  can become key so text fields and the shortcut recorder work
  (farzaa-clicky `KeyablePanel` pattern).
- While recording/transcribing, hover does nothing (the nudge is busy
  showing state); panel also auto-closes when dictation starts.
- Dashboard keeps: Home, Insights, Dictionary, Snippets, Style, Transforms,
  Scratchpad. The Settings sidebar item, `FullSettingsView`, and the
  onboarding deep-link that sets `selectedSidebarItem = "Settings"`
  (`Sources/HushApp.swift:30`) are removed/re-routed to the notch panel.

## Architecture (invariant-safe)

The Phase 1 nudge display panel is NOT touched — its invariants stand
(safe-area disabled twice, measured sizes, click-through). New pieces:

- **Hover catcher**: a tiny invisible panel over the notch-shelf zone that
  accepts mouse events and owns an `NSTrackingArea`. The notch zone has no
  clickable menu-bar content, so intercepting the mouse there is safe. On
  notchless displays the catcher sits over the pill zone.
- **`NudgeMenuController`**: owns the menu panel (`KeyablePanel`-style
  NSPanel, `.nonactivatingPanel`, level mainMenu+3, can become key),
  positions it centered under the notch/top edge, animates open/close,
  installs the click-outside monitor.
- **`NudgeMenuView`** (SwiftUI): the two views + section row components.
  Reuses `AppSettings.shared` published properties directly.
- **Mic wiring**: `AVCaptureDevice.DiscoverySession` lists inputs; the
  chosen device's UID is stored in the existing
  `AppSettings.selectedMicrophoneID` and applied to the AVAudioEngine
  input node via CoreAudio (`kAudioOutputUnitProperty_CurrentDevice`) in
  `AudioCaptureService`.

## Testing

Manual (user is visual QA vs the real HeyClicky): hover open/close feel,
gear switch, every settings row functional, mic picker switches the actual
capture device (verify by dictating with a different mic selected),
click-outside dismissal, panel never steals focus while typing in another
app, dictation auto-closes the panel, external-display behavior.

## Estimate

2–3 working sessions.
