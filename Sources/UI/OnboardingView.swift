import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @StateObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var micPermissionGranted = false
    @State private var axPermissionGranted = false
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "mic.fill")
                .font(.system(size: 64))
                .foregroundColor(.blue)
                .padding(.top, 40)
            
            Text("Welcome to Hush")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Privacy-first voice dictation.")
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 20) {
                // Mic permission
                HStack {
                    Image(systemName: micPermissionGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(micPermissionGranted ? .green : .secondary)
                    
                    VStack(alignment: .leading) {
                        Text("Microphone Access")
                            .fontWeight(.medium)
                        Text("Required to record your voice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !micPermissionGranted {
                        Button("Request") {
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                DispatchQueue.main.async {
                                    micPermissionGranted = granted
                                }
                            }
                        }
                    }
                }
                
                // Accessibility permission
                HStack {
                    Image(systemName: axPermissionGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(axPermissionGranted ? .green : .secondary)
                    
                    VStack(alignment: .leading) {
                        Text("Accessibility Permissions")
                            .fontWeight(.medium)
                        Text("Required to automatically paste text into other apps.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !axPermissionGranted {
                        Button("Request") {
                            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String : true]
                            let accessEnabled = AXIsProcessTrustedWithOptions(options)
                            axPermissionGranted = accessEnabled
                            if !accessEnabled {
                                // Keep checking periodically
                                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                                    if AXIsProcessTrusted() {
                                        axPermissionGranted = true
                                        timer.invalidate()
                                    }
                                }
                            }
                        }
                    }
                }
                
                // AI Cleanup
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Text Cleanup (Optional)")
                        .fontWeight(.medium)
                    
                    Text("For AI text cleanup, install Ollama from ollama.com, then run 'ollama pull llama3.2:3b' in Terminal. The app works perfectly without it, you'll just get the raw transcription.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Link("Open ollama.com", destination: URL(string: "https://ollama.com")!)
                        .font(.caption)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 40)
            
            Spacer()
            
            Button("Get Started") {
                settings.hasCompletedOnboarding = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!micPermissionGranted)
            .padding(.bottom, 40)
        }
        .onAppear {
            checkPermissions()
        }
    }
    
    private func checkPermissions() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axPermissionGranted = AXIsProcessTrusted()
    }
}
