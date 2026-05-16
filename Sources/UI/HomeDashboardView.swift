import SwiftUI

struct HomeDashboardView: View {
    @StateObject private var historyStore = HistoryStore.shared
    @StateObject private var settings = AppSettings.shared
    
    var wordsToday: Int {
        let calendar = Calendar.current
        return historyStore.records.filter { calendar.isDateInToday($0.timestamp) }
            .reduce(0) { $0 + $1.wordCount }
    }
    
    var totalWords: Int {
        historyStore.records.reduce(0) { $0 + $1.wordCount }
    }
    
    var averageWPM: Int {
        let totalDuration = historyStore.records.reduce(0) { $0 + $1.duration }
        if totalDuration == 0 { return 0 }
        return Int(Double(totalWords) / (totalDuration / 60.0))
    }
    
    var dayStreak: Int {
        let calendar = Calendar.current
        let uniqueDays = Set(historyStore.records.map { calendar.startOfDay(for: $0.timestamp) }).sorted(by: >)
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
        return streak
    }
    
    var groupedRecords: [(String, [TranscriptionRecord])] {
        let calendar = Calendar.current
        let dict = Dictionary(grouping: historyStore.records) { record -> String in
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
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Main Timeline
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        // Header
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Overview")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                Text("Your dictation history and activity")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.top, 24)
                        .padding(.horizontal, 32)
                        
                        // Top Stats Row
                        HStack(spacing: 16) {
                            ModernStatCard(title: "Words Today", value: "\(wordsToday)", icon: "text.word.spacing", color: .blue)
                            ModernStatCard(title: "Total Words", value: "\(totalWords)", icon: "doc.text.fill", color: .purple)
                            ModernStatCard(title: "Average WPM", value: "\(averageWPM)", icon: "bolt.fill", color: .orange)
                            ModernStatCard(title: "Day Streak", value: "\(dayStreak)", icon: "flame.fill", color: .red)
                        }
                        .padding(.horizontal, 32)
                        
                        // Timeline
                        VStack(alignment: .leading, spacing: 24) {
                            Text("Recent Transcriptions")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 32)
                            
                            if groupedRecords.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "mic.slash")
                                        .font(.system(size: 40))
                                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                    Text("No transcriptions yet. Start dictating!")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 60)
                            } else {
                                ForEach(groupedRecords, id: \.0) { group in
                                    VStack(alignment: .leading, spacing: 16) {
                                        Text(group.0)
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 32)
                                        
                                        VStack(spacing: 12) {
                                            ForEach(group.1) { record in
                                                TranscriptionRecordRow(record: record)
                                            }
                                        }
                                        .padding(.horizontal, 32)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 40)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                
                Divider()
                    .ignoresSafeArea()
                
                // Right Sidebar Stats Panel
                VStack(spacing: 24) {
                    Text("Daily Challenge")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Circular Progress
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 12)
                        
                        let progress = min(Double(wordsToday) / Double(max(settings.dailyWordGoal, 1)), 1.0)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                LinearGradient(colors: [.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 12, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.8, dampingFraction: 0.7), value: progress)
                        
                        VStack(spacing: 4) {
                            Image(systemName: "target")
                                .font(.system(size: 24))
                                .foregroundColor(.accentColor)
                            Text("\(wordsToday)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text("of \(settings.dailyWordGoal)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 160, height: 160)
                    .padding(.vertical, 10)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Motivation")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        Text(motivationMessage(words: wordsToday, goal: settings.dailyWordGoal))
                            .font(.body)
                            .italic()
                            .foregroundColor(.primary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                    }
                    
                    Spacer()
                }
                .padding(24)
                .frame(width: 280)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
    }
    
    private func motivationMessage(words: Int, goal: Int) -> String {
        let progress = Double(words) / Double(max(goal, 1))
        if progress == 0 { return "Time to start speaking your mind!" }
        if progress < 0.5 { return "Great start! Keep those words flowing." }
        if progress < 1.0 { return "You're more than halfway there!" }
        return "Goal crushed! You're on fire today! 🔥"
    }
}

struct ModernStatCard: View {
    var title: String
    var value: String
    var icon: String
    var color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(color)
                }
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct TranscriptionRecordRow: View {
    var record: TranscriptionRecord
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.timestamp, style: .time)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                Text("\(record.wordCount) w")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(width: 65, alignment: .trailing)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(record.cleanedTranscript)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(.primary)
                    .lineSpacing(4)
            }
            Spacer(minLength: 0)
            
            Button(action: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(record.cleanedTranscript, forType: .string)
            }) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
            .help("Copy transcription")
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }
}
