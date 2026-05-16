import SwiftUI
import KeyboardShortcuts

enum HUDState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}

struct WaveformView: View {
    var level: Float
    
    // Smooth transitions for the 9 bars
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<9) { index in
                Capsule()
                    .fill(Color.orange)
                    // The middle bars are taller, the outer bars are shorter
                    .frame(width: 3, height: calculateHeight(for: index))
                    .animation(.spring(response: 0.15, dampingFraction: 0.6), value: level)
            }
        }
    }
    
    private func calculateHeight(for index: Int) -> CGFloat {
        // Base idle height
        let baseHeight: CGFloat = 6.0
        
        // Calculate a nice curve where the center is highest
        let center = 4.0
        let distance = abs(CGFloat(index) - center)
        
        // Max height for the center bar, decreasing outwards
        let maxHeight: CGFloat = 32.0
        let attenuation = max(0, 1.0 - (distance * 0.25))
        
        // Randomize slightly to make it feel alive even when quiet
        let randomFactor = CGFloat.random(in: 0.8...1.2)
        
        // Give it a minimum "jiggle" when active so it never looks frozen
        let activeLevel = max(CGFloat(level), 0.15)
        
        let calculated = baseHeight + (activeLevel * maxHeight * attenuation * randomFactor)
        return min(max(baseHeight, calculated), 45.0)
    }
}

struct HUDView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        // Use a ZStack to ensure elements absolutely never push each other off-center
        ZStack {
            switch appState.hudState {
            case .idle:
                // Wispr-style tiny dark idle pill
                Capsule()
                    .fill(Color(white: 0.08)) // Very dark gray/black fill
                    .frame(width: 28, height: 6) // Significantly smaller to match Wispr's exact size
                    .overlay(
                        Capsule()
                            .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                
            case .recording:
                // Black pill with orange waveform
                HStack(spacing: 0) {
                    WaveformView(level: appState.audioLevel)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(height: 50)
                .background(
                    Capsule()
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                )
                
            case .transcribing:
                // Flat waveform dots + orange loading spinner
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(0..<9) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.gray.opacity(0.6))
                                .frame(width: 3, height: 3)
                        }
                    }
                    
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                        .scaleEffect(0.6)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(height: 50)
                .background(
                    Capsule()
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                )
                
            case .error(let msg):
                Text(msg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.9))
                    )
            }
        }
        .frame(width: 250, height: 60, alignment: .center)
        // Completely removed the state animation so they never overlap or slide sideways
    }
}

struct HotkeyString {
    static var current: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecord) {
            return shortcut.description
        }
        return "⇧A"
    }
}
