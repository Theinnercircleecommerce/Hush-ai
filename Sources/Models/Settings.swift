import Foundation
import SwiftUI
import AppKit
import Security

// MARK: - Talk hold-to-talk combos

/// Hold-to-talk is a modifier-only combo, which KeyboardShortcuts.Recorder
/// cannot record. The user picks from this fixed list instead.
struct TalkCombo: Identifiable {
    let id: String
    let label: String
    let symbols: [String]
    let flags: NSEvent.ModifierFlags

    static let all: [TalkCombo] = [
        TalkCombo(id: "control+option",  label: "⌃⌥  Control Option",  symbols: ["⌃", "⌥"], flags: [.control, .option]),
        TalkCombo(id: "control+shift",   label: "⌃⇧  Control Shift",   symbols: ["⌃", "⇧"], flags: [.control, .shift]),
        TalkCombo(id: "control+command", label: "⌃⌘  Control Command", symbols: ["⌃", "⌘"], flags: [.control, .command]),
        TalkCombo(id: "option+shift",    label: "⌥⇧  Option Shift",    symbols: ["⌥", "⇧"], flags: [.option, .shift]),
        TalkCombo(id: "command+option",  label: "⌘⌥  Command Option",  symbols: ["⌘", "⌥"], flags: [.command, .option]),
        TalkCombo(id: "command+shift",   label: "⌘⇧  Command Shift",   symbols: ["⌘", "⇧"], flags: [.command, .shift]),
        TalkCombo(id: "fn",              label: "fn  Globe",           symbols: ["fn"],     flags: [.function]),
    ]

    static func named(_ id: String) -> TalkCombo {
        all.first { $0.id == id } ?? all[0]
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @Published var aiCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(aiCleanupEnabled, forKey: "aiCleanupEnabled") }
    }
    @Published var selectedMicrophoneID: String {
        didSet { UserDefaults.standard.set(selectedMicrophoneID, forKey: "selectedMicrophoneID") }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    
    @Published var dailyWordGoal: Int {
        didSet { UserDefaults.standard.set(dailyWordGoal, forKey: "dailyWordGoal") }
    }
    @Published var primaryLanguage: String {
        didSet { UserDefaults.standard.set(primaryLanguage, forKey: "primaryLanguage") }
    }
    @Published var secondaryLanguage: String {
        didSet { UserDefaults.standard.set(secondaryLanguage, forKey: "secondaryLanguage") }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published var showInDock: Bool {
        didSet { UserDefaults.standard.set(showInDock, forKey: "showInDock") }
    }
    @Published var menuBarIconStyle: String {
        didSet { UserDefaults.standard.set(menuBarIconStyle, forKey: "menuBarIconStyle") }
    }
    @Published var commandModeEnabled: Bool {
        didSet { UserDefaults.standard.set(commandModeEnabled, forKey: "commandModeEnabled") }
    }
    @Published var pressEnterEnabled: Bool {
        didSet { UserDefaults.standard.set(pressEnterEnabled, forKey: "pressEnterEnabled") }
    }
    @Published var bulkImportEnabled: Bool {
        didSet { UserDefaults.standard.set(bulkImportEnabled, forKey: "bulkImportEnabled") }
    }
    @Published var scratchpadText: String {
        didSet { UserDefaults.standard.set(scratchpadText, forKey: "scratchpadText") }
    }

    @Published var startSound: String {
        didSet { UserDefaults.standard.set(startSound, forKey: "startSound") }
    }
    @Published var stopSound: String {
        didSet { UserDefaults.standard.set(stopSound, forKey: "stopSound") }
    }
    /// Talk gets its own pair so the two modes are audibly distinguishable.
    @Published var talkStartSound: String {
        didSet { UserDefaults.standard.set(talkStartSound, forKey: "talkStartSound") }
    }
    @Published var talkStopSound: String {
        didSet { UserDefaults.standard.set(talkStopSound, forKey: "talkStopSound") }
    }
    
    @Published var whisperKitModelSize: String {
        didSet { UserDefaults.standard.set(whisperKitModelSize, forKey: "whisperKitModelSize") }
    }
    @Published var ollamaModelName: String {
        didSet { UserDefaults.standard.set(ollamaModelName, forKey: "ollamaModelName") }
    }
    @Published var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: "ttsVoice") }
    }
    @Published var showAnswerBubble: Bool {
        didSet { UserDefaults.standard.set(showAnswerBubble, forKey: "showAnswerBubble") }
    }
    /// TalkCombo.id for the hold-to-talk modifier combo.
    @Published var talkCombo: String {
        didSet { UserDefaults.standard.set(talkCombo, forKey: "talkCombo") }
    }

    init() {
        let defaults = UserDefaults.standard
        
        if defaults.object(forKey: "aiCleanupEnabled") != nil {
            self.aiCleanupEnabled = defaults.bool(forKey: "aiCleanupEnabled")
        } else {
            self.aiCleanupEnabled = false // Default to false to prevent LLM talking back or skipping words
        }
        
        self.selectedMicrophoneID = defaults.string(forKey: "selectedMicrophoneID") ?? ""
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        
        if defaults.object(forKey: "dailyWordGoal") != nil {
            self.dailyWordGoal = defaults.integer(forKey: "dailyWordGoal")
        } else {
            self.dailyWordGoal = 100
        }
        
        self.primaryLanguage = defaults.string(forKey: "primaryLanguage") ?? "en"
        self.secondaryLanguage = defaults.string(forKey: "secondaryLanguage") ?? ""
        
        if defaults.object(forKey: "launchAtLogin") != nil {
            self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        } else {
            self.launchAtLogin = true
        }
        
        if defaults.object(forKey: "showInDock") != nil {
            self.showInDock = defaults.bool(forKey: "showInDock")
        } else {
            self.showInDock = true
        }
        
        self.menuBarIconStyle = defaults.string(forKey: "menuBarIconStyle") ?? "default"
        self.commandModeEnabled = defaults.bool(forKey: "commandModeEnabled")
        
        if defaults.object(forKey: "pressEnterEnabled") != nil {
            self.pressEnterEnabled = defaults.bool(forKey: "pressEnterEnabled")
        } else {
            self.pressEnterEnabled = true
        }
        
        self.bulkImportEnabled = defaults.bool(forKey: "bulkImportEnabled")
        self.scratchpadText = defaults.string(forKey: "scratchpadText") ?? ""
        self.startSound = defaults.string(forKey: "startSound") ?? "Ping"
        self.stopSound = defaults.string(forKey: "stopSound") ?? "Pop"
        self.talkStartSound = defaults.string(forKey: "talkStartSound") ?? "Tink"
        self.talkStopSound = defaults.string(forKey: "talkStopSound") ?? "Bottle"
        self.whisperKitModelSize = defaults.string(forKey: "whisperKitModelSize") ?? "tiny"
        self.ollamaModelName = defaults.string(forKey: "ollamaModelName") ?? "llama3.2:3b"
        self.ttsVoice = defaults.string(forKey: "ttsVoice") ?? "alloy"
        // Owner preference: voice-only by default; the written answer is opt-in.
        self.showAnswerBubble = defaults.object(forKey: "showAnswerBubble") as? Bool ?? false
        self.talkCombo = defaults.string(forKey: "talkCombo") ?? "control+option"
    }
}
