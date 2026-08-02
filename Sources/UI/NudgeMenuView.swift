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
    case home, agents, settings, history, insights, scratchpad

    var title: String {
        switch self {
        case .home: return "Home"
        case .agents: return "Agents"
        case .settings: return "Settings"
        case .history: return "History"
        case .insights: return "Insights"
        case .scratchpad: return "Scratchpad"
        }
    }

    var panelSize: CGSize {
        switch self {
        case .home: return NudgeMenuLayout.homeSize
        case .agents: return NudgeMenuLayout.homeSize
        case .settings: return NudgeMenuLayout.settingsSize
        default: return NudgeMenuLayout.subpageSize
        }
    }
}

// MARK: - Shortcut Entry

struct ShortcutEntry: Identifiable {
    var id: String { name }
    let name: String
    let keys: [String]        // e.g. ["fn", "⌃"] rendered as keycaps
    let subtitle: String?     // optional, e.g. "hold and speak"
    let enabled: Bool         // false → grayed "coming soon" row
}

struct NudgeMenuView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared
    @State private var page: NudgePage = .home
    @State private var expanded = false
    @State private var collapsedSize = CGSize(width: 260, height: 16)
    var onClose: () -> Void

    /// All grow/shrink motion lives HERE as SwiftUI springs. The window is
    /// fixed-size; animating its frame re-layouts the hosting view every
    /// frame and stutters — this doesn't.
    var body: some View {
        let size = expanded ? page.panelSize : collapsedSize
        return ZStack(alignment: .top) {
            VStack(spacing: 0) {
                panelHeader
                // Every page stays mounted so navigation is instant — same
                // stuck-proof pattern NudgeView uses for its states.
                ZStack(alignment: .top) {
                    pageLayer(homeView, for: .home)
                    pageLayer(agentsPlaceholderView, for: .agents)
                    pageLayer(settingsView, for: .settings)
                    pageLayer(historyView, for: .history)
                    pageLayer(insightsView, for: .insights)
                    pageLayer(scratchpadView, for: .scratchpad)
                }
                .animation(.easeOut(duration: 0.18), value: page)
            }
            // Content laid out at full page size ALWAYS — the collapse only
            // clips it, so nothing re-flows during the open/close spring.
            .frame(width: page.panelSize.width, height: page.panelSize.height, alignment: .top)
            .opacity(expanded ? 1 : 0)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(
                NudgeNotchShape(topCornerRadius: 10, bottomCornerRadius: 24)
                    .fill(Color(red: 0.05, green: 0.05, blue: 0.05))
            )
            .clipShape(NudgeNotchShape(topCornerRadius: 10, bottomCornerRadius: 24))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("NudgeMenuWillOpen"))) { note in
            if let w = note.userInfo?["width"] as? CGFloat,
               let h = note.userInfo?["height"] as? CGFloat {
                collapsedSize = CGSize(width: w, height: h)
            }
            page = .home
            expanded = false
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    expanded = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("NudgeMenuWillClose"))) { _ in
            withAnimation(.easeIn(duration: 0.2)) {
                expanded = false
            }
        }
    }

    private func pageLayer<C: View>(_ content: C, for target: NudgePage) -> some View {
        content
            .opacity(page == target ? 1 : 0)
            .allowsHitTesting(page == target)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 0) {
            if page == .home || page == .agents {
                // Tab bar: Home | Agents on the left, gear on the right
                HStack(spacing: 4) {
                    tabButton(label: "Home", icon: "house.fill", target: .home)
                    tabButton(label: "Agents", icon: "sparkles", target: .agents)
                }
                Spacer()
                Button(action: { navigate(to: .settings) }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            } else {
                // Sub-pages: back chevron + page title
                Button(action: { navigate(to: page == .settings ? .home : .settings) }) {
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

    private func tabButton(label: String, icon: String, target: NudgePage) -> some View {
        let isSelected = page == target
        return Button(action: { navigate(to: target) }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : Color(red: 0.5, green: 0.5, blue: 0.52))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? Color(red: 0.18, green: 0.18, blue: 0.20)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func navigate(to newPage: NudgePage) {
        guard newPage != page else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            page = newPage
        }
        // Window never moves — this only updates hover/click hit-testing.
        NudgeMenuController.shared.resize(to: newPage.panelSize)
    }

    // MARK: - Home

    /// Derive keycap labels from the current hotkey string.
    /// The shortcut description typically looks like "⌃⌥A" — we split on
    /// character boundaries so modifier symbols become individual chips.
    private func hotkeyKeycaps() -> [String] {
        let raw = HotkeyString.current
        // Known modifier prefixes to split out as individual keycaps
        let modifiers: [String] = ["⇧", "⌃", "⌥", "⌘", "fn"]
        var remaining = raw
        var caps: [String] = []
        // Greedily strip recognised modifier symbols from the front
        var changed = true
        while changed {
            changed = false
            for mod in modifiers {
                if remaining.hasPrefix(mod) {
                    caps.append(mod)
                    remaining = String(remaining.dropFirst(mod.count))
                    changed = true
                    break
                }
            }
        }
        // Whatever is left is the key (e.g. "A", "Space")
        if !remaining.isEmpty {
            caps.append(remaining)
        }
        // Fallback: if nothing parsed sensibly, return the whole string as one cap
        return caps.isEmpty ? [raw] : caps
    }

    private var shortcutEntries: [ShortcutEntry] {
        [
            ShortcutEntry(name: "Dictate", keys: hotkeyKeycaps(),
                          subtitle: "hold and speak", enabled: true),
            ShortcutEntry(name: "Hands-free", keys: hotkeyKeycaps() + ["2×"],
                          subtitle: "double-tap to toggle", enabled: true),
            ShortcutEntry(name: "Talk", keys: ["⌃", "⌥"],
                          subtitle: "coming soon", enabled: false),
            ShortcutEntry(name: "Text", keys: ["⌃", "2×"],
                          subtitle: "coming soon", enabled: false),
        ]
    }

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⌘ Shortcuts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gray)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(shortcutEntries) { entry in
                    shortcutEntryRow(entry)
                    if entry.id != shortcutEntries.last?.id { rowDivider }
                }
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

    private func shortcutEntryRow(_ entry: ShortcutEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(entry.enabled ? .white : Color(red: 0.5, green: 0.5, blue: 0.52))
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                }
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(entry.keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(entry.enabled
                                         ? .white
                                         : Color(red: 0.45, green: 0.45, blue: 0.45))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(red: 0.20, green: 0.20, blue: 0.22))
                        )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

    // MARK: - Agents (placeholder — wired in Task 2)

    private var agentsPlaceholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.32))
            Text("Agents live here soon")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("Hush agents will do tasks for you in the background — coming in a future update.")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .padding(.horizontal, 18)
    }

    // MARK: - Sub-pages (filled in Tasks 2–3)

    /// Recent transcriptions bucketed into TODAY / YESTERDAY / date, newest
    /// first. `records` is already ordered timestamp-desc by the store.
    private var groupedRecords: [(String, [TranscriptionRecord])] {
        let calendar = Calendar.current
        let recent = Array(history.records.prefix(60))
        let dict = Dictionary(grouping: recent) { record -> String in
            if calendar.isDateInToday(record.timestamp) { return "TODAY" }
            if calendar.isDateInYesterday(record.timestamp) { return "YESTERDAY" }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: record.timestamp).uppercased()
        }
        return dict.sorted {
            let d1 = $0.value.first?.timestamp ?? Date.distantPast
            let d2 = $1.value.first?.timestamp ?? Date.distantPast
            return d1 > d2
        }
    }

    private var historyView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if groupedRecords.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "mic.slash")
                            .font(.system(size: 26))
                            .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.32))
                        Text("No transcriptions yet")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                } else {
                    ForEach(groupedRecords, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                                .padding(.leading, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(group.1.enumerated()), id: \.element.id) { index, record in
                                    if index > 0 { rowDivider }
                                    historyRow(record)
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                            )
                        }
                    }

                    Button(action: { showClearAllAlert() }) {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .frame(width: 22)
                            Text("Clear all history")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func historyRow(_ record: TranscriptionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.cleanedTranscript)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(record.timestamp, style: .time) · \(record.wordCount) words")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            Spacer(minLength: 4)
            Button(action: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(record.cleanedTranscript, forType: .string)
            }) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .help("Copy")
            Button(action: { history.delete(record: record) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.55, green: 0.35, blue: 0.35))
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func showClearAllAlert() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This permanently deletes every saved transcription."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            history.clearAll()
        }
    }

    // MARK: - Insights

    private var totalWords: Int {
        history.records.reduce(0) { $0 + $1.wordCount }
    }

    private var averageWPM: Int {
        let totalDuration = history.records.reduce(0) { $0 + $1.duration }
        if totalDuration == 0 { return 0 }
        return Int(Double(totalWords) / (totalDuration / 60.0))
    }

    private var mostActiveHour: String {
        let calendar = Calendar.current
        var hourCounts: [Int: Int] = [:]
        for record in history.records {
            let hour = calendar.component(.hour, from: record.timestamp)
            hourCounts[hour, default: 0] += 1
        }
        guard let max = hourCounts.max(by: { $0.value < $1.value }) else { return "—" }
        let ampm = max.key < 12 ? "AM" : "PM"
        let h = max.key % 12 == 0 ? 12 : max.key % 12
        return "\(h) \(ampm)"
    }

    /// Words per day for the last 14 days, oldest → newest.
    private var wordsPerDay: [(date: Date, count: Int)] {
        let calendar = Calendar.current
        var dict: [Date: Int] = [:]
        for i in 0..<14 {
            let d = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -i, to: Date())!)
            dict[d] = 0
        }
        for record in history.records {
            let d = calendar.startOfDay(for: record.timestamp)
            if dict[d] != nil { dict[d, default: 0] += record.wordCount }
        }
        return dict.map { (date: $0.key, count: $0.value) }.sorted { $0.date < $1.date }
    }

    private var insightsView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    insightCard(title: "total words", value: "\(totalWords)")
                    insightCard(title: "avg WPM", value: "\(averageWPM)")
                }
                HStack(spacing: 10) {
                    insightCard(title: "day streak", value: streakText)
                    insightCard(title: "peak hour", value: mostActiveHour)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("LAST 14 DAYS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
                        .padding(.leading, 4)
                    barChart
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var barChart: some View {
        let data = wordsPerDay
        let peak = max(data.map(\.count).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(data, id: \.date) { item in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(item.count > 0
                                  ? Color(red: 0.35, green: 0.55, blue: 0.95)
                                  : Color(red: 0.18, green: 0.18, blue: 0.20))
                            .frame(height: max(3, CGFloat(item.count) / CGFloat(peak) * 90))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(item.count) words")
                }
            }
            .frame(height: 90)
            HStack {
                Text("\(peak) peak")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                Spacer()
                Text("today")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
    }

    private func insightCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
        )
    }

    private var scratchpadView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick notes. Saved automatically as you type.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .padding(.horizontal, 4)
            TextEditor(text: $settings.scratchpadText)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                )
                .colorScheme(.dark)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

                // LIBRARY
                settingsSection(title: "LIBRARY") {
                    VStack(spacing: 0) {
                        navRow(icon: "clock", title: "History", page: .history)
                        rowDivider
                        navRow(icon: "chart.bar", title: "Insights", page: .insights)
                        rowDivider
                        navRow(icon: "note.text", title: "Scratchpad", page: .scratchpad)
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
