import SwiftUI

struct ScratchpadView: View {
    @StateObject private var settings = AppSettings.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Scratchpad")
                .font(.largeTitle)
                .fontDesign(.serif)
            
            Text("A simple space for quick notes. Saved automatically.")
                .foregroundColor(.secondary)
            
            TextEditor(text: $settings.scratchpadText)
                .font(.body)
                .padding()
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
        .padding()
    }
}
