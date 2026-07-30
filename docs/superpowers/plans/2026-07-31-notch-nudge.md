# Notch Nudge (HUD Rebuild) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Hush's floating HUD pill with a Clicky-style notch-anchored "nudge": translucent idle pill at the top edge, black notch expansion with "Listening" (teal dots) and "Thinking" (purple dots) states.

**Architecture:** A fixed-size transparent `NSPanel` per screen, pinned top-center above the menu bar. The panel never resizes; a SwiftUI `NudgeView` inside animates between states with springs. The existing `HUDState` enum on `AppState` keeps driving everything — no dictation logic changes.

**Tech Stack:** Swift 5.9 SwiftPM executable (no Xcode project), SwiftUI + AppKit. macOS 14+. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-31-notch-nudge-design.md`

## ⚠️ STATE AS OF 2026-07-31 EVENING — READ BEFORE DOING ANYTHING

Tasks 1–3 are DONE (commits 907f189, 588773b, 702ef29, b11a591 + later
fixes) and were then HAND-TUNED against the real HeyClicky with pixel
measurements. **The code in the repo is the source of truth, NOT the code
blocks in Tasks 1–3 below** — those blocks are the original draft and are
now partially outdated. NEVER re-apply, "restore," or regenerate
`NudgeShape.swift`, `NudgeView.swift`, or `NotchNudgeController.swift`
from this document. Only Tasks 4 and 5 remain.

Hard-won invariants — breaking any of these is a regression:

1. **Safe area must stay disabled twice**: `hosting.safeAreaRegions = []`
   in `NotchNudgeController.swift` AND `.ignoresSafeArea()` on the root
   frame in `NudgeView.swift`. Without BOTH, macOS silently pushes all
   content 32pt below the hardware notch on the built-in display (looks
   fine on external monitors — that's how the bug hides).
2. **Idle differs per screen**: notched screen → `idleNotchShelf` (black
   notch-hugging bar, `notchWidth + 72` wide, `notchHeight + 1` tall — a
   pixel-measured match of HeyClicky's 250×33pt idle bar; NO pill).
   Notchless screen → translucent `idlePill`. Do not unify these.
3. Measured device facts (M2 MacBook Air 13": notch = 179×32pt): shelf
   ≈ 251×33pt, flush with notch bottom, no lip below.
4. A temporary geometry self-check writes `NUDGE-GEO` lines to
   `/tmp/hush-nudge-geo.log` on launch (panel frame, safe-area insets,
   notch size). Use it to verify placement after ANY nudge change:
   panel top must equal screenMaxY, hostingSafeArea must be all zeros.
   Remove this block only in Task 5 after the user signs off visually.

## Global Constraints

- Build with `swift build` (SwiftPM). NEVER run `xcodebuild`. Full app bundle: `./build.sh` (produces `Hush.app` in repo root).
- There is no test target in `Package.swift`. Verification is compile checks (`swift build`) plus manual runs. Do not add a test target.
- Do not add dependencies to `Package.swift`.
- Reference code lives in `/tmp/clicky-refs/` (glide, farzaa-clicky). Read it for mechanics; never copy files from it wholesale and never copy assets from `/Applications/HeyClicky.app`.
- The user (Lord Berries) is visual QA — he compares against the real HeyClicky app on his notched MacBook. When a task says "ask user to verify," actually stop and ask.
- USER RULE: never delete files without asking him first. Task 4 has a deletion step — get his OK in-chat before executing it.
- All UI state changes on the main thread (existing code uses `DispatchQueue.main`).
- To relaunch the app for manual checks: `pkill -x Hush; ./build.sh && open Hush.app` (if macOS re-prompts for mic/accessibility after a rebuild, tell the user to re-grant).

---

### Task 1: Notch geometry + nudge shape — ✅ DONE (SKIP; repo code is newer than these blocks)

**Files:**
- Create: `Sources/UI/NudgeShape.swift`

**Interfaces:**
- Produces: `struct NotchMetrics { let hasNotch: Bool; let notchWidth: CGFloat; let notchHeight: CGFloat; static func metrics(for screen: NSScreen) -> NotchMetrics }`
- Produces: `struct NudgeNotchShape: Shape` with `var topCornerRadius: CGFloat`, `var bottomCornerRadius: CGFloat` (animatable)
- Produces: `enum NudgeLayout { static let containerWidth: CGFloat = 600; static let containerHeight: CGFloat = 70 }`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import AppKit

/// Fixed outer dimensions of the transparent nudge panel. The panel never
/// resizes; the SwiftUI content inside animates within this canvas.
enum NudgeLayout {
    static let containerWidth: CGFloat = 600
    static let containerHeight: CGFloat = 70
}

/// Physical notch measurements for a given screen.
struct NotchMetrics {
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchMetrics(hasNotch: true, notchWidth: width, notchHeight: topInset)
        }
        // Notchless display (external monitor / older Mac): the expansion
        // renders as a free-standing rounded bar of this virtual size.
        return NotchMetrics(hasNotch: false, notchWidth: 180, notchHeight: 0)
    }

    /// Height of the black expansion bar content.
    var expansionHeight: CGFloat {
        hasNotch ? notchHeight + 8 : 34
    }
}

/// Outline of the widened notch: square top edge that flares out of the
/// screen top, rounded lower corners — same silhouette as the hardware notch.
struct NudgeNotchShape: Shape {
    var topCornerRadius: CGFloat = 8
    var bottomCornerRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Start at top-left, on the screen's top edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Flare inward-downward from the top edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        // Left side down.
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        // Bottom-left rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        // Bottom-right rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        // Right side up.
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        // Flare back out to the top edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
```

- [ ] **Step 2: Compile**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/NudgeShape.swift
git commit -m "feat: notch geometry helpers and nudge shape for new HUD"
```

---

### Task 2: NudgeView (all four states) — ✅ DONE (SKIP; repo code is newer than these blocks)

**Files:**
- Create: `Sources/UI/NudgeView.swift`

**Interfaces:**
- Consumes: `NotchMetrics`, `NudgeNotchShape`, `NudgeLayout` (Task 1); `AppState.hudState: HUDState`, `AppState.audioLevel: Float` (existing, `Sources/Core/AppState.swift`); `HUDState` enum (existing, currently in `Sources/UI/HUDView.swift`).
- Produces: `struct NudgeView: View` with `init(appState: AppState, metrics: NotchMetrics)`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Clicky-style nudge: translucent idle pill at the top edge; black notch
/// expansion with a state label (left) and animated dots (right) when active.
struct NudgeView: View {
    @ObservedObject var appState: AppState
    let metrics: NotchMetrics

    private static let listeningTeal = Color(red: 0.29, green: 0.87, blue: 0.83)
    private static let thinkingPurple = Color(red: 0.72, green: 0.45, blue: 0.95)

    init(appState: AppState, metrics: NotchMetrics) {
        self.appState = appState
        self.metrics = metrics
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if case .idle = appState.hudState {
                    idlePill
                        .transition(.opacity)
                } else {
                    expansion
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: NudgeLayout.containerWidth, height: NudgeLayout.containerHeight, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: appState.hudState)
    }

    // MARK: - Idle

    private var idlePill: some View {
        Capsule()
            .fill(Color.white.opacity(0.16))
            .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
            .frame(width: 250, height: 9)
            .padding(.top, metrics.hasNotch ? metrics.notchHeight + 2 : 4)
    }

    // MARK: - Active expansion

    private var expansionWidth: CGFloat {
        metrics.notchWidth + 240
    }

    private var expansion: some View {
        ZStack {
            NudgeNotchShape(
                topCornerRadius: metrics.hasNotch ? 8 : 0,
                bottomCornerRadius: 14
            )
            .fill(Color.black)

            HStack(spacing: 0) {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                // Keep the physical notch area empty.
                Color.clear.frame(width: metrics.notchWidth)
                dots
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 24)
            }
            // Center content in the sliver below the hardware notch on
            // notched screens; vertically centered on notchless displays.
            .padding(.top, metrics.hasNotch ? metrics.notchHeight * 0.35 : 0)
        }
        .frame(width: expansionWidth, height: metrics.expansionHeight)
        .clipShape(NudgeNotchShape(
            topCornerRadius: metrics.hasNotch ? 8 : 0,
            bottomCornerRadius: 14
        ))
    }

    @ViewBuilder
    private var label: some View {
        switch appState.hudState {
        case .recording:
            Text("Listening")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        case .transcribing:
            Text("Thinking")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        case .error(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var dots: some View {
        switch appState.hudState {
        case .recording:
            NudgeBarsView(level: appState.audioLevel, color: Self.listeningTeal)
        case .transcribing:
            NudgePulseDotsView(color: Self.thinkingPurple)
        case .error:
            NudgePulseDotsView(color: Color(red: 1.0, green: 0.42, blue: 0.42))
        case .idle:
            EmptyView()
        }
    }
}

/// Five mini bars driven by live mic level (Listening state).
struct NudgeBarsView: View {
    var level: Float
    var color: Color

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: barHeight(index))
                    .animation(.spring(response: 0.15, dampingFraction: 0.6), value: level)
            }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base: CGFloat = 3
        let center: CGFloat = 2
        let attenuation = max(0, 1.0 - abs(CGFloat(index) - center) * 0.3)
        let active = max(CGFloat(level), 0.12)
        let jitter = CGFloat.random(in: 0.85...1.15)
        return min(base + active * 9 * attenuation * jitter, 12)
    }
}

/// Three softly pulsing dots (Thinking / error states).
struct NudgePulseDotsView: View {
    var color: Color
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .opacity(pulsing ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.18),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
    }
}
```

- [ ] **Step 2: Compile**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/NudgeView.swift
git commit -m "feat: NudgeView with idle pill, listening, thinking, error states"
```

---

### Task 3: NotchNudgeController + wire into app — ✅ DONE (SKIP; repo code is newer than these blocks)

**Files:**
- Create: `Sources/UI/NotchNudgeController.swift`
- Modify: `Sources/AppDelegate.swift:25` (the line `HUDWindowController.shared.show(appState: self.appState)`)

**Interfaces:**
- Consumes: `NudgeView`, `NotchMetrics`, `NudgeLayout` (Tasks 1–2); `AppState` (existing).
- Produces: `final class NotchNudgeController` with `static let shared` and `func show(appState: AppState)`.

- [ ] **Step 1: Create the controller**

```swift
import Cocoa
import SwiftUI

/// Owns one transparent, click-through panel per screen, pinned top-center
/// above the menu bar. Replaces HUDWindowController.
final class NotchNudgeController {
    static let shared = NotchNudgeController()

    private var panels: [NSPanel] = []
    private weak var appState: AppState?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuildPanels),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show(appState: AppState) {
        self.appState = appState
        rebuildPanels()
    }

    @objc private func rebuildPanels() {
        guard let appState = appState else { return }

        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()

        for screen in NSScreen.screens {
            let metrics = NotchMetrics.metrics(for: screen)
            let panel = NudgePanel(
                contentRect: NSRect(
                    x: 0, y: 0,
                    width: NudgeLayout.containerWidth,
                    height: NudgeLayout.containerHeight
                )
            )
            panel.contentView = NSHostingView(
                rootView: NudgeView(appState: appState, metrics: metrics)
            )

            let x = screen.frame.midX - NudgeLayout.containerWidth / 2
            let y = screen.frame.maxY - NudgeLayout.containerHeight
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.orderFront(nil)
            panels.append(panel)
        }
    }
}

private final class NudgePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        ignoresMouseEvents = true
        // Above the menu bar so the expansion visually merges with the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Switch the app over**

In `Sources/AppDelegate.swift`, replace:

```swift
        HUDWindowController.shared.show(appState: self.appState)
```

with:

```swift
        NotchNudgeController.shared.show(appState: self.appState)
```

- [ ] **Step 3: Build and run**

Run: `pkill -x Hush; ./build.sh && open Hush.app`
Expected: app launches; translucent pill visible top-center at the notch.

- [ ] **Step 4: Manual state check (ask the user)**

Ask the user to: dictate once (hotkey held), watching for — idle pill →
"Listening" + teal bars reacting to voice → "Thinking" + purple pulse →
back to idle pill. Then compare idle pill and expansion side-by-side with
the real HeyClicky. Wait for his feedback; iterate on sizes/colors/offsets
in `NudgeView.swift` until he approves.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/NotchNudgeController.swift Sources/AppDelegate.swift
git commit -m "feat: notch-anchored nudge panel replaces floating HUD window"
```

---

### Task 4: Remove the old HUD and the position setting

**Files:**
- Create: `Sources/Models/HUDState.swift` (enum moves here)
- Modify: `Sources/UI/FullSettingsView.swift` (remove HUD Position picker rows ~lines 192–201; absorb `HotkeyString`)
- Modify: `Sources/Models/Settings.swift` (remove `hudPosition` property, lines 48–50, and its init line 110)
- Delete: `Sources/UI/HUDView.swift`, `Sources/UI/HUDWindowController.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `HUDState` enum unchanged but now in `Sources/Models/HUDState.swift`; `HotkeyString` struct unchanged but now in `Sources/UI/FullSettingsView.swift`.

- [ ] **Step 1: ASK THE USER for permission to delete the two files** (his global rule). Do not proceed without an explicit yes.

- [ ] **Step 2: Move `HUDState` into its own file**

Create `Sources/Models/HUDState.swift`:

```swift
import Foundation

enum HUDState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}
```

- [ ] **Step 3: Move `HotkeyString` into its consumer**

Append to the bottom of `Sources/UI/FullSettingsView.swift` (copied verbatim from `HUDView.swift:120-127`):

```swift
struct HotkeyString {
    static var current: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
            return shortcut.description
        }
        return "⇧A"
    }
}
```

Ensure `import KeyboardShortcuts` exists at the top of `FullSettingsView.swift` (add it if missing).

- [ ] **Step 4: Delete the old HUD files**

```bash
git rm Sources/UI/HUDView.swift Sources/UI/HUDWindowController.swift
```

- [ ] **Step 5: Remove the position setting**

In `Sources/Models/Settings.swift` delete the `hudPosition` property (lines 48–50) and its assignment in `init` (line 110: `self.hudPosition = defaults.string(forKey: "hudPosition") ?? "bottom"`).

In `Sources/UI/FullSettingsView.swift` delete the whole "HUD Position" `HStack` block and its surrounding `Divider()` (approx. lines 190–204: `Divider()`, `HStack { Text("HUD Position") ... }`; keep exactly one `Divider()` between the neighboring settings rows).

- [ ] **Step 6: Build and run**

Run: `pkill -x Hush; swift build 2>&1 | tail -3 && ./build.sh && open Hush.app`
Expected: `Build complete!`; app runs; Settings no longer shows "HUD Position"; dictation states all still render.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/
git commit -m "refactor: remove legacy HUD pill and HUD position setting"
```

---

### Task 5: Full manual QA pass

**Files:** none (verification + polish fixes only)

- [ ] **Step 1: Run the spec's QA checklist with the user**

1. Idle pill vs HeyClicky side-by-side (position, width, translucency).
2. Dictation cycle: Listening (teal, voice-reactive) → Thinking (purple pulse) → idle.
3. Error state: trigger by stopping a recording almost instantly (< 0.3 s) with Ollama cleanup OFF, or temporarily enable AI Cleanup with Ollama not running to get the "Ollama not detected" error — verify red text in the expansion, then auto-return to idle.
4. Fullscreen app (e.g. YouTube fullscreen in Chrome): nudge still visible while dictating.
5. External monitor if available: fallback pill renders and animates at top-center.

- [ ] **Step 2: Fix any visual nits the user reports** (sizes, paddings, colors live in `NudgeView.swift`; panel level/position in `NotchNudgeController.swift`). Rebuild and re-check after each fix.

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "polish: nudge QA fixes from side-by-side comparison with HeyClicky"
```
