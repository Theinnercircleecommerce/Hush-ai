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
    case home, settings, history, dictionary, snippets, insights, scratchpad

    var title: String {
        switch self {
        case .home: return "Home"
        case .settings: return "Settings"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .insights: return "Insights"
        case .scratchpad: return "Scratchpad"
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
    @State private var newWord = ""
    @State private var newTrigger = ""
    @State private var newReplacement = ""
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
                pageLayer(scratchpadView, for: .scratchpad)
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
                // Scratchpad is entered from Settings, so back returns there.
                Button(action: { navigate(to: page == .scratchpad ? .settings : .home) }) {
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

    private var dictionaryView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Custom words, names and technical terms that improve transcription accuracy.")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    TextField("Add a word or phrase…", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .colorScheme(.dark)
                        .onSubmit(addWord)
                    Button(action: addWord) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.22, green: 0.22, blue: 0.24)))
                    }
                    .buttonStyle(.plain)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if history.dictionaryItems.isEmpty {
                    emptyState(icon: "character.book.closed", text: "No words yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.dictionaryItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { rowDivider }
                            HStack {
                                Text(item.word)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                                Spacer()
                                Button(action: { history.deleteDictionaryItem(item) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(red: 0.55, green: 0.35, blue: 0.35))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
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

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        history.addDictionaryItem(DictionaryItem(word: trimmed))
        newWord = ""
    }

    private var snippetsView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Voice shortcuts. Say the trigger phrase, get the replacement text.")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 4)

                VStack(spacing: 8) {
                    TextField("Trigger (e.g. 'insert email')", text: $newTrigger)
                        .textFieldStyle(.roundedBorder)
                        .colorScheme(.dark)
                    HStack(spacing: 8) {
                        TextField("Replacement", text: $newReplacement)
                            .textFieldStyle(.roundedBorder)
                            .colorScheme(.dark)
                            .onSubmit(addSnippet)
                        Button(action: addSnippet) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(red: 0.22, green: 0.22, blue: 0.24)))
                        }
                        .buttonStyle(.plain)
                        .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if history.snippets.isEmpty {
                    emptyState(icon: "scissors", text: "No snippets yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.snippets.enumerated()), id: \.element.id) { index, snippet in
                            if index > 0 { rowDivider }
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.trigger)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(snippet.replacement)
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                Button(action: { history.deleteSnippet(snippet) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color(red: 0.55, green: 0.35, blue: 0.35))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
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

    private func addSnippet() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !replacement.isEmpty else { return }
        history.addSnippet(Snippet(trigger: trigger, replacement: replacement))
        newTrigger = ""
        newReplacement = ""
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

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.32))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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

                // NOTES
                settingsSection(title: "NOTES") {
                    Button(action: { navigate(to: .scratchpad) }) {
                        settingsRow(icon: "note.text", title: "Scratchpad",
                                    subtitle: "Quick notes, saved automatically.") {
                            Image(systemName: "chevron.right")
                                .foregroundColor(.gray)
                                .font(.system(size: 12))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
