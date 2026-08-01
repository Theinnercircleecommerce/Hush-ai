# Notch Settings Panel (Phase 1.5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dashboard's Settings tab with a Clicky-style two-view panel (Home on hover, Settings via gear) that springs out of the notch, including a properly wired microphone picker.

**Architecture:** Phase 1's display nudge stays untouched. Three new units: an invisible hover-catcher panel over the notch zone, a `NudgeMenuController` owning a non-activating key-capable menu panel, and a `NudgeMenuView` SwiftUI two-view UI bound to `AppSettings.shared`. Mic selection goes `AVCaptureDevice` UID → CoreAudio device ID → AVAudioEngine input unit.

**Tech Stack:** Swift 5.9 SwiftPM, SwiftUI + AppKit + CoreAudio. macOS 14+. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-01-notch-settings-panel-design.md`

## ⚠️ DO-NOT-REGRESS (Phase 1 invariants — repo code is source of truth)

- NEVER modify sizing, safe-area handling, or state logic in
  `Sources/UI/NudgeView.swift`, `Sources/UI/NudgeShape.swift`, or the
  display panel in `Sources/UI/NotchNudgeController.swift`. Verified facts:
  safe-area is disabled twice (`hosting.safeAreaRegions = []` +
  `.ignoresSafeArea()`); idle shelf = `notchWidth + 72` × `notchHeight + 1`;
  active bar = `notchWidth + 260`, flush with the notch bottom.
- After any change touching those files, check the geometry self-log:
  `tail -2 "$(getconf DARWIN_USER_TEMP_DIR)/hush-nudge-geo.log"` — panel
  top must equal screenMaxY and hostingSafeArea must be all zeros.
- USER RULE: never delete files without asking Lord Berries first (Task 5
  has a deletion gate).

## Global Constraints

- Build: `swift build`; app bundle: `./build.sh`; relaunch:
  `pkill -x Hush; ./build.sh && open Hush.app`. NEVER `xcodebuild`.
- No test target; verification = `swift build` + manual runs with the user.
- Reference code (re-clone if `/tmp/clicky-refs` is missing — commands in
  `docs/superpowers/research/2026-07-31-clicky-research-dossier.md`):
  hover/expand mechanics `glide/apps/macos/Glide/GlideDynamicIslandManager.swift`;
  key-capable non-activating dropdown + click-outside dismissal
  `farzaa-clicky/leanring-buddy/MenuBarPanelManager.swift`.
- Visual ground truth: user screenshots of HeyClicky's panel (Home view +
  two settings pages). The user compares side-by-side with the real app.
- All UI on the main thread. Panel must never activate the app
  (`.nonactivatingPanel`) — typing in another app must not lose focus,
  except when the user clicks INTO one of our text fields.

---

### Task 1: Hover catcher + empty menu panel that opens and closes

**Files:**
- Create: `Sources/UI/NudgeMenuController.swift`
- Modify: `Sources/UI/NotchNudgeController.swift` (only the `rebuildPanels`
  loop end, to install the catcher — no display-panel changes)

**Interfaces:**
- Produces: `final class NudgeMenuController` with `static let shared`,
  `func attach(appState: AppState)`, `func rebuildCatchers()`,
  `var isOpen: Bool`.
- Produces (private): `HoverCatcherPanel`, `KeyableMenuPanel`.
- Consumes: `NotchMetrics`, `NudgeLayout` (existing, Task-1 of Phase 1).

- [ ] **Step 1: Create the controller with catcher + placeholder panel**

```swift
import Cocoa
import Combine
import SwiftUI

/// Hover-over-the-notch → menu panel. Owns an invisible mouse-accepting
/// "catcher" strip over the notch/pill zone per screen, and one shared
/// menu panel that springs open beneath the notch of the hovered screen.
final class NudgeMenuController {
    static let shared = NudgeMenuController()

    private(set) var isOpen = false
    private var catchers: [HoverCatcherPanel] = []
    private var menuPanel: KeyableMenuPanel?
    private var clickOutsideMonitor: Any?
    private weak var appState: AppState?

    private init() {}

    private var stateCancellable: AnyCancellable?

    func attach(appState: AppState) {
        self.appState = appState
        // Auto-close the panel the moment dictation starts.
        stateCancellable = appState.$hudState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state != .idle { self?.close() }
            }
        rebuildCatchers()
    }

    func rebuildCatchers() {
        for catcher in catchers { catcher.close() }
        catchers.removeAll()

        for screen in NSScreen.screens {
            let metrics = NotchMetrics.metrics(for: screen)
            // Zone = idle shelf on notched screens; pill zone on others.
            let zoneWidth: CGFloat = metrics.hasNotch ? metrics.notchWidth + 72 : 260
            let zoneHeight: CGFloat = metrics.hasNotch ? metrics.notchHeight + 1 : 16
            let rect = NSRect(
                x: screen.frame.midX - zoneWidth / 2,
                y: screen.frame.maxY - zoneHeight,
                width: zoneWidth,
                height: zoneHeight
            )
            let catcher = HoverCatcherPanel(zone: rect, screen: screen)
            catcher.onHover = { [weak self] hoveredScreen in
                self?.open(on: hoveredScreen)
            }
            catcher.orderFront(nil)
            catchers.append(catcher)
        }
    }

    func open(on screen: NSScreen) {
        guard !isOpen else { return }
        guard let appState = appState else { return }
        // Never open while the nudge is busy showing dictation state.
        if appState.hudState != .idle { return }
        isOpen = true

        let panel = KeyableMenuPanel()
        let hosting = NSHostingView(
            rootView: NudgeMenuView(
                appState: appState,
                onClose: { [weak self] in self?.close() }
            )
        )
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        let metrics = NotchMetrics.metrics(for: screen)
        let size = NudgeMenuLayout.homeSize
        let topY = screen.frame.maxY - (metrics.hasNotch ? 0 : 4)
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: topY - size.height,
                   width: size.width, height: size.height),
            display: false
        )
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        menuPanel = panel
        installClickOutsideMonitor()
    }

    func close() {
        guard isOpen, let panel = menuPanel else { return }
        isOpen = false
        removeClickOutsideMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
        menuPanel = nil
    }

    /// Called by NudgeMenuView when switching Home <-> Settings.
    func resize(to size: CGSize) {
        guard let panel = menuPanel, let screen = panel.screen ?? NSScreen.main else { return }
        let metrics = NotchMetrics.metrics(for: screen)
        let topY = screen.frame.maxY - (metrics.hasNotch ? 0 : 4)
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: topY - size.height,
                           width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func installClickOutsideMonitor() {
        // Grace delay so opening-click / permission dialogs aren't caught
        // (farzaa-clicky pattern).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.isOpen else { return }
            self.clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.close()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

enum NudgeMenuLayout {
    static let homeSize = CGSize(width: 510, height: 260)
    static let settingsSize = CGSize(width: 510, height: 640)
}

/// Invisible strip over the notch/pill zone that only exists to receive
/// mouse-entered events. The notch zone has no clickable system UI, so
/// intercepting the mouse here is safe.
final class HoverCatcherPanel: NSPanel {
    var onHover: ((NSScreen) -> Void)?
    private let targetScreen: NSScreen

    init(zone: NSRect, screen: NSScreen) {
        self.targetScreen = screen
        super.init(contentRect: zone,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let tracker = HoverTrackerView(frame: NSRect(origin: .zero, size: zone.size))
        tracker.onEntered = { [weak self] in
            guard let self = self else { return }
            self.onHover?(self.targetScreen)
        }
        contentView = tracker
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HoverTrackerView: NSView {
    var onEntered: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }
}

/// Non-activating but key-capable, so the shortcut recorder and text
/// fields inside the menu work without activating Hush.
final class KeyableMenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Placeholder menu view so Task 1 compiles standalone**

Append to the SAME file (Task 2 moves it to its own file and replaces the
body):

```swift
struct NudgeMenuView: View {
    @ObservedObject var appState: AppState
    var onClose: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color.black.opacity(0.96))
            .overlay(Text("menu placeholder").foregroundColor(.white))
    }
}
```

- [ ] **Step 3: Wire into the app**

In `Sources/UI/NotchNudgeController.swift`, at the END of
`rebuildPanels()` (after the screen loop — do not touch the loop body),
add:

```swift
        NudgeMenuController.shared.attach(appState: appState)
```

(`attach` re-runs `rebuildCatchers()`, so screen changes rebuild both.)

- [ ] **Step 4: Compile and hand-test**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `pkill -x Hush; ./build.sh && open Hush.app`
Ask the user: hover the notch → placeholder appears under the notch;
click anywhere outside → it fades away; start dictating → hover does
NOT open it. Also verify the nudge itself still looks/behaves exactly
as before (geometry log check per DO-NOT-REGRESS).

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/NudgeMenuController.swift Sources/UI/NotchNudgeController.swift
git commit -m "feat: hover catcher opens menu panel skeleton from the notch"
```

---

### Task 2: Home view

**Files:**
- Create: `Sources/UI/NudgeMenuView.swift` (move struct from Task 1 file,
  delete the placeholder there)
- Modify: `Sources/UI/NudgeMenuController.swift` (remove placeholder struct)

**Interfaces:**
- Consumes: `AppState` (`hudState`), `AppSettings.shared`,
  `HistoryStore` daily stats (`Sources/Core/HistoryStore.swift` — use the
  same APIs `HomeDashboardView.swift` uses for words-today and streak; read
  that file first and mirror its calls exactly),
  `HotkeyString.current` (currently in `Sources/UI/FullSettingsView.swift`),
  `NudgeMenuController.shared.resize(to:)`, `NudgeMenuLayout`.
- Produces: `struct NudgeMenuView: View { init(appState:onClose:) }` with
  `enum NudgeMenuTab { case home, settings }` internal state.

- [ ] **Step 1: Build the two-view scaffold + Home content**

`NudgeMenuView` structure (complete the row styling to match the user's
HeyClicky screenshots — dark #0d0d0d background, 24pt corner radius,
rows as rounded #1c1c1e cards, 13pt medium white text, gray captions):

```swift
import SwiftUI
import KeyboardShortcuts

struct NudgeMenuView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var tab: NudgeMenuTab = .home
    var onClose: () -> Void

    enum NudgeMenuTab { case home, settings }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch tab {
            case .home: homeView
            case .settings: settingsView   // Task 3 fills this in
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.05))
        )
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Label("Home", systemImage: "house.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tab == .home ? .white : .gray)
                .onTapGesture { switchTab(.home) }
            Spacer()
            Button(action: { switchTab(tab == .settings ? .home : .settings) }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(tab == .settings ? .white : .gray)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func switchTab(_ newTab: NudgeMenuTab) {
        guard newTab != tab else { return }
        tab = newTab
        NudgeMenuController.shared.resize(
            to: newTab == .settings ? NudgeMenuLayout.settingsSize
                                    : NudgeMenuLayout.homeSize
        )
    }
    // homeView / settingsView / row components follow
}
```

Home view contents (left column stats, right column shortcuts, bottom
dashboard button):

```swift
    private var homeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    statCard(title: "words today", value: wordsTodayText)
                    statCard(title: "day streak", value: streakText)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("⌘ Shortcuts")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gray)
                    shortcutRow(name: "Dictate", keys: HotkeyString.current)
                    // Later phases append Talk / Text rows here.
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Button(action: {
                onClose()
                NotificationCenter.default.post(
                    name: Notification.Name("OpenDashboard"), object: nil)
            }) {
                Label("Open Dashboard", systemImage: "rectangle.grid.2x2")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.11, green: 0.11, blue: 0.12)))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }
```

Implement `statCard(title:value:)`, `shortcutRow(name:keys:)` (keys in a
small rounded keycap style like the screenshots), and `wordsTodayText` /
`streakText` using the exact HistoryStore APIs mirrored from
`HomeDashboardView.swift`. Move `HotkeyString` out of
`FullSettingsView.swift` into this file (it gets deleted in Task 5); leave
a `// moved to NudgeMenuView.swift` free `FullSettingsView` compiling by
removing its copy.

- [ ] **Step 2: Compile, relaunch, hand-test with the user** (hover →
  Home shows real stats and hotkey; gear → grows to empty settings and
  back; Open Dashboard button opens the dashboard and closes the panel).

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/NudgeMenuView.swift Sources/UI/NudgeMenuController.swift Sources/UI/FullSettingsView.swift
git commit -m "feat: notch menu Home view with stats, shortcuts, dashboard button"
```

---

### Task 3: Settings view (all sections)

**Files:**
- Modify: `Sources/UI/NudgeMenuView.swift`

**Interfaces:**
- Consumes: every `AppSettings.shared` published property (see
  `Sources/Models/Settings.swift` — model sizes/languages/sounds lists are
  in `FullSettingsView.swift`'s pickers; copy the option lists verbatim),
  Sparkle update check (find the existing "Check for Updates" action —
  `grep -n "checkForUpdates" Sources/` — and call the same method).
- Produces: `settingsView` body used by Task 2's scaffold.

- [ ] **Step 1: Build the sectioned settings list**

`settingsView` = `ScrollView` of sections in this order (styling: gray
uppercase 11pt section captions, rows as rounded dark cards — match the
user's HeyClicky screenshots):

1. **DICTATION** — rows: model size `Picker` (tiny/base/small/
   distil-large-v3/large-v3-turbo — copy exact tags from
   `ProcessingSettingsView`), language `Picker` (en/nl/de/fr/es/auto —
   copy from `GeneralSettingsView`), `Toggle` AI Cleanup + conditional
   Ollama model `TextField`, secondary rows: `Toggle` Press Enter command,
   `Toggle` Command Mode, `Toggle` Bulk import.
2. **SHORTCUTS** — row hosting `KeyboardShortcuts.Recorder(for: .toggleRecord)`.
3. **SOUND** — start sound `Picker` + stop sound `Picker` (copy the option
   list from `SystemSettingsView`).
4. **MICROPHONE** — row showing current device name with chevron (Task 4
   wires the picker; for now render `Text(settings.selectedMicrophoneID.isEmpty ? "System default" : settings.selectedMicrophoneID)`).
5. **SYSTEM** — `Toggle` Launch at login, `Toggle` Show in Dock
   (subtitle "Turn off to keep Hush notch only."), menu-bar icon `Picker`.
6. **SUPPORT** — "Check for Updates" row calling the existing Sparkle
   action.
7. **Footer** — red "Quit Hush" row (`NSApp.terminate(nil)`) and version
   caption from `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`.

Write complete row helper views (`settingsSection(title:content:)`,
`settingsRow(icon:title:subtitle:trailing:)`) — every row must be real
working controls bound to `settings`, not placeholders.

- [ ] **Step 2: Compile, relaunch, hand-test with the user** — flip every
  toggle/picker in the notch panel, then confirm the change is live
  (e.g. switch stop sound and dictate; toggle dock icon).

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/NudgeMenuView.swift
git commit -m "feat: full settings sections inside the notch panel"
```

---

### Task 4: Microphone picker, actually wired

**Files:**
- Modify: `Sources/Core/AudioCaptureService.swift`
- Modify: `Sources/UI/NudgeMenuView.swift` (MICROPHONE row becomes a picker)

**Interfaces:**
- Produces: `struct MicrophoneDevice: Identifiable { let id: String  // CoreAudio UID; let name: String }`,
  `static func availableMicrophones() -> [MicrophoneDevice]` on
  `AudioCaptureService`, and device application inside
  `AudioCaptureService.startRecording` (or wherever the engine starts —
  read the file first; it is 82 lines).
- Consumes: `AppSettings.shared.selectedMicrophoneID` (already exists,
  currently unused).

- [ ] **Step 1: Device discovery + engine wiring in AudioCaptureService**

```swift
import AVFoundation
import CoreAudio

struct MicrophoneDevice: Identifiable, Hashable {
    let id: String   // CoreAudio/AVCaptureDevice unique ID
    let name: String
}

extension AudioCaptureService {
    static func availableMicrophones() -> [MicrophoneDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// Translates a CoreAudio UID string to an AudioDeviceID.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var cfUID = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr,
                &size, &deviceID
            )
        }
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }

    /// Points the engine's input node at the selected device. Call BEFORE
    /// installing the tap / starting the engine.
    func applySelectedMicrophone(to engine: AVAudioEngine) {
        let uid = AppSettings.shared.selectedMicrophoneID
        guard !uid.isEmpty,
              var deviceID = Self.audioDeviceID(forUID: uid),
              let unit = engine.inputNode.audioUnit else { return }
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}
```

Then read `AudioCaptureService.swift` and call
`applySelectedMicrophone(to: engine)` at the start of the record path,
before `engine.inputNode` format/tap setup. Empty
`selectedMicrophoneID` = system default (no call).

- [ ] **Step 2: Replace the MICROPHONE row with a working picker**

`Picker` bound to `settings.selectedMicrophoneID`, options: "System
default" (tag `""`) + `AudioCaptureService.availableMicrophones()`
(tag = `id`, label = `name`), refreshed `.onAppear`. Show the selected
device's name in the row like HeyClicky's "AirPods Max".

- [ ] **Step 3: Compile, relaunch, hand-test with the user** — pick a
  non-default mic (e.g. AirPods), dictate, confirm audio came from it;
  switch back to System default and dictate again.

- [ ] **Step 4: Commit**

```bash
git add Sources/Core/AudioCaptureService.swift Sources/UI/NudgeMenuView.swift
git commit -m "feat: working microphone picker wired through CoreAudio"
```

---

### Task 5: Retire the dashboard Settings tab

**Files:**
- Modify: `Sources/UI/MainDashboardView.swift` (remove `.settings` case
  from `SidebarItem` enum, its NavigationLink block at lines ~77–83, its
  icon case, and the `case .settings: FullSettingsView()` switch arm)
- Modify: `Sources/HushApp.swift:30` (the onboarding deep-link sets
  `selectedSidebarItem = "Settings"` — change to `"Home"`)
- Delete: `Sources/UI/FullSettingsView.swift`

**Steps:**

- [ ] **Step 1: ASK THE USER for permission to delete
  `FullSettingsView.swift`** (his global rule). Confirm `HotkeyString` and
  any picker option lists were already moved into `NudgeMenuView.swift`
  (Tasks 2–3) — `grep -n "HotkeyString\|FullSettingsView" Sources/` must
  show no remaining references outside the file itself.

- [ ] **Step 2: Remove sidebar entry + switch arm + deep-link** (files/
  lines above; keep all other sidebar items).

- [ ] **Step 3: Delete the file**

```bash
git rm Sources/UI/FullSettingsView.swift
```

- [ ] **Step 4: Build, relaunch, hand-test** — dashboard shows no Settings
  item; onboarding completion still lands somewhere sane; notch panel is
  now the only settings surface.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/
git commit -m "refactor: notch panel replaces dashboard settings tab"
```

---

### Task 6: QA pass with the user

- [ ] **Step 1: Run the spec's manual test list** — hover open/close feel
  vs HeyClicky, gear switch animation, every row functional, mic switch
  verified by dictation, click-outside dismissal, no focus stealing while
  typing elsewhere (type in another app with panel open), dictation
  auto-close, external monitor hover-over-pill, nudge geometry log still
  clean.
- [ ] **Step 2: Fix reported nits, rebuild, re-check.**
- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "polish: notch settings panel QA fixes"
```
