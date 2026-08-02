# Notch Menu Seamless First-Open Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The notch menu opens butter-smooth from the very first hover (no first-open stutter, no first-gear freeze) and sits flush with the top edge on notchless external monitors (no gap).

**Architecture:** Stop creating the panel per open. `NudgeMenuController` builds ONE `KeyableMenuPanel` + `NSHostingView` at `attach(...)`, pre-lays it out invisibly, and keeps it alive forever; `open`/`close` only reposition, order-front and animate. `NudgeMenuView` keeps BOTH tabs (Home + Settings) permanently mounted and flips opacity — the same stuck-proof pattern `NudgeView` already uses for its states.

**Fixes user-reported issues (2026-08-01 evening):** first-open glitchy, gear first-press freeze, top gap on external monitor.

## ⚠️ DO-NOT-REGRESS

- Do NOT touch `Sources/UI/NudgeView.swift`, `Sources/UI/NudgeShape.swift`,
  or the display-panel setup in `Sources/UI/NotchNudgeController.swift`.
- Keep ALL current behavior: poll-based hover open (works over physical
  notch), ~0.4s mouse-out auto-close, click-outside close, dictation
  auto-close, grow-out-of-notch frame animation, `NudgeNotchShape`
  flush-top background.
- Build: `swift build`; relaunch: `pkill -x Hush; ./build.sh && open Hush.app`.
  NEVER `xcodebuild`. Manual verification with the user.
- Geometry check after build:
  `tail -2 "$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log"` — panel
  top == screenMaxY, hostingSafeArea zeros.

---

### Task 1: Persistent pre-warmed panel + flush external top

**Files:**
- Modify: `Sources/UI/NudgeMenuController.swift`

**Interfaces:** `attach(appState:)`, `open(on:)`, `close()`, `resize(to:)`
keep their signatures. New private: `func makePanel(appState: AppState)`.

- [x] **Step 1: Build the panel once in `attach`**

Add a `makePanel` and call it from `attach` (panel created before first
hover, never recreated):

```swift
    func attach(appState: AppState) {
        self.appState = appState
        stateCancellable = appState.$hudState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state != .idle { self?.close() }
            }
        makePanel(appState: appState)
        startHoverMonitoring()
    }

    private func makePanel(appState: AppState) {
        guard menuPanel == nil else { return }
        let panel = KeyableMenuPanel()
        let hosting = NSHostingView(
            rootView: NudgeMenuView(
                appState: appState,
                onClose: { [weak self] in self?.close() }
            )
        )
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        // Pre-warm: lay out the full view tree now (both tabs are mounted
        // in NudgeMenuView after Task 2), so the first hover pays nothing.
        panel.setFrame(
            NSRect(origin: .zero, size: NudgeMenuLayout.homeSize),
            display: false
        )
        hosting.layoutSubtreeIfNeeded()

        menuPanel = panel
    }
```

- [x] **Step 2: `open` repositions instead of creating**

In `open(on:)`: delete the panel/hosting creation lines (`let panel =
KeyableMenuPanel()` through `panel.contentView = hosting` and the later
`menuPanel = panel`). Use the persistent panel instead, and post a reset
notification so the view opens on Home:

```swift
    func open(on screen: NSScreen) {
        guard !isOpen else { return }
        guard let appState = appState, let panel = menuPanel else { return }
        if appState.hudState != .idle { return }
        isOpen = true
        NotificationCenter.default.post(
            name: Notification.Name("NudgeMenuWillOpen"), object: nil)
        // ... existing startFrame/endFrame math and grow animation,
        // BUT with topY changed per Step 3 and no panel creation ...
    }
```

- [x] **Step 3: Flush top on notchless displays**

Everywhere `topY` is computed (in `open` and `resize`), replace

```swift
        let topY = screen.frame.maxY - (metrics.hasNotch ? 0 : 4)
```

with

```swift
        let topY = screen.frame.maxY
```

(The `metrics` local stays — it is still used for the shelf start-frame.)

- [x] **Step 4: `close` hides instead of destroying**

In `close()`, the animation completion handler currently calls
`panel.close()` and `menuPanel = nil`. Change to keep the panel alive:

```swift
        }, completionHandler: {
            panel.orderOut(nil)
        })
        // menuPanel stays set — do NOT nil it.
```

Also verify nothing else nils `menuPanel` (`grep -n "menuPanel = nil" Sources/UI/NudgeMenuController.swift` → only inside removed code).

- [x] **Step 5: Compile + commit**

`swift build 2>&1 | tail -3` → `Build complete!`

```bash
git add Sources/UI/NudgeMenuController.swift
git commit -m "perf: persistent pre-warmed menu panel; flush top on external"
```

---

### Task 2: Both tabs permanently mounted in NudgeMenuView

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`

- [x] **Step 1: Replace the tab `switch` with an opacity flip**

In `body`, the current tab area is a `switch tab { case .home: homeView; case .settings: settingsView }`. Replace with both mounted (settings pre-built → first gear press is instant):

```swift
            ZStack(alignment: .top) {
                homeView
                    .opacity(tab == .home ? 1 : 0)
                    .allowsHitTesting(tab == .home)
                settingsView
                    .opacity(tab == .settings ? 1 : 0)
                    .allowsHitTesting(tab == .settings)
            }
            .animation(.easeOut(duration: 0.18), value: tab)
```

- [x] **Step 2: Reset to Home whenever the panel reopens**

Add to the outermost view in `body`:

```swift
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("NudgeMenuWillOpen"))) { _ in
            tab = .home
        }
```

- [x] **Step 3: Build, relaunch, verify with the user**

`pkill -x Hush; ./build.sh && open Hush.app`, then have the user check
IMMEDIATELY after launch (first interaction is the whole point):
1. Very first hover → grows smoothly out of the notch, no stutter.
2. Very first gear press → settings appear instantly, smooth height change.
3. External monitor: panel top edge flush with screen top, no gap.
4. Reopen → starts on Home again.
5. Regression sweep: hover-center open, mouse-out close, click-outside
   close, dictation auto-close, mic picker still works, geometry log clean.

- [x] **Step 4: Commit**

```bash
git add Sources/UI/NudgeMenuView.swift
git commit -m "perf: both menu tabs stay mounted — instant first gear press"
```
