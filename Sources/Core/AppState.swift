import Foundation
import SwiftUI
import Combine
import AVFoundation

class AppState: ObservableObject {
    @Published var hudState: HUDState = .idle
    @Published var audioLevel: Float = 0.0
    
    let audioService = AudioCaptureService()
    let localService = LocalTranscriptionService()
    let ollamaService = OllamaCleanupService()
    private var cancellables = Set<AnyCancellable>()
    
    var isRecording: Bool {
        return hudState == .recording
    }
    
    init() {
        audioService.$audioLevel
            .receive(on: RunLoop.main)
            .assign(to: \.audioLevel, on: self)
            .store(in: &cancellables)
            
        // Prewarm the transcription model in the background so it's instantly ready
        localService.prewarm(modelSize: AppSettings.shared.whisperKitModelSize)
        
        // Listen for model changes to prewarm immediately
        AppSettings.shared.$whisperKitModelSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newModelSize in
                self?.localService.prewarm(modelSize: newModelSize)
            }
            .store(in: &cancellables)
    }
    
    func toggleRecording() {
        if hudState == .transcribing {
            // Ignore hotkey presses while already processing to prevent WhisperKit/CoreML deadlocks
            return
        }
        
        if audioService.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        // AppState isn't @MainActor-isolated, but every call site (hotkeys,
        // UI actions) already runs on the main thread; MeetingSession is
        // @MainActor, so the read needs an explicit isolation assertion to
        // type-check.
        if MainActor.assumeIsolated({ MeetingSession.shared.isRecording }) {
            hudState = .error("recording a meeting — stop it first")
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            do {
                // Play the start sound BEFORE opening the mic: opening the
                // input device reconfigures the audio route (drops Bluetooth
                // headphones into call mode), which mangles a sound that is
                // still playing. It also keeps the bloop out of the recording.
                if AppSettings.shared.startSound != "None" {
                    NSSound(named: AppSettings.shared.startSound)?.play()
                }
                try audioService.startRecording()
                self.hudState = .recording
            } catch {
                self.hudState = .error("Failed to start recording")
            }
        } else {
            Task {
                let hasPermission = await audioService.checkPermission()
                if hasPermission {
                    DispatchQueue.main.async { self.startRecording() }
                } else {
                    DispatchQueue.main.async { self.hudState = .error("No microphone access") }
                }
            }
        }
    }
    
    func stopRecording() {
        guard let result = audioService.stopRecording() else {
            // No audio ever arrived (mic still opening, or a dead Bluetooth
            // take). Without this reset the HUD stays on "recording" forever
            // and the app looks frozen.
            self.hudState = .idle
            return
        }
        
        if result.duration < 0.3 {
            self.hudState = .idle
            return
        }
        
        if AppSettings.shared.stopSound != "None" {
            NSSound(named: AppSettings.shared.stopSound)?.play()
        }
        
        self.hudState = .transcribing
        
        Task {
            do {
                let language = AppSettings.shared.primaryLanguage
                let localModel = AppSettings.shared.whisperKitModelSize
                let rawText = try await localService.transcribe(fileURL: result.url, modelSize: localModel, language: language)
                
                // --- Whisper Hallucination Filter ---
                var cleanedRawText = rawText
                // Strip out common Whisper bracket/parenthesis tags like [BLANK_AUDIO], (Music playing), etc.
                if let regex = try? NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)", options: []) {
                    cleanedRawText = regex.stringByReplacingMatches(in: cleanedRawText, options: [], range: NSRange(location: 0, length: cleanedRawText.utf16.count), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                let lowerText = cleanedRawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "!", with: "").replacingOccurrences(of: "?", with: "")
                let hallucinations = [
                    "thank you", "thank you for watching", "thanks for watching", "subscribe", 
                    "subscribe to the channel", "subscribe to my channel", "amém", "amem", 
                    "bye", "you", "thanks", "blank audio", "silence", "music", "music playing", ""
                ]
                
                if hallucinations.contains(lowerText) || (result.duration < 0.5 && lowerText.count < 10) || cleanedRawText.isEmpty {
                    DispatchQueue.main.async { self.hudState = .idle }
                    return
                }
                // ------------------------------------
                
                var finalText = cleanedRawText
                var showOllamaWarning = false
                
                if AppSettings.shared.aiCleanupEnabled {
                    let ollamaModel = AppSettings.shared.ollamaModelName
                    do {
                        finalText = try await ollamaService.cleanup(text: rawText, modelName: ollamaModel)
                    } catch OllamaCleanupService.OllamaError.notRunning {
                        showOllamaWarning = true
                    }
                }
                
                // Press Enter Command
                var shouldPressEnter = false
                if AppSettings.shared.pressEnterEnabled {
                    let enterTriggers = ["press enter", "hit enter", "click enter", "send message"]
                    let lowerText = finalText.lowercased()
                    
                    for trigger in enterTriggers {
                        if let range = lowerText.range(of: trigger + "[\\.\\!\\?]*$", options: .regularExpression) {
                            let matchedLength = lowerText.distance(from: range.lowerBound, to: lowerText.endIndex)
                            finalText = String(finalText.dropLast(matchedLength)).trimmingCharacters(in: .whitespacesAndNewlines)
                            shouldPressEnter = true
                            break
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    HistoryStore.shared.add(rawText: rawText, cleanedText: finalText, duration: result.duration)
                    
                    // Paste
                    if PasteService.isAccessibilityEnabled() {
                        PasteService.paste(text: finalText, simulateReturn: shouldPressEnter)
                    } else {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(finalText, forType: .string)
                        
                        // Notify user why it didn't paste
                        let script = "display notification \"Please enable Accessibility in System Settings for Hush to auto-paste.\" with title \"Transcription Copied to Clipboard\""
                        var error: NSDictionary?
                        if let appleScript = NSAppleScript(source: script) {
                            appleScript.executeAndReturnError(&error)
                        }
                    }
                    
                    if showOllamaWarning {
                        self.hudState = .error("Ollama not detected — raw transcription pasted.")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if case .error = self.hudState {
                                self.hudState = .idle
                            }
                        }
                    } else {
                        self.hudState = .idle
                    }
                }
                
            } catch {
                DispatchQueue.main.async {
                    let errStr = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.hudState = .error("Failed: \(errStr)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.hudState = .idle
                    }
                }
            }
        }
    }
}
