import Foundation
import SwiftUI
import Security

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @Published var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }
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
    @Published var hudPosition: String {
        didSet { UserDefaults.standard.set(hudPosition, forKey: "hudPosition") }
    }
    
    @Published var groqAPIKey: String {
        didSet { 
            UserDefaults.standard.set(groqAPIKey, forKey: "groqAPIKey")
            if !groqAPIKey.isEmpty {
                hasCompletedOnboarding = true
            }
        }
    }
    @Published var startSound: String {
        didSet { UserDefaults.standard.set(startSound, forKey: "startSound") }
    }
    @Published var stopSound: String {
        didSet { UserDefaults.standard.set(stopSound, forKey: "stopSound") }
    }
    
    init() {
        let defaults = UserDefaults.standard
        
        self.whisperModel = defaults.string(forKey: "whisperModel") ?? "whisper-large-v3-turbo"
        
        if defaults.object(forKey: "aiCleanupEnabled") != nil {
            self.aiCleanupEnabled = defaults.bool(forKey: "aiCleanupEnabled")
        } else {
            self.aiCleanupEnabled = false // Default to false to prevent LLM talking back or skipping words
        }
        
        self.selectedMicrophoneID = defaults.string(forKey: "selectedMicrophoneID") ?? ""
        let loadedKey = defaults.string(forKey: "groqAPIKey") ?? ""
        self.groqAPIKey = loadedKey
        
        if !loadedKey.isEmpty {
            self.hasCompletedOnboarding = true
        } else {
            self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        }
        
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
        self.hudPosition = defaults.string(forKey: "hudPosition") ?? "bottom"
        self.startSound = defaults.string(forKey: "startSound") ?? "Ping"
        self.stopSound = defaults.string(forKey: "stopSound") ?? "Pop"
    }
}
