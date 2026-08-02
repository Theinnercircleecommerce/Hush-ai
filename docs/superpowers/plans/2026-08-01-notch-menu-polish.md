# Notch Menu Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the notch menu panel behave like HeyClicky's: it grows out of the notch (flush top, square corners), opens when hovering anywhere on the notch (including the physical notch), and closes on its own when the mouse leaves.

**Architecture:** Replace the window-event hover catcher with a 10 Hz mouse-location poll in `NudgeMenuController` (one mechanism decides open AND close). Animate the panel's frame from notch-shelf size to full size. Swap the panel background to the existing `NudgeNotchShape` so the top edge merges with the notch.

**Tech Stack:** Swift 5.9 SwiftPM, AppKit + SwiftUI. No new dependencies.

**Fixes user-reported issues (2026-08-01):** popup-look instead of notch extension; stays open until click; hovering the physical notch does nothing.

## ⚠️ DO-NOT-REGRESS

- Do NOT touch `Sources/UI/NudgeView.swift` or `Sources/UI/NudgeShape.swift`
  logic, and do not change the display panel setup in
  `Sources/UI/NotchNudgeController.swift`. (You will only USE
  `NudgeNotchShape` from NudgeMenuView.)
- Phase-1 invariants hold (safe-area disabled twice; measured nudge sizes).
  After building, check `tail -2 "$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log"`:
  panel top == screenMaxY, hostingSafeArea all zeros.
- Build: `swift build`; relaunch: `pkill -x Hush; ./build.sh && open Hush.app`.
  NEVER `xcodebuild`. No test target — verification is manual with the user.

---

### Task 1: Poll-based hover open/close (replaces the catcher windows)

**Files:**
- Modify: `Sources/UI/NudgeMenuController.swift`

**Interfaces:**
- `NudgeMenuController.attach(appState:)` keeps its signature (called from
  `NotchNudgeController.rebuildPanels`). `rebuildCatchers()` is deleted —
  remove any external calls to it (`grep -rn "rebuildCatchers" Sources/`).
- Classes `HoverCatcherPanel` and `HoverTrackerView` are deleted entirely.

- [x] **Step 1: Delete the catcher machinery**

In `Sources/UI/NudgeMenuController.swift` remove: the `catchers` property,
`rebuildCatchers()`, class `HoverCatcherPanel`, class `HoverTrackerView`.

- [x] **Step 2: Add the poll**

Replace `attach(appState:)` and add the timer logic:

```swift
    private var hoverTimer: Timer?
    private var outsideTicks = 0

    func attach(appState: AppState) {
        self.appState = appState
        // Auto-close the panel the moment dictation starts.
        stateCancellable = appState.$hudState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state != .idle { self?.close() }
            }
        startHoverMonitoring()
    }

    private func startHoverMonitoring() {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.hoverTick()
        }
        // .common so the poll keeps running while menus/scrolling are active.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    /// The strip that counts as "hovering the notch": full notch width +
    /// shelf wings, plus a few points below the notch line so the target
    /// is reachable even though macOS nudges the cursor out of the notch.
    private func hoverZone(for screen: NSScreen) -> NSRect {
        let metrics = NotchMetrics.metrics(for: screen)
        let width: CGFloat = metrics.hasNotch ? metrics.notchWidth + 72 : 260
        let height: CGFloat = metrics.hasNotch ? metrics.notchHeight + 6 : 20
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func hoverTick() {
        guard let appState = appState else { return }
        let mouse = NSEvent.mouseLocation

        if !isOpen {
            guard appState.hudState == .idle else { return }
            for screen in NSScreen.screens where hoverZone(for: screen).contains(mouse) {
                open(on: screen)
                return
            }
        } else if let panel = menuPanel {
            let nearPanel = panel.frame.insetBy(dx: -8, dy: -8).contains(mouse)
            let inZone = NSScreen.screens.contains { hoverZone(for: $0).contains(mouse) }
            if nearPanel || inZone {
                outsideTicks = 0
            } else {
                outsideTicks += 1
                if outsideTicks >= 4 {   // ~0.4s away → close
                    outsideTicks = 0
                    close()
                }
            }
        }
    }
```

Keep the click-outside monitor as a backup close path (unchanged).

- [x] **Step 3: Compile**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
(`grep -rn "rebuildCatchers\|HoverCatcherPanel" Sources/` must return nothing.)

- [x] **Step 4: Commit**

```bash
git add Sources/UI/NudgeMenuController.swift
git commit -m "fix: poll-based notch hover — opens over physical notch, auto-closes on mouse-out"
```

---

### Task 2: Grow-out-of-the-notch animation + flush top shape

**Files:**
- Modify: `Sources/UI/NudgeMenuController.swift` (`open`, `close`)
- Modify: `Sources/UI/NudgeMenuView.swift:30-33` (background shape)

- [x] **Step 1: Animate the frame instead of fading**

In `open(on:)`, replace the setFrame + alpha animation block (everything
from `let metrics = ...` through the `NSAnimationContext` group) with:

```swift
        let metrics = NotchMetrics.metrics(for: screen)
        let size = NudgeMenuLayout.homeSize
        let topY = screen.frame.maxY - (metrics.hasNotch ? 0 : 4)

        // Start collapsed at the notch-shelf footprint, spring out to full.
        let shelfWidth: CGFloat = metrics.hasNotch ? metrics.notchWidth + 72 : 260
        let shelfHeight: CGFloat = metrics.hasNotch ? metrics.notchHeight + 1 : 16
        let startFrame = NSRect(
            x: screen.frame.midX - shelfWidth / 2,
            y: topY - shelfHeight,
            width: shelfWidth, height: shelfHeight
        )
        let endFrame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: topY - size.height,
            width: size.width, height: size.height
        )
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 1
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(endFrame, display: true)
        }
```

In `close()`, replace the alpha fade with the reverse: animate
`setFrame` back to the same `startFrame` math (recompute from
`panel.screen ?? NSScreen.main`; guard-nil falls back to plain
`panel.close()`), duration 0.22, then `panel.close()` in the completion
handler.

- [x] **Step 2: Flush top shape**

In `Sources/UI/NudgeMenuView.swift` (currently lines 30–33), replace:

```swift
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.05))
        )
```

with:

```swift
        .background(
            NudgeNotchShape(topCornerRadius: 10, bottomCornerRadius: 24)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.05))
        )
```

(If the executor finds the actual fill color differs from
`0.05/0.05/0.05`, keep the existing color — only the shape changes.)
Also add matching clipping so content and the settings ScrollView respect
the shape: after the `.background(...)`, add

```swift
        .clipShape(NudgeNotchShape(topCornerRadius: 10, bottomCornerRadius: 24))
```

- [x] **Step 3: Build, relaunch, verify with the user**

`pkill -x Hush; ./build.sh && open Hush.app`, then ask the user to check:
1. Hover anywhere on the notch (including dead center) → panel GROWS out
   of the notch, square top flush with the screen edge.
2. Move the mouse away (down into the screen) → closes by itself ~0.4s
   later; moving between panel and notch does NOT close it.
3. Gear → grows taller; back to Home → shrinks.
4. Dictating closes it; hover during dictation does nothing.
5. External monitor: hover the pill zone → same behavior.
6. Nudge geometry log still clean (DO-NOT-REGRESS check).

- [x] **Step 4: Commit**

```bash
git add Sources/UI/NudgeMenuController.swift Sources/UI/NudgeMenuView.swift
git commit -m "feat: menu panel grows out of the notch with flush top edge"
```
