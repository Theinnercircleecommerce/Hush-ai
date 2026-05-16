import SwiftUI

struct DictionaryView: View {
    @StateObject private var historyStore = HistoryStore.shared
    @State private var newWord = ""
    @State private var searchText = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dictionary")
                .font(.largeTitle)
                .fontDesign(.serif)
            
            Text("Add custom words, names, and technical terms to improve transcription accuracy.")
                .foregroundColor(.secondary)
            
            HStack {
                TextField("Add a new word or phrase...", text: $newWord)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Add") {
                    let trimmed = newWord.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        historyStore.addDictionaryItem(DictionaryItem(word: trimmed))
                        newWord = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            
            List {
                ForEach(historyStore.dictionaryItems.filter { searchText.isEmpty || $0.word.localizedCaseInsensitiveContains(searchText) }) { item in
                    HStack {
                        Text(item.word)
                            .font(.body)
                        Spacer()
                        Button(action: {
                            historyStore.deleteDictionaryItem(item)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
            }
            .searchable(text: $searchText, prompt: "Search dictionary...")
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
        .padding()
    }
}
