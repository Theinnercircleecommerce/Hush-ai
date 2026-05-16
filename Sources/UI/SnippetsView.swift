import SwiftUI

struct SnippetsView: View {
    @StateObject private var historyStore = HistoryStore.shared
    @State private var newTrigger = ""
    @State private var newReplacement = ""
    @State private var searchText = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Snippets")
                .font(.largeTitle)
                .fontDesign(.serif)
            
            Text("Voice shortcuts. Define a trigger phrase and its replacement text.")
                .foregroundColor(.secondary)
            
            HStack {
                TextField("Trigger (e.g. 'insert email')", text: $newTrigger)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                TextField("Replacement (e.g. 'john@example.com')", text: $newReplacement)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Add") {
                    let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
                    let replacement = newReplacement.trimmingCharacters(in: .whitespaces)
                    if !trigger.isEmpty && !replacement.isEmpty {
                        historyStore.addSnippet(Snippet(trigger: trigger, replacement: replacement))
                        newTrigger = ""
                        newReplacement = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            
            List {
                ForEach(historyStore.snippets.filter { searchText.isEmpty || $0.trigger.localizedCaseInsensitiveContains(searchText) || $0.replacement.localizedCaseInsensitiveContains(searchText) }) { snippet in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snippet.trigger)
                                .font(.headline)
                            Text(snippet.replacement)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            historyStore.deleteSnippet(snippet)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
            }
            .searchable(text: $searchText, prompt: "Search snippets...")
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
        .padding()
    }
}
