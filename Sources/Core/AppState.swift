import Foundation
import SwiftUI
import Combine
import AVFoundation

class AppState: ObservableObject {
    @Published var hudState: HUDState = .idle
    @Published var audioLevel: Float = 0.0
    
    let audioService = AudioCaptureService()
    let groqService = GroqTranscriptionService()
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
    }
    
    func toggleRecording() {
        if audioService.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            do {
                try audioService.startRecording()
                if AppSettings.shared.startSound != "None" {
                    NSSound(named: AppSettings.shared.startSound)?.play()
                }
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
        guard let result = audioService.stopRecording() else { return }
        
        if result.duration < 0.3 {
            self.hudState = .idle
            return
        }
        
        if AppSettings.shared.stopSound != "None" {
            NSSound(named: AppSettings.shared.stopSound)?.play()
        }
        
        self.hudState = .transcribing
        
        let dictionaryWords = HistoryStore.shared.dictionaryItems.map { $0.word }.joined(separator: ", ")
        let snippets = HistoryStore.shared.snippets
        
        Task {
            do {
                let apiKey = AppSettings.shared.groqAPIKey
                let model = AppSettings.shared.whisperModel
                let language = AppSettings.shared.primaryLanguage
                
                let rawText: String
                if AppSettings.shared.processingMode == "Cloud (Groq)" {
                    rawText = try await groqService.transcribe(fileURL: result.url, apiKey: apiKey, model: model, prompt: dictionaryWords, language: language)
                } else {
                    let localModel = AppSettings.shared.whisperKitModelSize
                    rawText = try await localService.transcribe(fileURL: result.url, modelSize: localModel, prompt: dictionaryWords, language: language)
                }
                
                // --- Whisper Hallucination Filter ---
                let lowerText = rawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "!", with: "").replacingOccurrences(of: "?", with: "")
                let hallucinations = [
                    "thank you", "thank you for watching", "thanks for watching", "subscribe", 
                    "subscribe to the channel", "subscribe to my channel", "amém", "amem", 
                    "bye", "you", "thanks", ""
                ]
                
                if hallucinations.contains(lowerText) || (result.duration < 0.5 && lowerText.count < 10) {
                    DispatchQueue.main.async { self.hudState = .idle }
                    return
                }
                // ------------------------------------
                
                var finalText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                var showOllamaWarning = false
                
                if AppSettings.shared.aiCleanupEnabled {
                    if AppSettings.shared.processingMode == "Cloud (Groq)" {
                        finalText = try await groqService.cleanup(text: rawText, apiKey: apiKey)
                    } else {
                        let ollamaModel = AppSettings.shared.ollamaModelName
                        do {
                            finalText = try await ollamaService.cleanup(text: rawText, modelName: ollamaModel)
                        } catch OllamaCleanupService.OllamaError.notRunning {
                            showOllamaWarning = true
                        }
                    }
                }
                
                // Apply snippets
                for snippet in snippets {
                    // Simple case-insensitive replacement
                    finalText = finalText.replacingOccurrences(of: snippet.trigger, with: snippet.replacement, options: .caseInsensitive)
                }
                
                // Press Enter Command
                var shouldPressEnter = false
                if AppSettings.shared.pressEnterEnabled {
                    let enterTriggers = ["press enter", "hit enter", "send message"]
                    let lowerText = finalText.lowercased()
                    for trigger in enterTriggers {
                        if lowerText.hasSuffix(trigger) || lowerText.hasSuffix(trigger + ".") {
                            let suffixLength = lowerText.hasSuffix(trigger + ".") ? trigger.count + 1 : trigger.count
                            finalText = String(finalText.dropLast(suffixLength)).trimmingCharacters(in: .whitespacesAndNewlines)
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
