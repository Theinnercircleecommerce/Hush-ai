# Phase 6 — Meeting Recap

**Date:** 2026-08-12
**Status:** Approved design, not yet planned
**Replaces:** Fathom (third-party cloud note-taker)

## Goal

Record a Google Meet call the owner is *in*, transcribe it locally, attribute
each line to the person who said it, and produce a recap plus action items per
person. Audio never leaves the Mac. One Claude call per meeting, ~$0.05.

Non-goal: recording meetings the owner does not attend. That needs a bot in the
call and a server to host it; both were considered and rejected (see
Alternatives).

## User flow

1. Owner joins a Meet call and turns on Meet's live captions.
2. Owner opens the notch menu and clicks the yellow **Record Call** pill.
3. Pill turns red and shows an elapsed timer. The panel can be closed; recording
   continues.
4. Owner clicks the pill again to stop.
5. Hush transcribes in the background. The pill shows "Processing…".
6. Result lands in **LIBRARY → Meetings**. Opening a row shows: recap, action
   items grouped by person, and the full attributed transcript, with a copy
   button per section.

There is no hotkey. The nudge button is the only entry point.

## Architecture

Five new units. Each is independently testable and depends only on what is
listed.

### 1. `SystemAudioCaptureService`

**Does:** Records the Mac's audio output (everyone else on the call) to a file,
and hands out periodic video frames of the screen.

**How:** One `SCStream` with two outputs.

- `SCStreamConfiguration.capturesAudio = true`
- `excludesCurrentProcessAudio = true` — Hush's own TTS must not be recorded
- `sampleRate = 48000`, `channelCount = 2`
- `minimumFrameInterval = CMTime(value: 2, timescale: 1)` — one frame every 2s,
  which is all the OCR needs
- Audio sample buffers are downmixed to **16 kHz mono** before writing. A raw
  48 kHz stereo float CAF is ~1.3 GB/hour; 16 kHz mono is ~115 MB/hour, and
  16 kHz mono is exactly what WhisperKit wants.

**Depends on:** ScreenCaptureKit, AVFoundation. Screen Recording permission is
already granted for circle-to-ask.

**Does NOT touch** `AudioCaptureService`. The mic path keeps its
fresh-`AVAudioEngine`-per-press behaviour untouched — engine reuse has silently
broken recording before (commit 896e82f), so it is off limits.

### 2. `SpeakerNameReader`

**Does:** Turns a stream of screen frames into a timeline of
`(timestamp, speakerName)`.

**How:** For each frame, run `VNRecognizeTextRequest` (Vision framework,
on-device, free, no dependency) over the bottom-centre region of the frame where
Meet renders captions. Meet formats captions as `Name: spoken text`. Extract the
substring before the first colon. Emit `SpeakerTick(t: TimeInterval, name:
String)` when the name changes.

**Cost:** $0. No image is ever sent to an API.

**Fallback (captions off, or Meet redesigns):** OCR the participant tiles once at
the start of the recording to collect a name list. Emit no ticks. The recap
prompt then receives the name list and infers ownership from context ("Sarah,
can you send the deck?"). Degraded but useful; costs nothing extra.

**Frames are never persisted and never sent anywhere.** OCR runs in memory and
the frame is dropped.

### 3. `MeetingSession`

**Does:** Orchestrates one recording, start to saved row. The equivalent of
`TalkSession` for meetings.

**Sequence:**

1. Start `AudioCaptureService` (mic → `me.caf`) and `SystemAudioCaptureService`
   (system audio → `them.caf`, frames → `SpeakerNameReader`).
2. Both files share a single `t=0`, stamped when the second stream reports its
   first buffer, so the two transcripts align.
3. On stop: close both files, stop the stream.
4. Transcribe each file with `LocalTranscriptionService` using
   `large-v3-turbo`, requesting **segment timestamps**. Files longer than
   10 minutes are chunked into 10-minute pieces with the offset added back to
   each segment's timestamps.
5. Merge (see `TranscriptMerger`).
6. Send the merged transcript to `ClaudeVisionClient` (text-only path, no
   images) for the recap.
7. Write the `meeting` row. Delete `me.caf` and `them.caf`.

**Guards:**
- Re-entry guard — a second click while recording means *stop*, not *start*.
- Meetings under 30 seconds are discarded without an API call.
- If the Claude call fails, the row is still saved with the transcript and a
  `recapFailed` flag. The Meetings view offers a Retry button; retry costs one
  more call, no re-transcription.

### 4. `TranscriptMerger`

**Does:** Pure function. Takes mic segments, system segments, and the speaker
timeline; returns one chronological array of
`AttributedLine(t: TimeInterval, speaker: String, text: String)`.

**Rules:**
- Every mic segment is attributed to `"Me"`, unconditionally.
- Every system segment is attributed to the speaker tick active at the segment's
  **midpoint** (midpoint, not start — captions lag speech by ~1s, so start-time
  matching mis-assigns the first words of each turn).
- If no tick covers that midpoint, attribute to `"Someone else"`.
- Output sorted by `t`.

This is the one piece with real logic and no I/O, so it carries the unit tests.

### 5. `MeetingStore` + `MeetingsView`

**Store:** GRDB migration `v4` on the existing
`~/Library/Application Support/com.hush.app/history.sqlite`. Follows the
`HistoryStore` migrator pattern exactly (`HistoryStore.swift:24-66`).

```
meeting
  id            TEXT     PRIMARY KEY
  startedAt     DATETIME NOT NULL
  duration      DOUBLE   NOT NULL
  title         TEXT     NOT NULL     -- Claude-generated, or "Meeting <date>"
  participants  TEXT     NOT NULL     -- JSON array of names
  transcript    TEXT     NOT NULL     -- JSON array of AttributedLine
  recap         TEXT                  -- markdown, null if recapFailed
  actionItems   TEXT                  -- JSON array of {owner, task}
  recapFailed   BOOLEAN  NOT NULL
INDEX meeting_on_startedAt
```

**View:** New `NudgePage` case `.meetings`, added to the enum at
`NudgeMenuView.swift:14` (title `"Meetings"`, default `subpageSize` panel). One
`navRow(icon: "person.2", title: "Meetings", page: .meetings)` added to the
LIBRARY section at `NudgeMenuView.swift:1128`, and one `pageLayer` at
`NudgeMenuView.swift:73`. List → detail, matching the History page's structure.

### Button change

`NudgeMenuView.swift:319` is currently `Button(action: {})` — a dead placeholder
labelled "Undock Cursor". It becomes the Record Call control:

| State | Label | Fill | Icon |
|---|---|---|---|
| idle | `Record Call` | yellow `(0.98, 0.80, 0.10)` | `play.fill` |
| recording | `12:04` | red | `stop.fill` |
| processing | `Processing…` | grey, disabled | spinner |

Colour and geometry otherwise unchanged, so the notch layout does not move.

## Cost

Per one-hour meeting, using the rates in `Sources/Core/Pricing.swift`
($3.00/M input, $15.00/M output for `claude-sonnet-4-6`):

| Item | Cost |
|---|---|
| Audio capture, OCR, WhisperKit | $0.00 — all on-device |
| One recap call (~12k in, ~1.5k out) | ~$0.06 |
| **Total** | **~$0.06** |

For contrast, the rejected "send a screenshot every 10s to Claude" approach
would be 360 images × ~2,000 tokens = ~$2.20 for the same meeting.

Recap calls are logged to the existing `usageEvent` table via `UsageStore`, so
they appear in Usage & cost like every other call.

`ClaudeVisionClient` currently hardcodes `max_tokens: 1024`
(`ClaudeVisionClient.swift:65`). The recap path needs ~2,000, so the request
builder gains a `maxTokens` parameter defaulting to the current 1024. No
behaviour change for circle-to-ask.

## Privacy

- **Audio never leaves the Mac.** Both streams are transcribed by WhisperKit
  locally and the files are deleted after transcription.
- **Screen frames never leave the Mac.** OCR is on-device; frames are not saved.
- **The transcript text does go to Anthropic** for the recap. This is the same
  boundary circle-to-ask already crosses, and it is far less than Fathom
  receives (Fathom gets the raw audio and stores it indefinitely).
- Transcripts are stored **unencrypted** in the local SQLite DB, same as
  dictation history. Anyone with the owner's unlocked Mac can read them.
- Nothing meeting-related is written to the `$TMPDIR` diagnostic logs. Per the
  existing rule: lengths and structured codes only, never content.

A future local-only recap via the existing `OllamaCleanupService` is possible
but **out of scope** for this phase.

## Failure modes

| Situation | Behaviour |
|---|---|
| Screen Recording permission revoked | Pill shows an error; mic-only recording is not attempted (a one-sided transcript is worse than none) |
| Captions off / no Meet window | Falls back to the participant name list; if that also fails, everyone but the owner is `"Someone else"` |
| Meeting under 30s | Discarded silently, no API call |
| Claude call fails | Row saved with transcript, `recapFailed = true`, Retry button in the detail view |
| Disk fills mid-recording | Stop, keep what was written, transcribe it |
| Mac sleeps mid-call | Recording ends; whatever was captured is processed |
| Second click while recording | Stops. Never starts a second session. |

## Testing

**Unit (XCTest):**
- `TranscriptMerger` — midpoint attribution, tick gaps, empty timeline,
  overlapping mic and system segments, ordering.
- `SpeakerNameReader` caption parsing — `Name: text`, names containing colons,
  no colon, empty OCR result.
- Chunk-offset arithmetic for meetings over 10 minutes.

**Manual QA (owner):**
- Real 3-person Meet call, captions on → correct names on the transcript.
- Same call, captions off → falls back without crashing.
- Close the notch panel mid-recording → recording continues.
- Check Usage & cost shows the recap call.
- Confirm `me.caf` and `them.caf` are gone after processing.

**Not automatable:** ScreenCaptureKit audio capture and Vision OCR against live
Meet both need a real call. These are owner-QA only.

## Alternatives considered

**Bot joins the call (Fathom's model).** Rejected. Requires headless Chromium
(~300MB), a Google account, pasting the meeting link, and it appears in the
participant list where IT policies often block it. Its only advantage —
recording calls the owner does not attend — was explicitly not needed, and
delivering it would require a cloud server, which reintroduces the exact privacy
problem this feature exists to remove.

**Screenshots to Claude for speaker names.** Rejected on cost: ~$2.20/hour
versus ~$0.06 with on-device OCR, for the same information.

**Voice diarization to separate speakers.** Rejected. Yields "Speaker 1 /
Speaker 2", not names, and adds a large new dependency. OCR gets real names for
free.

**A separate note-taker app.** Rejected. Would duplicate Hush's audio capture,
WhisperKit integration, Keychain handling, signing, notarization, Sparkle
updates, and menu-bar shell. Roughly 70% of this feature already exists inside
Hush.

## Estimated work

~1,200 lines of new Swift across five files, plus three small edits to
`NudgeMenuView.swift` and one GRDB migration.

Claude's execution time: roughly 3–4 hours across several sessions.
Owner's testing time: one real 3-person call per QA round, ~15 minutes each,
expect 2–3 rounds.
