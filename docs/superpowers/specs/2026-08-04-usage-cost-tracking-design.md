# Usage & cost tracking — design

Date: 2026-08-04
Status: approved (option A2 — read-only, split by provider)

## Goal

A Usage screen in the Hush menu that answers, at a glance: *how much am I
spending on this app this month, and what is eating it?*

Read-only. No budget, no spend cap, no alerts.

## What actually costs money

| Piece | Provider | Rate | Accuracy |
|---|---|---|---|
| Circle-to-ask answer | Anthropic `claude-sonnet-4-6` | $3.00/M input tok, $15.00/M output tok | **Exact** — tokens come back on the stream |
| Spoken answer | OpenAI `gpt-4o-mini-tts` | $0.60/M input chars + ~$0.015/min audio | **Estimated** (±10–15%) |
| Transcription | WhisperKit, on-device | $0 | n/a |
| Cleanup | Ollama, on-device | $0 | n/a |

Screenshots dominate: each captured screen is roughly 1,500–2,500 input tokens,
so a two-monitor question lands around $0.02–0.03. Text-only follow-ups are ~10×
cheaper because `ClaudeVisionClient` never replays images.

## Architecture

### 1. Pricing — `Sources/Core/Pricing.swift`

One file holding every rate as a named constant, plus two pure functions
(`claudeCost`, `ttsCost`). Cost is computed **at write time** and frozen into the
row, so historical totals stay correct if a provider changes prices later.

### 2. Storage — `usageEvent` table

New GRDB migration `v3` in `HistoryStore`, reusing the existing
`history.sqlite` database and its `dbQueue`.

```
usageEvent(id, timestamp, provider, model, inputTokens, outputTokens,
           costUSD, isEstimate)
```

`provider` is `"claude"` or `"tts"`. **No prompt text, no transcripts, no answer
text is stored** — counts and money only.

`UsageStore` (`Sources/Core/UsageStore.swift`) owns reads and writes, mirroring
the existing `HistoryStore` shape: an `ObservableObject` singleton that publishes
the last 30 days of rows and derives totals from them.

### 3. Recording Claude usage — exact

`ClaudeVisionClient.textDelta` currently returns `String?` and silently drops
every non-text SSE event. It becomes a `StreamEvent` enum:

- `message_start` → `message.usage.input_tokens`
- `message_delta` → `usage.output_tokens` (cumulative; last one wins)
- `content_block_delta` → text, as today

`ask` accumulates both counts and records them in a `defer` block, so a stream
that dies halfway still logs what Anthropic billed for. Prompt caching is not
used, so the `cache_*` usage fields are always zero and are ignored.

### 4. Recording TTS usage — estimated

`SpeechOutputService.drain` already knows each segment's text; it now carries
that text alongside the in-flight fetch so `playAndWait` can see it.

Once `AVAudioPlayer` is constructed we have `player.duration` — the real length
of the generated audio. Cost is:

```
characters / 1_000_000 * $0.60   +   duration / 60 * $0.015
```

Rows are flagged `isEstimate = true` and rendered with a `≈` prefix so the number
is never mistaken for exact.

### 5. UI — new `.usage` page

`NudgePage` gains a `.usage` case (subpage size). A `navRow` under **LIBRARY**
in Settings opens it, next to History and Insights.

```
This month          $4.12
                    Claude $3.80 · Voice ≈$0.32

Today               $0.31
                    Claude $0.29 · Voice ≈$0.02

142 questions · avg $0.029 each

Feb 3    $0.42    Claude $0.38 · Voice ≈$0.04
Feb 2    $0.18    Claude $0.16 · Voice ≈$0.02
...30 days
```

"This month" is the calendar month and resets on the 1st. Amounts under one cent
render with three decimals so a cheap day doesn't collapse to `$0.00`.

## Non-goals

- Budgets, caps, and alerts (explicitly deferred — option B/C).
- A per-question log (option A3).
- Tracking on-device work, which is free.
- Reconciling against the provider's own billing dashboard. These numbers are
  Hush's own accounting; small drift from Anthropic's invoice is expected, and
  the TTS half is an estimate by construction.
