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
            case .settings: settingsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.05))
        )
        .ignoresSafeArea()
    }

    // MARK: - Top Bar

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

    // MARK: - Home View

    private var wordsTodayText: String {
        let calendar = Calendar.current
        let count = HistoryStore.shared.records
            .filter { calendar.isDateInToday($0.timestamp) }
            .reduce(0) { $0 + $1.wordCount }
        return "\(count)"
    }

    private var streakText: String {
        let calendar = Calendar.current
        let uniqueDays = Set(HistoryStore.shared.records.map {
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
                    statCard(title: "words today", value: wordsTodayText)
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

    // MARK: - Settings View (filled in Task 3)

    private var settingsView: some View {
        Text("Settings coming in Task 3")
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
