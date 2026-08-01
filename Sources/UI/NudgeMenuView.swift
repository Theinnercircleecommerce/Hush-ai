import SwiftUI
import KeyboardShortcuts

struct HotkeyString {
    static var current: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
            return shortcut.description
        }
        return "⇧A"
    }
}

enum NudgePage: Equatable {
    case home, settings, history, dictionary, snippets, insights

    var title: String {
        switch self {
        case .home: return "Home"
        case .settings: return "Settings"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .insights: return "Insights"
        }
    }

    var panelSize: CGSize {
        switch self {
        case .home: return NudgeMenuLayout.homeSize
        case .settings: return NudgeMenuLayout.settingsSize
        default: return NudgeMenuLayout.subpageSize
        }
    }
}

struct NudgeMenuView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared
    @State private var page: NudgePage = .home
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            // Every page stays mounted so navigation is instant — same
            // stuck-proof pattern NudgeView uses for its states.
            ZStack(alignment: .top) {
                pageLayer(homeView, for: .home)
                pageLayer(settingsView, for: .settings)
                pageLayer(historyView, for: .history)
                pageLayer(dictionaryView, for: .dictionary)
                pageLayer(snippetsView, for: .snippets)
                pageLayer(insightsView, for: .insights)
            }
            .animation(.easeOut(duration: 0.18), value: page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            NudgeNotchShape(topCornerRadius: 10, bottomCornerRadius: 24)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.05))
        )
        .clipShape(NudgeNotchShape(topCornerRadius: 10, bottomCornerRadius: 24))
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("NudgeMenuWillOpen"))) { _ in
            page = .home
        }
    }

    private func pageLayer<C: View>(_ content: C, for target: NudgePage) -> some View {
        content
            .opacity(page == target ? 1 : 0)
            .allowsHitTesting(page == target)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            if page == .home {
                Label("Home", systemImage: "house.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { navigate(to: .settings) }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { navigate(to: .home) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(page.title)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func navigate(to newPage: NudgePage) {
        guard newPage != page else { return }
        page = newPage
        NudgeMenuController.shared.resize(to: newPage.panelSize)
    }

    // MARK: - Home

    private var todayRecords: [TranscriptionRecord] {
        let calendar = Calendar.current
        return history.records.filter { calendar.isDateInToday($0.timestamp) }
    }

    private var wordsTodayText: String {
        "\(todayRecords.reduce(0) { $0 + $1.wordCount })"
    }

    private var streakText: String {
        let calendar = Calendar.current
        let uniqueDays = Set(history.records.map {
            calendar.startOfDay(for: $0.timestamp)
        }).sorted(by: >)
        var streak = 0
        var currentDate = calendar.startOfDay(for: Date())
        for day in uniqueDays {
            if day == currentDate {
                streak += 1
                currentDate = calendar.date(byAdding: .day, value: -1, to: currentDate)!
            } else if day == calendar.date(byAdding: .day, value: -1, to: currentDate)! {
                streak += 1
                currentDate = day
            } else {
                break
            }
        }
        return "\(streak)"
    }

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: { navigate(to: .insights) }) {
                        statCard(title: "words today", value: wordsTodayText)
                    }
                    .buttonStyle(.plain)
                    statCard(title: "day streak", value: streakText)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("⌘ Shortcuts")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.gray)
                    shortcutRow(name: "Dictate", keys: HotkeyString.current)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 0) {
                navRow(icon: "clock.arrow.circlepath", title: "History", page: .history)
                rowDivider
                navRow(icon: "character.book.closed", title: "Dictionary", page: .dictionary)
                rowDivider
                navRow(icon: "scissors", title: "Snippets", page: .snippets)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private func navRow(icon: String, title: String, page target: NudgePage) -> some View {
        Button(action: { navigate(to: target) }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.gray)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 130, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
        )
    }

    private func shortcutRow(name: String, keys: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.22, green: 0.22, blue: 0.24))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.14, green: 0.14, blue: 0.16))
        )
    }

    // MARK: - Sub-pages (filled in Tasks 2–3)

    private var historyView: some View {
        subpagePlaceholder("History")
    }

    private var insightsView: some View {
        subpagePlaceholder("Insights")
    }

    private var dictionaryView: some View {
        subpagePlaceholder("Dictionary")
    }

    private var snippetsView: some View {
        subpagePlaceholder("Snippets")
    }

    private func subpagePlaceholder(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Settings

    private let soundOptions = ["None", "Basso", "Blow", "Bottle", "Frog", "Funk",
                                "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
                                "Sosumi", "Submarine", "Tink"]

    private var settingsView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {

                // DICTATION
                settingsSection(title: "DICTATION") {
                    VStack(spacing: 0) {
                        settingsRow(icon: "cpu", title: "Model Size") {
                            Picker("", selection: $settings.whisperKitModelSize) {
                                Text("Tiny").tag("tiny")
                                Text("Tiny English").tag("tiny.en")
                                Text("Base").tag("base")
                                Text("Base English").tag("base.en")
                                Text("Small").tag("small")
                                Text("Small English").tag("small.en")
                                Text("Distil Large v3").tag("distil-large-v3")
                                Text("Large v3 Turbo").tag("large-v3-turbo")
                            }
                            .pickerStyle(.menu)
                            .frame(width: 160)
                            .colorScheme(.dark)
                        }
                        rowDivider
                        settingsRow(icon: "globe", title: "Language") {
                            Picker("", selection: $settings.primaryLanguage) {
                                Text("English").tag("en")
                                Text("Dutch").tag("nl")
                                Text("German").tag("de")
                                Text("French").tag("fr")
                                Text("Spanish").tag("es")
                                Text("Auto-detect").tag("")
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)
                            .colorScheme(.dark)
                        }
                        rowDivider
                        settingsRow(icon: "wand.and.stars", title: "AI Cleanup") {
                            Toggle("", isOn: $settings.aiCleanupEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        if settings.aiCleanupEnabled {
                            rowDivider
                            settingsRow(icon: "server.rack", title: "Ollama Model") {
                                TextField("e.g. llama3.2:3b", text: $settings.ollamaModelName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 140)
                                    .colorScheme(.dark)
                            }
                        }
                        rowDivider
                        settingsRow(icon: "return", title: "Press Enter Command") {
                            Toggle("", isOn: $settings.pressEnterEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        rowDivider
                        settingsRow(icon: "command", title: "Command Mode") {
                            Toggle("", isOn: $settings.commandModeEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        rowDivider
                        settingsRow(icon: "square.and.arrow.down.on.square", title: "Bulk Import") {
                            Toggle("", isOn: $settings.bulkImportEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                }

                // SHORTCUTS
                settingsSection(title: "SHORTCUTS") {
                    settingsRow(icon: "keyboard", title: "Dictate") {
                        KeyboardShortcuts.Recorder(for: .toggleRecord)
                            .colorScheme(.dark)
                    }
                }

                // SOUND
                settingsSection(title: "SOUND") {
                    VStack(spacing: 0) {
                        settingsRow(icon: "speaker.wave.1", title: "Start Sound") {
                            Picker("", selection: $settings.startSound) {
                                ForEach(soundOptions, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)
                            .colorScheme(.dark)
                            .onChange(of: settings.startSound) { val in
                                if val != "None" { NSSound(named: val)?.play() }
                            }
                        }
                        rowDivider
                        settingsRow(icon: "speaker.wave.3", title: "Stop Sound") {
                            Picker("", selection: $settings.stopSound) {
                                ForEach(soundOptions, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)
                            .colorScheme(.dark)
                            .onChange(of: settings.stopSound) { val in
                                if val != "None" { NSSound(named: val)?.play() }
                            }
                        }
                    }
                }

                // MICROPHONE
                settingsSection(title: "MICROPHONE") {
                    MicrophonePickerRow(selectedID: $settings.selectedMicrophoneID)
                }

                // SYSTEM
                settingsSection(title: "SYSTEM") {
                    VStack(spacing: 0) {
                        settingsRow(icon: "power", title: "Launch at Login") {
                            Toggle("", isOn: $settings.launchAtLogin)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        rowDivider
                        settingsRow(icon: "dock.rectangle",
                                    title: "Show in Dock",
                                    subtitle: "Turn off to keep Hush notch only.") {
                            Toggle("", isOn: $settings.showInDock)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        rowDivider
                        settingsRow(icon: "menubar.rectangle", title: "Menu Bar Icon") {
                            Picker("", selection: $settings.menuBarIconStyle) {
                                Text("Default").tag("default")
                                Text("Monochrome").tag("monochrome")
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)
                            .colorScheme(.dark)
                        }
                    }
                }

                // SUPPORT
                settingsSection(title: "SUPPORT") {
                    Button(action: {
                        AppDelegate.shared.updaterController.checkForUpdates(nil)
                    }) {
                        settingsRow(icon: "arrow.down.circle", title: "Check for Updates") {
                            Image(systemName: "chevron.right")
                                .foregroundColor(.gray)
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                }

                // FOOTER
                VStack(spacing: 8) {
                    settingsSection(title: "") {
                        Button(action: { NSApplication.shared.terminate(nil) }) {
                            HStack {
                                Image(systemName: "power")
                                    .foregroundColor(.red)
                                    .frame(width: 22)
                                Text("Quit Hush")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.red)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("Hush \(version)")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Shared row helpers

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
            )
        }
    }

    private func settingsRow<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var rowDivider: some View {
        Divider()
            .background(Color(red: 0.18, green: 0.18, blue: 0.20))
            .padding(.leading, 46)
    }
}

// MARK: - Microphone Picker Row

private struct MicrophonePickerRow: View {
    @Binding var selectedID: String
    @State private var devices: [MicrophoneDevice] = []

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.gray)
                .frame(width: 22, alignment: .center)
            Text("Device")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            Picker("", selection: $selectedID) {
                Text("System default").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
            .colorScheme(.dark)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .onAppear {
            devices = AudioCaptureService.availableMicrophones()
        }
    }
}
