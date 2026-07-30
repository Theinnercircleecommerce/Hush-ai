# Clicky → Hush Research Dossier

Date: 2026-07-31. Purpose: everything learned while researching HeyClicky so
future sessions can design and implement Phases 2–5 without re-research.
Companion docs: `docs/superpowers/specs/2026-07-31-notch-nudge-design.md`
(Phase 1 spec) and `docs/superpowers/plans/2026-07-31-notch-nudge.md`
(Phase 1 plan).

## 1. Decisions already made (do not re-litigate)

- **Approach 1**: port Clicky-style capabilities INTO Hush, phase by phase.
  Hush remains the app; keep local WhisperKit dictation, history, Sparkle.
- **Option A**: personal build for Lord Berries. His own API keys (Keychain),
  direct API calls, NO backend, no accounts/billing.
- **Privacy rule**: raw voice audio never leaves the Mac. STT stays local
  (WhisperKit). Only text + screenshots (on explicit trigger) go to cloud AI.
- **Keys needed from Phase 2**: Anthropic (screen understanding) + OpenAI
  (TTS now, Realtime voice later). Ballpark heavy use: $10–40/month.
- **Phases**: 1 nudge (specced+planned) → 2 circle-to-ask + spoken replies →
  3 chat dropdown (double-tap hotkey) → 4 cursor triangle companion →
  5 agents (bundled CLI runtime; prefer Claude Code over Codex).
- **Hotkey map to mirror** (from real app): hold `ctrl+option` = talk;
  double-tap `ctrl` = text chat; `fn+ctrl` = dictate; double-tap `fn+ctrl`
  = hands-free dictation.
- Never copy HeyClicky's bundled assets/branding. Mechanics and ideas are
  fair game; MIT-licensed reference code is usable.

## 2. What the real HeyClicky is (confirmed facts)

App: /Applications/HeyClicky.app, v1.0.44 (build 53), bundle id
`com.humansongs.clicky`, native Swift (AppKit+SwiftUI), macOS 14.2+,
LSUIElement menu-bar app. Frameworks: Sparkle (appcast:
farzaa.github.io/clicky-releases/appcast.xml) + Sentry. PostHog analytics,
PLCrashReporter. Backend: api.heyclicky.com (+ a Supabase instance).

Pipeline (from TBPN interview + binary inspection):
- **Voice talk**: OpenAI **gpt-realtime** (voices incl. Cedar/Marin —
  exclusive to that API; preview MP3s ship in the bundle). Realtime also
  acts as the tool-calling ROUTER.
- **Screen understanding**: routed to **Claude** (default) with screenshots.
- **Dictation**: **Deepgram** cloud STT via their server
  (`/v2/dictation/deepgram-token`, `/transcribe`, `/cleanup` routes in the
  binary). Their dictation is cloud → Hush's on-device WhisperKit is a
  genuine privacy edge; keep it.
- **Agents**: bundled **Codex CLI runtime** (Resources/CodexRuntime/bin +
  vendor) spawned as local subprocess, plus local MCP servers:
  `computer-use` (Cua-backed GUI control) and `composio` (Gmail, Notion,
  Linear, Google Workspace integrations).
- History: farza (buildspace) built it in ~8 weeks from Jan 2026; viral
  April 2026; YC Spring 2026. clicky.so = same product, earlier domain.
  clicky.foo = unaffiliated Windows clone.

## 3. Reference code (CRITICAL — /tmp is wiped on reboot)

Re-clone anytime:

```bash
mkdir -p /tmp/clicky-refs && cd /tmp/clicky-refs
git clone --depth 1 https://github.com/farzaa/clicky.git farzaa-clicky   # REAL open-source Clicky, MIT
git clone --depth 1 https://github.com/jasonkneen/openclicky.git         # fork: agents, circle-select, realtime voice
git clone --depth 1 https://github.com/shujanshaikh/glide.git            # best notch island + cursor companion
git clone --depth 1 https://github.com/dabit3/heyclicky-clone.git        # clean minimal pill + vision pipeline
```

### farzaa-clicky (MIT, the real product's ancestor — primary reference)
Xcode project `leanring-buddy.xcodeproj` (typo intentional). Key files in
`leanring-buddy/`:
- `OverlayWindow.swift` (~881 lines) — fullscreen transparent click-through
  overlay per screen (`.screenSaver` level, canJoinAllSpaces/stationary/
  fullScreenAuxiliary) + `BlueCursorView` triangle: 60fps mouse-follow
  (offset +35x/+25y), quadratic-Bezier arc flight (0.6–1.4 s by distance,
  smoothstep easing, 1.3x mid-flight scale).
- `CompanionManager.swift` — central state; `[POINT:x,y:label(:screenN)]`
  regex parse (~line 784); coordinate transforms (~lines 648–674):
  screenshot px → display points (scale) → AppKit bottom-left origin
  (y-flip) → global coords (add display frame origin).
  System prompt (~lines 544–577): lowercase, spoken-style, 1–2 sentences,
  describes POINT protocol. Context = last 10 exchanges, POINT tags
  stripped before storing.
- `ClaudeAPI.swift` — Anthropic messages API, streaming SSE parse,
  base64 image blocks, max_tokens 1024, TLS-warmup HEAD request trick.
- `CompanionScreenCaptureUtility.swift` — ScreenCaptureKit multi-monitor,
  1280px max, JPEG 0.8, excludes own windows, cursor screen listed first,
  returns display frames + pixel dims for coordinate mapping.
- `GlobalPushToTalkShortcutMonitor.swift` — CGEvent tap (.listenOnly) for
  modifier-only hotkeys (more reliable than NSEvent global monitors).
- `AssemblyAIStreamingTranscriptionProvider.swift`, `ElevenLabsTTSClient.swift`
  — their old cloud STT/TTS (we use WhisperKit + OpenAI TTS instead).
- `MenuBarPanelManager.swift` + `CompanionPanelView.swift` — dropdown panel:
  nonactivating borderless `KeyablePanel` under the status item, click-out
  dismissal with 0.3 s grace.
- `CLAUDE.md` — their dev guidance (don't run xcodebuild from terminal:
  invalidates TCC; transient cursor fades after 1 s idle; etc.)

### glide (best nudge + companion reference)
`apps/macos/Glide/`:
- `GlideDynamicIslandManager.swift` — THE notch island: fixed-size panel
  (550×360) at `.mainMenu + 3`, inner SwiftUI animates; `GlideNotchShape`
  (animatable top/bottom radii); widths: collapsed 170 / active 440 /
  expanded 470; heights 24/34; hover-to-expand spring (0.42/0.8).
- `OverlayWindow.swift` — cursor companion with tooltip bubbles.
- `apps/server/` — Cloudflare Worker (we skip backends, but its
  `routes/chat.ts` shows Vercel AI SDK + Anthropic + Composio tools).

### openclicky (fork; only place with circle-select + agent HUD code)
Adds: circle/region drawing for element selection, Codex CLI agent mode,
gpt-realtime-2 voice with tool calling, computer-use CGEvent dispatch,
agent HUD cards, chat workspace. Use as the reference for Phase 2's circle
gesture and Phase 5.

### heyclicky-clone (dabit3)
Minimal clean version: `clicky/UI/PillController.swift` (simple pill panel),
`Core/ScreenContextProvider.swift`, `Core/LLMClient.swift` (OpenAI vision),
markdown skills store. Good "simplest possible" sanity reference.

## 4. Intel from inside /Applications/HeyClicky.app (readable, revisit anytime)

- `Contents/Resources/ClickyModelInstructions.md` — their COMPLETE agent
  behavior contract (~95 lines): routing rules (structured tools → Composio
  MCP → Computer Use last), approval gate ("user's instruction IS the
  approval"; confirm only for delete/overwrite/send-email/spend-money),
  no-permission-prompt-storm rules for personal folders, draft-first Gmail.
  Blueprint for our Phase 5 agent rules.
- `Contents/Resources/AGENTS.md` — documents THEIR source structure
  class-by-class (FloatingSessionButtonManager, ScreenshotManager with
  window-exclusion-from-capture, ContentView focus tracking).
- `Contents/Resources/ClickyBundledSkills/` — agent skills, mostly vendored
  MIT from github.com/nousresearch/hermes-agent (see ATTRIBUTION.md):
  cua-driver (computer-use loop: snapshot AX state → act by element_index →
  verify via re-snapshot, background-first), clicky-repo-operator,
  clicky-research-report, frontend-design, pdf/doc/spreadsheet, etc.
- `Contents/Resources/CodexRuntime/` — the bundled agent binary (bin/vendor).
- Voice preview MP3s (cedar, marin, …) = OpenAI Realtime proof.
- Sound design: paired open/close/send/receive UI sounds (agent-launch.m4a,
  clicky-text-open/close/send/receive.wav) — idea worth imitating with our
  own sounds.
- Binary strings: routes /v2/chat, /v2/dictation/*; Deepgram transcriber
  class; internal path shows private repo continues `leanring-buddy`
  lineage → farzaa-clicky repo is the true ancestor.

## 5. Their weaknesses = our advantages

1. Privacy: their dictation audio + screenshots go through their servers.
   Hush: dictation fully local; screenshots only ever to the user's own
   API key, nothing stored.
2. Cost: their agent calls ≈ 25¢ each, quotas (Pro 150/mo). Ours: raw API
   cost, no quota, no markup.
3. No continuous awareness (screenshot on keypress only) — same for us,
   fine.
4. Voice-in-office problem — Hush keeps strong silent modes (dictation,
   text chat).
5. No public API/MCP — if we ever want, Claude Code gives us this free.

## 6. Phase 2–5 implementation pointers

- **Phase 2 (circle-to-ask + spoken replies)**: overlay window from
  farzaa-clicky + circle gesture from openclicky (mouse-path capture on the
  overlay while hotkey held; crop screenshot to circled region's bounding
  box, send region + full screen to Claude). Reply → OpenAI TTS
  (`tts-1`/`gpt-4o-mini-tts`) → AVAudioPlayer. Reuse `ClaudeAPI.swift`
  streaming pattern; keep farza's spoken-style system prompt approach and
  the `[POINT:...]` protocol (needed in Phase 4 anyway).
  Teardown reference: isaacflath.com/writing/how-clicky-works.
- **Phase 3 (chat dropdown)**: `MenuBarPanelManager` + `CompanionPanelView`
  pattern; "ask Hush…" input bar styled like the screenshots (rounded dark
  field, attach + send, speaker toggle for TTS playback); double-tap ctrl
  detection via the CGEvent tap monitor. ALSO: hover-over-nudge expands the
  notch into a settings/tabs panel like the real Clicky — glide's
  `GlideDynamicIslandManager` has the full hover-to-expand implementation
  (hover target 220×32, spring 0.42/0.8, expanded 470×310).
  LESSON from Phase 1: any SwiftUI content in a panel overlapping the notch
  needs safe-area disabled (`NSHostingView.safeAreaRegions = []`) or macOS
  pushes it 32 pt below the notch on the built-in display.
- **Phase 4 (cursor triangle)**: port BlueCursorView mechanics (60fps
  follow, Bezier arc, POINT parsing + 3 coordinate transforms are the
  hard-won part — copy the math).
- **Phase 5 (agents)**: bundle/spawn **Claude Code CLI** as subprocess
  (their Codex move, our stack). Adapt ClickyModelInstructions.md rules.
  User already runs Claude Code, so start by shelling out to the installed
  `claude` binary before bundling anything.
- **Realtime voice (optional later)**: OpenAI Realtime API (WebRTC/WS),
  voice "cedar" for the authentic feel; it can also route tool calls.

## 7. Visual ground truth (screenshots)

Originals from Lord Berries (phone + screen): idle pill comparison
(Clicky wider/translucent at very top vs Hush's smaller lower pill),
notch expansion "Listening" (teal dots right of notch, label left),
"Thinking" (purple), chat input bar, settings dropdown pages, cursor
triangle. Converted copies were in /tmp (volatile); originals in
`~/Downloads/IMG_0578–0583.heic` and the user can always re-shoot —
the real app is installed for side-by-side comparison.

## 8. Sources

- github.com/farzaa/clicky (MIT) · isaacflath.com/writing/how-clicky-works
- TBPN interview 2026-06-10 (tbpndigest.com) — Realtime router, Codex
  bundling, 25¢ agent economics, proactive-nudge plans
- openai.com/index/introducing-gpt-realtime (cedar/marin voices)
- ycombinator.com/companies/heyclicky · producthunt.com/products/clicky-2
- Web research + repo analysis agent reports, this session (2026-07-31)
