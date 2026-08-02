# Home Declutter + Agents Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The panel's Home view stops showing "cold Hush" (stats, history, dictionary, snippets rows all leave Home). Home becomes Clicky-like: a Home | Agents tab bar, a proper growing Shortcuts menu, gear for settings. Agents gets a placeholder tab ready for Phase 5. Dictionary and Snippets pages are removed entirely; History/Insights (and any other content rows currently on Home) move into Settings.

**Approved by user 2026-08-02.**

## ⚠️ DO-NOT-REGRESS (read the memory-derived invariants — repo code is truth)

- The menu panel WINDOW is fixed-size and never animated; all grow/shrink
  is SwiftUI springs inside `NudgeMenuView`. Do not reintroduce
  NSPanel frame animation or controller `resize(to:)` calls.
- Hover hit-testing: top edge is INCLUSIVE (`zoneContains` in
  `NudgeMenuController` — do not replace with plain `NSRect.contains`).
  Hover zones match the visible target only (notch width / 188pt pill).
- Panel is created ONCE in `attach()`; open/close reposition + order
  front/out only. Poll-based hover; close-generation guard; all pages stay
  MOUNTED (opacity flip) — new pages too, pre-warmed via
  `layoutSubtreeIfNeeded` in `makePanel`.
- Do NOT touch `NudgeView.swift`, `NudgeShape.swift`, or the display-panel
  setup in `NotchNudgeController.swift`.
- USER RULE: ask before deleting files (gate in Task 3).
- Build `swift build`; relaunch `pkill -x Hush; ./build.sh && open Hush.app`;
  NEVER `xcodebuild`. Geometry check:
  `tail -2 "$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log"`.
- Before coding: read `Sources/UI/NudgeMenuView.swift` fully — the 7-page
  structure (Home, Settings, History, Insights, Dictionary, Snippets,
  Scratchpad) was built across four executed plans and is the source of
  truth, not older plan documents.

---

### Task 1: Home redesign — tab bar + real Shortcuts menu

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`

- [ ] **Step 1: Top bar becomes Home | Agents + gear** (Clicky's layout:
  two tab labels left — house icon "Home", sparkle icon "Agents" — gear
  far right). Selected tab white, unselected gray, 13pt semibold.
- [ ] **Step 2: Home content = Shortcuts section only.** Remove from Home:
  words-today card, streak card, History/Dictionary/Snippets/Scratchpad
  rows, anything else content-like. New Home body: "⌘ Shortcuts" caption +
  a rows list built from a single data array so future phases append
  entries without layout surgery:

```swift
struct ShortcutEntry: Identifiable {
    let id = UUID()
    let name: String
    let keys: [String]        // e.g. ["fn", "⌃"] rendered as keycaps
    let subtitle: String?     // optional, e.g. "hold and speak"
    let enabled: Bool         // false → grayed "coming soon" row
}

private var shortcutEntries: [ShortcutEntry] {
    [
        ShortcutEntry(name: "Dictate", keys: hotkeyKeycaps(),
                      subtitle: "hold and speak", enabled: true),
        ShortcutEntry(name: "Hands-free", keys: hotkeyKeycaps() + ["2×"],
                      subtitle: "double-tap to toggle", enabled: true),
        ShortcutEntry(name: "Talk", keys: ["⌃", "⌥"],
                      subtitle: "coming soon", enabled: false),
        ShortcutEntry(name: "Text", keys: ["⌃", "2×"],
                      subtitle: "coming soon", enabled: false),
    ]
}
```

  `hotkeyKeycaps()` derives the current KeyboardShortcuts recorder value
  (reuse the existing `HotkeyString`/recorder plumbing already in this
  file — read it first; if splitting into per-key caps is fiddly, render
  the whole shortcut string in one keycap). Row style: name left
  (disabled rows gray + "coming soon" subtitle), keycaps right as small
  rounded dark chips — match the user's HeyClicky Home screenshot.
- [ ] **Step 3:** Build, relaunch, eyeball with the user. Commit:
  `git commit -m "feat: Home is tab bar + growing shortcuts menu, content rows gone"`.

---

### Task 2: Agents placeholder tab

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`

- [ ] **Step 1:** New mounted page `agents` (same opacity-flip pattern).
  Content: centered sparkle icon, "Agents live here soon", one gray
  sentence: "Hush agents will do tasks for you in the background — coming
  in a future update." No buttons. Height: same as Home.
- [ ] **Step 2:** Tab bar switches Home ↔ Agents (SwiftUI spring inside
  the fixed window, like existing page switches). Reopen still resets to
  Home.
- [ ] **Step 3:** Build, verify, commit:
  `git commit -m "feat: agents placeholder tab in notch panel"`.

---

### Task 3: History/Insights into Settings; Dictionary & Snippets removed

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`
- Possibly delete: dictionary/snippets page code (see gate)

- [ ] **Step 1:** Settings list gains a "LIBRARY" section (above SUPPORT):
  rows "History >" and "Insights >" navigating to the existing pages
  (unchanged); plus "Scratchpad >" if that page still exists. Back button
  from those pages returns to Settings now, not Home.
- [ ] **Step 2: ASK THE USER (gate):** removing Dictionary & Snippets
  pages makes those features unmanageable from the UI. Confirm choice:
  **(a)** delete pages AND stop applying stored dictionary hints/snippet
  replacements in the transcription pipeline (feature fully dead), or
  **(b)** delete pages only, existing stored words/snippets keep working
  silently. Recommend (b) — zero risk to the dictation pipeline. Then
  remove the pages, their `NudgePage` cases, and any entry rows; if the
  user picks (a), also strip the pipeline hooks (grep for the dictionary/
  snippet application sites in `Sources/Core/AppState.swift`).
- [ ] **Step 3:** `swift build` (compiler errors are the removal
  checklist), relaunch, verify: Home shows only shortcuts, Agents tab
  present, Settings has Library rows, no Dictionary/Snippets anywhere.
- [ ] **Step 4:** Commit:
  `git commit -m "refactor: content pages live under Settings; dictionary and snippets retired"`.

---

### Task 4: QA with the user

- [ ] Hover torture test (notch + pill, rapid in/out — must open every
  time), first-open smoothness, tab switching feel vs real Clicky,
  Settings → History/Insights navigation and back, dictation still clean
  end-to-end, geometry log clean.
- [ ] Fix nits, final commit: `git commit -m "polish: home declutter QA"`.
