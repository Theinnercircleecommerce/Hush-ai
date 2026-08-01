# Dashboard Into Notch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the dashboard window entirely — the notch panel becomes Hush's only UI (like HeyClicky). History, Dictionary, Snippets and a mini Insights view move into the panel as drill-in sub-pages; Scratchpad and the Style/Transforms placeholders are retired.

**Architecture:** `NudgeMenuView` gets page-based navigation (`enum NudgePage`) with a back-arrow header, replacing the two-tab setup. Sub-pages are compact dark variants reusing the SAME stores the dashboard views use today (`HistoryStore`, and whatever backs Dictionary/Snippets — read those views first). The dashboard window, its sidebar views, and all "OpenDashboard" plumbing are deleted. Onboarding window stays.

**Approved by user 2026-08-01:** notch is the only settings/UI surface; Clicky has no dashboard either.

## ⚠️ DO-NOT-REGRESS

- Do NOT touch `Sources/UI/NudgeView.swift`, `Sources/UI/NudgeShape.swift`,
  or display-panel setup in `Sources/UI/NotchNudgeController.swift`.
- Keep ALL menu-panel behavior shipped through the
  `2026-08-01-notch-menu-seamless.md` plan: persistent pre-warmed panel
  (created once in `attach`, never per-open), poll-based hover open,
  mouse-out auto-close, grow-out-of-notch animation, flush top,
  both-views-mounted opacity switching, reset-on-open notification.
  Extend that pattern — do not replace it.
- All sub-pages must stay MOUNTED (opacity switching) like the current
  Home/Settings pair — no first-open jank. Pre-warm still happens in
  `makePanel` via `layoutSubtreeIfNeeded()`.
- USER RULE: never delete files without asking first. Tasks 4–5 have
  explicit ask-gates. This includes Scratchpad — its removal kills a
  feature; get the OK.
- Build: `swift build`; relaunch: `pkill -x Hush; ./build.sh && open Hush.app`.
  NEVER `xcodebuild`. Manual verification with the user. Geometry check:
  `tail -2 "$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log"`.

---

### Task 1: Page navigation inside the panel

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`
- Modify: `Sources/UI/NudgeMenuController.swift` (only `NudgeMenuLayout`)

**Interfaces:**
- Produces: `enum NudgePage: Equatable { case home, settings, history, dictionary, snippets, insights }`
- Produces: header API `panelHeader(title: String, showBack: Bool)`; pages
  besides Home show it with a chevron-left back button → `page = .home`.
- `NudgeMenuLayout` gains `static let subpageSize = CGSize(width: 510, height: 560)`
  (settingsSize stays for Settings; Home stays homeSize). `resize(to:)`
  is already generic — no controller logic changes.

- [ ] **Step 1:** Replace `NudgeMenuTab` with `NudgePage`. The mounted
  ZStack grows to all six pages, each `.opacity(page == .x ? 1 : 0)` +
  `.allowsHitTesting(page == .x)`, animated on `page`. Switching pages
  calls `NudgeMenuController.shared.resize(to:)` with the right size
  (home → homeSize, settings → settingsSize, others → subpageSize).
  The "NudgeMenuWillOpen" reset sets `page = .home`.
- [ ] **Step 2:** Home view: below the stats/shortcuts block, add three
  navigation rows in the settings-row card style — "History", "Dictionary",
  "Snippets" with chevrons → `page = .history` etc. Make the "words today"
  stat card tappable → `page = .insights`. REMOVE the "Open Dashboard"
  button.
- [ ] **Step 3:** Compile (`swift build`), pages can be empty
  placeholders EXCEPT wired navigation must work. Commit:
  `git commit -m "feat: page navigation in notch panel, dashboard rows on Home"`.

---

### Task 2: History + Insights sub-pages

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`
- Read first: `Sources/Core/HistoryStore.swift`,
  `Sources/UI/HomeDashboardView.swift`, `Sources/UI/InsightsView.swift`
  (mirror their exact store calls; do not invent APIs).

- [ ] **Step 1: History page** — ScrollView list of recent transcriptions
  grouped by day (today / yesterday / date), each row: cleaned text
  (2-line limit, 12pt), time + word count caption, right-aligned copy
  button (`NSPasteboard` general, `setString`) and a small ✕ delete button
  calling the store's existing delete API. "Clear all" row at the bottom
  (red, with a confirmation alert). Limit initial load to the store's
  existing query APIs — no schema changes.
- [ ] **Step 2: Insights page** — compact: 4 stat cards (total words, avg
  WPM, streak, most-active hour) + a 14-day bar chart drawn with plain
  SwiftUI `Capsule`s (no new dependencies) — data via the same calls
  `InsightsView.swift` uses.
- [ ] **Step 3:** Build, relaunch, hand-test with the user (dictate, open
  History, copy a row, delete a row). Commit:
  `git commit -m "feat: history and insights sub-pages in notch panel"`.

---

### Task 3: Dictionary + Snippets sub-pages

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`
- Read first: `Sources/UI/DictionaryView.swift`, `Sources/UI/SnippetsView.swift`
  (reuse their backing store/persistence exactly — only the UI shell changes).

- [ ] **Step 1: Dictionary page** — add-word field (TextField + plus
  button; the panel is key-capable so typing works), scrollable chip/row
  list of words, ✕ per row. Same persistence as `DictionaryView`.
- [ ] **Step 2: Snippets page** — two-field add row (trigger →
  replacement), list of existing pairs, ✕ per row. Same persistence as
  `SnippetsView`.
- [ ] **Step 3:** Build, relaunch, hand-test (add a dictionary word,
  dictate it, confirm the hint works; add a snippet, dictate its trigger).
  Commit: `git commit -m "feat: dictionary and snippets sub-pages in notch panel"`.

---

### Task 4: Remove the dashboard window

**Files (read `Sources/HushApp.swift` and `Sources/AppDelegate.swift` fully first):**
- Modify: `Sources/HushApp.swift` — remove the dashboard `Window`/
  `WindowGroup` scene, the `OpenDashboard` handling, the
  `selectedSidebarItem` onboarding deep-link; keep the onboarding scene
  and menu-bar scene.
- Modify: `Sources/AppDelegate.swift` — remove `OpenDashboard`
  notification posts/menu commands (Cmd+Shift+D "Open Dashboard", any
  Settings menu item → the panel has no window to open; keep Check for
  Updates and Quit).
- `grep -rn "OpenDashboard\|MainDashboardView\|selectedSidebarItem" Sources/`
  must end up empty outside deleted files.

- [ ] **Step 1: ASK THE USER** — permission to delete these files
  (recoverable via git): `Sources/UI/MainDashboardView.swift`,
  `Sources/UI/HomeDashboardView.swift`, `Sources/UI/InsightsView.swift`,
  `Sources/UI/DictionaryView.swift`, `Sources/UI/SnippetsView.swift`,
  `Sources/UI/ScratchpadView.swift`. Confirm Scratchpad feature removal
  explicitly (its `scratchpadText` setting stays in UserDefaults,
  harmless). Do not proceed without a yes.
- [ ] **Step 2:** Strip the scenes/menu plumbing per above; `git rm` the
  six files; remove now-orphaned references (`swift build` errors are the
  checklist).
- [ ] **Step 3:** Build, relaunch. Verify: no dashboard opens from
  anywhere; menu bar icon still shows its menu; onboarding still opens on
  a fresh-defaults run
  (`defaults delete com.hush.app hasCompletedOnboarding` then relaunch —
  ASK the user before touching his defaults, or just have him confirm
  onboarding visually another way).
- [ ] **Step 4:** Commit:
  `git commit -m "refactor: dashboard removed — notch panel is Hush's only UI"`.

---

### Task 5: QA with the user

- [ ] Full sweep: first-hover smoothness (regression from persistent-panel
  work), all six pages navigate and function, back buttons, reopen lands
  on Home, dictation auto-close, click-outside, external pill behavior
  unchanged, geometry log clean, menu-bar icon menu intact, Sparkle
  update check reachable from Settings page.
- [ ] Fix nits, rebuild, re-check, final commit:
  `git commit -m "polish: notch-only UI QA fixes"`.
