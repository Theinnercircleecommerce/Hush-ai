# Hush ↔ BerriesCode Connect — Design

Date: 2026-08-15
Status: awaiting Lord Berries' approval

## What this is

Let Hush's circle+talk hotkey (Option+Shift) send what's on screen into a
BerriesCode chat, so Claude Code answers with full project context, the full
answer is readable in the BerriesCode window, and Hush speaks a short version
out loud.

## The one-breath flow

1. In BerriesCode, type `@hush` in a chat → a pill appears on that chat
   (same visual style as the @fable mode pill) → that chat is now "the
   connected chat." Only one chat can be connected at a time; connecting a
   new one steals the connection. Type `@hush` again (or click the pill) to
   disconnect.
2. In any app, hold Option+Shift, circle a region, speak a question, release.
3. **If a chat is connected:** Hush sends the circled screenshot + full
   screenshots + transcript into that BerriesCode chat. Claude Code replies
   with project context. Full reply renders in the BerriesCode window as a
   normal chat turn; Hush speaks a 2–3 sentence summary aloud.
4. **If nothing is connected:** Option+Shift behaves exactly as today
   (direct Anthropic vision call, spoken answer). Zero regression.
5. Keep circling + asking; every exchange lands in the same chat.

## Rules

- **Talk-only by default.** In Berries mode the prompt instructs Claude to
  discuss/answer and NOT modify files until the user explicitly says
  "fix it" / "do it" / "go ahead."
- **Short voice, full text.** Hush never reads code blocks or walls of text.
  It speaks a condensed answer; details stay in the window.
- **One hotkey.** No new modifier combo. Routing is decided purely by
  whether a chat is connected.

## How the apps talk (all local, no new API keys)

BerriesCode already runs `RemoteServer.swift` — HTTP on `127.0.0.1:8433`,
bearer token persisted in UserDefaults (`remoteToken`,
`com.innercircle.BerriesCodeMac`). Hush reads that token straight from
BerriesCode's defaults domain (both apps are unsandboxed, same user).

New/changed endpoints in BerriesCode:

- `GET /api/hush/status` → `{connected: bool, path, session, chatTitle}` —
  which chat (if any) has the @hush pill.
- `POST /api/hush/ask` → body `{text, images: [paths]}`. BerriesCode injects
  the message into the connected chat's ChatViewModel exactly as if the user
  typed it with image attachments (reusing the existing attachment →
  "Image for reference: <path>" mechanism), so the exchange renders live in
  the window and persists in the session .jsonl. Response streams back the
  assistant text so Hush can summarize + speak.

Hush side:

- New `BerriesBridge` service: polls/queries `status` on session start;
  if connected, writes crop + screens to temp JPEGs and POSTs to
  `/api/hush/ask` instead of calling Anthropic directly.
- Voice summary: Hush runs its existing Claude vision client ONCE over the
  final reply text with a "condense to 2-3 spoken sentences" prompt, then
  TTS as today. (Cheap call, no images.)
- If BerriesCode isn't running / server off / no chat connected → fall back
  to normal Hush mode silently.

BerriesCode UI:

- `@hush` token recognized in the composer → toggles connection, shows pill
  on the chat header (reuse @fable pill component/styling).
- Pill click = disconnect.

## Error handling

- Server unreachable mid-session → Hush says "Berries Code isn't answering"
  and falls back to normal mode for that ask.
- Claude CLI busy in that chat → queue the ask; if >20s, tell the user aloud.

## Testing

- Normal mode regression: no connection → behavior identical to 1.0.31.
- Connect/disconnect: pill state matches `status` endpoint.
- End-to-end: circle a UI bug in a test project chat → reply appears in
  window + spoken summary → "fix it" follow-up actually edits the file.

## Out of scope (later, if wanted)

- Live streaming of the answer text into Hush's answer bubble.
- Multiple connected chats.
- Hush controlling the mouse/clicks.
