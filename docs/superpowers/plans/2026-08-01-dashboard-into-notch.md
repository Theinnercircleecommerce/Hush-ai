# Dashboard Into Notch + Hover Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Hovering the notch or the pill ALWAYS opens the panel — fix the intermittent dead-hover bug. (2) Remove the dashboard window entirely — the notch panel becomes Hush's only UI (like HeyClicky). History, Dictionary, Snippets and a mini Insights view move into the panel as drill-in sub-pages; Scratchpad and the Style/Transforms placeholders are retired.

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

### Task 0: Hover ALWAYS opens (fix the reopen race)

**User-reported bug:** sometimes hovering does nothing; clicking anywhere
on screen, then hovering again, makes it work. Requirement: every hover
over the notch or the pill opens the panel, every time.

**Root cause:** `close()` animates the panel shut over ~0.22s and hides it
(`panel.orderOut`) in the animation COMPLETION handler. If the user
re-hovers during that animation, `open(on:)` runs (sets `isOpen = true`,
reanimates) — and THEN the stale close completion fires and orders the
panel out anyway. Now the panel is invisible while `isOpen == true`, so
`hoverTick` never reopens. A click runs the click-outside monitor →
`close()` → `isOpen = false` → hover works again. Exactly the reported
symptom.

**Files:**
- Modify: `Sources/UI/NudgeMenuController.swift`

- [x] **Step 1: Generation-guard the close completion**

Add a counter property:

```swift
    private var closeGeneration = 0
```

In `close()`, capture the generation and guard the completion:

```swift
    func close() {
        guard isOpen, let panel = menuPanel else { return }
        isOpen = false
        removeClickOutsideMonitor()
        closeGeneration += 1
        let generation = closeGeneration
        // ... existing shrink-back animation unchanged ...
        NSAnimationContext.runAnimationGroup({ ctx in
            // existing duration/timing/setFrame lines stay as they are
        }, completionHandler: { [weak self] in
            guard let self = self,
                  self.closeGeneration == generation,
                  !self.isOpen else { return }   // a reopen happened — do NOT hide
            panel.orderOut(nil)
        })
    }
```

In `open(on:)`, first line after the guards:

```swift
        closeGeneration += 1   // invalidate any in-flight close completion
```

and make sure `open` always does `panel.alphaValue = 1` and
`panel.orderFront(nil)` before its grow animation (so a mid-close reopen
recovers no matter what state the panel was left in).

- [x] **Step 2: Belt-and-suspenders desync recovery in the poll**

In `hoverTick()`'s `!isOpen` branch, opening is already the action — no
change. Add to the TOP of `hoverTick()`:

```swift
        // Self-heal: if state says open but the panel is not visible,
        // reset so the next hover can open. (Guards against any future
        // desync of the same class.)
        if isOpen, let panel = menuPanel, !panel.isVisible {
            isOpen = false
            removeClickOutsideMonitor()
        }
```

- [x] **Step 3: Verify the exact failure choreography**

Build + relaunch. Torture test with the user: rapidly hover in → out →
in (re-entering DURING the shrink animation) 10+ times on the notch, then
10+ times on the external pill. The panel must open on EVERY re-hover.
Then the normal sweep: mouse-out closes after ~0.4s, click-outside closes,
dictation closes.

- [x] **Step 4: Commit**

```bash
git add Sources/UI/NudgeMenuController.swift
git commit -m "fix: hover always opens — close-animation race could strand the panel hidden"
```

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

- [x] **Step 1:** Replace `NudgeMenuTab` with `NudgePage`. The mounted
  ZStack grows to all six pages, each `.opacity(page == .x ? 1 : 0)` +
  `.allowsHitTesting(page == .x)`, animated on `page`. Switching pages
  calls `NudgeMenuController.shared.resize(to:)` with the right size
  (home → homeSize, settings → settingsSize, others → subpageSize).
  The "NudgeMenuWillOpen" reset sets `page = .home`.
- [x] **Step 2:** Home view: below the stats/shortcuts block, add three
  navigation rows in the settings-row card style — "History", "Dictionary",
  "Snippets" with chevrons → `page = .history` etc. Make the "words today"
  stat card tappable → `page = .insights`. REMOVE the "Open Dashboard"
  button.
- [x] **Step 3:** Compile (`swift build`), pages can be empty
  placeholders EXCEPT wired navigation must work. Commit:
  `git commit -m "feat: page navigation in notch panel, dashboard rows on Home"`.

---

### Task 2: History + Insights sub-pages

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`
- Read first: `Sources/Core/HistoryStore.swift`,
  `Sources/UI/HomeDashboardView.swift`, `Sources/UI/InsightsView.swift`
  (mirror their exact store calls; do not invent APIs).

- [x] **Step 1: History page** — ScrollView list of recent transcriptions
  grouped by day (today / yesterday / date), each row: cleaned text
  (2-line limit, 12pt), time + word count caption, right-aligned copy
  button (`NSPasteboard` general, `setString`) and a small ✕ delete button
  calling the store's existing delete API. "Clear all" row at the bottom
  (red, with a confirmation alert). Limit initial load to the store's
  existing query APIs — no schema changes.
- [x] **Step 2: Insights page** — compact: 4 stat cards (total words, avg
  WPM, streak, most-active hour) + a 14-day bar chart drawn with plain
  SwiftUI `Capsule`s (no new dependencies) — data via the same calls
  `InsightsView.swift` uses.
- [x] **Step 3:** Build, relaunch, hand-test with the user (dictate, open
  History, copy a row, delete a row). Commit:
  `git commit -m "feat: history and insights sub-pages in notch panel"`.

---

### Task 3: Dictionary + Snippets sub-pages

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`
- Read first: `Sources/UI/DictionaryView.swift`, `Sources/UI/SnippetsView.swift`
  (reuse their backing store/persistence exactly — only the UI shell changes).

- [x] **Step 1: Dictionary page** — add-word field (TextField + plus
  button; the panel is key-capable so typing works), scrollable chip/row
  list of words, ✕ per row. Same persistence as `DictionaryView`.
- [x] **Step 2: Snippets page** — two-field add row (trigger →
  replacement), list of existing pairs, ✕ per row. Same persistence as
  `SnippetsView`.
- [x] **Step 3:** Build, relaunch, hand-test (add a dictionary word,
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

- [x] **Step 1: ASK THE USER** — permission to delete these files
  (recoverable via git): `Sources/UI/MainDashboardView.swift`,
  `Sources/UI/HomeDashboardView.swift`, `Sources/UI/InsightsView.swift`,
  `Sources/UI/DictionaryView.swift`, `Sources/UI/SnippetsView.swift`,
  `Sources/UI/ScratchpadView.swift`. Confirm Scratchpad feature removal
  explicitly (its `scratchpadText` setting stays in UserDefaults,
  harmless). Do not proceed without a yes.
- [x] **Step 2:** Strip the scenes/menu plumbing per above; `git rm` the
  six files; remove now-orphaned references (`swift build` errors are the
  checklist).
- [x] **Step 3:** Build, relaunch. Verify: no dashboard opens from
  anywhere; menu bar icon still shows its menu; onboarding still opens on
  a fresh-defaults run
  (`defaults delete com.hush.app hasCompletedOnboarding` then relaunch —
  ASK the user before touching his defaults, or just have him confirm
  onboarding visually another way).
- [x] **Step 4:** Commit:
  `git commit -m "refactor: dashboard removed — notch panel is Hush's only UI"`.

---

### Task 5: QA with the user

- [x] Full sweep: rapid hover in/out torture test on notch AND pill (Task
  0 regression — must open every time), first-hover smoothness, all six
  pages navigate and function, back buttons, reopen lands on Home,
  dictation auto-close, click-outside, geometry log clean, menu-bar icon
  menu intact, Sparkle update check reachable from Settings page.
- [x] Fix nits, rebuild, re-check, final commit:
  `git commit -m "polish: notch-only UI QA fixes"`.
