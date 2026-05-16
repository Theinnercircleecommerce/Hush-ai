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
            
            Text("Privacy-first voice dictation using Groq.")
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
                
                // API Key
                VStack(alignment: .leading, spacing: 8) {
                    Text("Groq API Key")
                        .fontWeight(.medium)
                    
                    SecureField("Paste your API key here", text: $settings.groqAPIKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    HStack {
                        Link("Get a free API key at console.groq.com", destination: URL(string: "https://console.groq.com/keys")!)
                            .font(.caption)
                    }
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
            .disabled(settings.groqAPIKey.isEmpty || !micPermissionGranted)
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
