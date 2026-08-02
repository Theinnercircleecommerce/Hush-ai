import Cocoa
import KeyboardShortcuts
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!
    
    let appState = AppState()
    var updaterController: SPUStandardUpdaterController!
    var lastKeyDownTime: Date?
    var isHandsFreeMode = false
    
    override init() {
        super.init()
        AppDelegate.shared = self
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Sparkle Updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // Setup initial dock state
        updateActivationPolicy(showInDock: AppSettings.shared.showInDock)
        
        // Show the idle pill HUD persistently right away!
        NotchNudgeController.shared.show(appState: self.appState)

        // Temporary wiring for talk hotkey monitor: hold ⌃⌥ → circle overlay.
        TalkHotkeyMonitor.shared.onPress = {
            CircleOverlayController.shared.begin()
        }
        TalkHotkeyMonitor.shared.onRelease = {
            let rect = CircleOverlayController.shared.end()
            TalkHotkeyMonitor.diag("release circle=\(rect.map { NSStringFromRect($0) } ?? "nil")")
        }
        TalkHotkeyMonitor.shared.start()

        // Open onboarding if not completed, otherwise launch silently in the menu bar!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !AppSettings.shared.hasCompletedOnboarding {
                NotificationCenter.default.post(name: Notification.Name("OpenOnboarding"), object: nil)
            }
        }
        
        // Request Accessibility permissions for global hotkeys
        requestAccessibilityPermissions()
        
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            let timeSinceLast = self.lastKeyDownTime.map { now.timeIntervalSince($0) } ?? 10.0
            self.lastKeyDownTime = now
            
            if self.isHandsFreeMode {
                // If currently in hands free mode, any click will stop it
                self.isHandsFreeMode = false
                if self.appState.isRecording {
                    self.appState.stopRecording()
                }
                return
            }
            
            if timeSinceLast < 0.4 {
                // Double click! Set to hands free mode
                self.isHandsFreeMode = true
                if self.appState.hudState == .idle {
                    self.appState.startRecording()
                }
            } else {
                // Single click start
                if self.appState.hudState == .idle {
                    self.appState.startRecording()
                }
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            guard let self = self else { return }
            
            if self.isHandsFreeMode {
                // Do not stop recording if in hands-free mode
                return
            }
            
            // Only stop if we were actually recording
            if self.appState.isRecording {
                self.appState.stopRecording()
            }
        }
    }
    
    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !isTrusted {
            print("Accessibility permissions not granted yet. Prompting user.")
        }
    }
    
    func updateActivationPolicy(showInDock: Bool) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
            if showInDock {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // No dashboard to reopen — the notch panel is the only UI.
        return true
    }
}
