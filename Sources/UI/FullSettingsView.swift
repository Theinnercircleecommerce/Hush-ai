import SwiftUI
import KeyboardShortcuts

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case processing = "Processing"
    case system = "System"
    case vibeCoding = "Vibe coding"
    case experimental = "Experimental"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .processing: return "cpu"
        case .system: return "desktopcomputer"
        case .vibeCoding: return "sparkles"
        case .experimental: return "flask"
        }
    }
}

struct FullSettingsView: View {
    @State private var selectedSection: SettingsSection = .general
    
    var body: some View {
        TabView(selection: $selectedSection) {
            ScrollView {
                GeneralSettingsView()
                    .padding()
            }
            .tabItem { Label(SettingsSection.general.rawValue, systemImage: SettingsSection.general.iconName) }
            .tag(SettingsSection.general)
            
            ScrollView {
                ProcessingSettingsView()
                    .padding()
            }
            .tabItem { Label(SettingsSection.processing.rawValue, systemImage: SettingsSection.processing.iconName) }
            .tag(SettingsSection.processing)
            
            ScrollView {
                SystemSettingsView()
                    .padding()
            }
            .tabItem { Label(SettingsSection.system.rawValue, systemImage: SettingsSection.system.iconName) }
            .tag(SettingsSection.system)
            
            ScrollView {
                VibeCodingSettingsView()
                    .padding()
            }
            .tabItem { Label(SettingsSection.vibeCoding.rawValue, systemImage: SettingsSection.vibeCoding.iconName) }
            .tag(SettingsSection.vibeCoding)
            
            ScrollView {
                ExperimentalSettingsView()
                    .padding()
            }
            .tabItem { Label(SettingsSection.experimental.rawValue, systemImage: SettingsSection.experimental.iconName) }
            .tag(SettingsSection.experimental)
        }
        .padding()
    }
}

// Custom Card style for Settings
struct SettingsCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            .foregroundColor(.primary)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct GeneralSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Shortcuts")
                            .font(.headline)
                        Text("Hold \(HotkeyString.current) and speak")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleRecord)
                }
                
                Divider()
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("Microphone")
                            .font(.headline)
                        Text("Built-in mic (recommended)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Change") {
                        // Action
                    }
                    .buttonStyle(PillButtonStyle())
                }
                
                Divider()
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("Language")
                            .font(.headline)
                        Text("Transcription language")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $settings.primaryLanguage) {
                        Text("English").tag("en")
                        Text("Dutch (Nederlands)").tag("nl")
                        Text("German (Deutsch)").tag("de")
                        Text("French (Français)").tag("fr")
                        Text("Spanish (Español)").tag("es")
                        Text("Auto-detect").tag("")
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 180)
                }
            }
        }
    }
}

struct SystemSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        SettingsCard {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .font(.headline)
            
            Divider()
            
            Toggle("Show in Dock", isOn: $settings.showInDock)
                .font(.headline)
            
            Divider()
            
            HStack {
                Text("Menu bar icon style")
                    .font(.headline)
                Spacer()
                Picker("", selection: $settings.menuBarIconStyle) {
                    Text("Default").tag("default")
                    Text("Monochrome").tag("monochrome")
                }
                .pickerStyle(MenuPickerStyle())
            }
            
            Divider()
            
            HStack {
                Text("HUD Position")
                    .font(.headline)
                Spacer()
                Picker("", selection: $settings.hudPosition) {
                    Text("Top (Below Notch)").tag("top")
                    Text("Bottom").tag("bottom")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 200)
            }
            
            Divider()
            
            let soundOptions = ["None", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
            
            HStack {
                Text("Start Sound")
                    .font(.headline)
                Spacer()
                Picker("", selection: $settings.startSound) {
                    ForEach(soundOptions, id: \.self) { sound in
                        Text(sound).tag(sound)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 150)
                .onChange(of: settings.startSound) { newValue in
                    if newValue != "None" {
                        NSSound(named: newValue)?.play()
                    }
                }
            }
            
            HStack {
                Text("Stop Sound")
                    .font(.headline)
                Spacer()
                Picker("", selection: $settings.stopSound) {
                    ForEach(soundOptions, id: \.self) { sound in
                        Text(sound).tag(sound)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 150)
                .onChange(of: settings.stopSound) { newValue in
                    if newValue != "None" {
                        NSSound(named: newValue)?.play()
                    }
                }
            }
            
            Divider()
            
            HStack {
                VStack(alignment: .leading) {
                    Text("Updates")
                        .font(.headline)
                    Text("Keep Hush up to date with the latest features.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Check for Updates") {
                    AppDelegate.shared.updaterController.checkForUpdates(nil)
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }
}

struct VibeCodingSettingsView: View {
    var body: some View {
        SettingsCard {
            Text("Vibe coding optimizations coming soon")
                .foregroundColor(.secondary)
        }
    }
}

struct ExperimentalSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        SettingsCard {
            Toggle(isOn: $settings.commandModeEnabled) {
                VStack(alignment: .leading) {
                    Text("Command Mode")
                        .font(.headline)
                    Text("Enable advanced voice commands. Learn more →")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            Toggle(isOn: $settings.pressEnterEnabled) {
                VStack(alignment: .leading) {
                    Text("Press Enter command")
                        .font(.headline)
                    Text("Automatically press enter when you say 'press enter' at the end of a dictation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            Toggle(isOn: $settings.bulkImportEnabled) {
                VStack(alignment: .leading) {
                    Text("Bulk import")
                        .font(.headline)
                    Text("Import snippets and dictionary items from files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}


struct ProcessingSettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var isTestingOllama = false
    @State private var ollamaTestResult = ""
    
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local Transcription (WhisperKit)")
                    .font(.headline)
                Text("Runs entirely on-device. Downloads model on first use.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    Text("Model Size")
                    Spacer()
                    Picker("", selection: $settings.whisperKitModelSize) {
                        Text("Tiny (Fastest)").tag("tiny")
                        Text("Base (Default)").tag("base")
                        Text("Small (Accurate)").tag("small")
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                }
            }
        }
        
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Cleanup")
                    .font(.headline)
                
                Toggle("Enable AI Cleanup", isOn: $settings.aiCleanupEnabled)
                
                if settings.aiCleanupEnabled {
                    Divider()
                    Text("Local Cleanup (Ollama)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Requires Ollama running locally (http://localhost:11434).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("Model Name")
                        Spacer()
                        TextField("e.g. llama3.2:3b", text: $settings.ollamaModelName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 150)
                    }
                    
                    HStack {
                        Spacer()
                        Button(action: testOllama) {
                            Text(isTestingOllama ? "Testing..." : "Test Connection")
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(isTestingOllama)
                    }
                    
                    if !ollamaTestResult.isEmpty {
                        Text(ollamaTestResult)
                            .font(.caption)
                            .foregroundColor(ollamaTestResult.contains("Success") ? .green : .red)
                    }
                }
            }
        }
    }
    
    private func testOllama() {
        isTestingOllama = true
        ollamaTestResult = ""
        Task {
            let service = OllamaCleanupService()
            let isRunning = await service.checkIsRunning()
            DispatchQueue.main.async {
                self.isTestingOllama = false
                if isRunning {
                    self.ollamaTestResult = "Success! Ollama is running."
                } else {
                    self.ollamaTestResult = "Error: Ollama not detected."
                }
            }
        }
    }
}
