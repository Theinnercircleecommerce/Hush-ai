import SwiftUI
import Charts

struct InsightsView: View {
    @StateObject private var historyStore = HistoryStore.shared
    
    var wordsPerDay: [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: Date())!
        
        var dict: [Date: Int] = [:]
        for i in 0..<30 {
            let d = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -i, to: Date())!)
            dict[d] = 0
        }
        
        for record in historyStore.records where record.timestamp >= thirtyDaysAgo {
            let d = calendar.startOfDay(for: record.timestamp)
            dict[d, default: 0] += record.wordCount
        }
        
        return dict.map { (date: $0.key, count: $0.value) }.sorted { $0.date < $1.date }
    }
    
    var mostActiveHour: String {
        let calendar = Calendar.current
        var hourCounts: [Int: Int] = [:]
        for record in historyStore.records {
            let hour = calendar.component(.hour, from: record.timestamp)
            hourCounts[hour, default: 0] += 1
        }
        
        if let max = hourCounts.max(by: { $0.value < $1.value }) {
            let ampm = max.key < 12 ? "AM" : "PM"
            let h = max.key % 12 == 0 ? 12 : max.key % 12
            return "\(h) \(ampm)"
        }
        return "N/A"
    }
    
    var totalTranscriptions: Int {
        historyStore.records.count
    }
    
    var avgWordsPerTranscription: Int {
        if totalTranscriptions == 0 { return 0 }
        let totalWords = historyStore.records.reduce(0) { $0 + $1.wordCount }
        return totalWords / totalTranscriptions
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Insights")
                    .font(.largeTitle)
                    .fontDesign(.serif)
                
                HStack(spacing: 20) {
                    InsightCard(title: "Total Transcriptions", value: "\(totalTranscriptions)")
                    InsightCard(title: "Avg Words / Transcription", value: "\(avgWordsPerTranscription)")
                    InsightCard(title: "Most Active Hour", value: mostActiveHour)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("Words Per Day (Last 30 Days)")
                        .font(.title2)
                        .fontDesign(.serif)
                    
                    Chart {
                        ForEach(wordsPerDay, id: \.date) { item in
                            BarMark(
                                x: .value("Date", item.date, unit: .day),
                                y: .value("Words", item.count)
                            )
                            .foregroundStyle(Color.accentColor.gradient)
                        }
                    }
                    .frame(height: 300)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
    }
}

struct InsightCard: View {
    var title: String
    var value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 32, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}
