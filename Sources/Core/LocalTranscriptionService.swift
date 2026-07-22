import Foundation
import WhisperKit

class LocalTranscriptionService {
    private var whisperKitTask: Task<WhisperKit, Error>?
    private var currentModelSize: String = ""
    
    enum LocalTranscriptionError: LocalizedError {
        case initializationFailed(String)
        case fileReadFailed
        
        var errorDescription: String? {
            switch self {
            case .initializationFailed(let msg): return "Failed to initialize WhisperKit: \(msg)"
            case .fileReadFailed: return "Failed to read audio file for transcription."
            }
        }
    }

    func prewarm(modelSize: String) {
        var actualModel = modelSize
        let allowedModels = ["tiny", "tiny.en", "base", "base.en", "small", "small.en", "distil-large-v3", "large-v3", "large-v3-turbo"]
        if !allowedModels.contains(actualModel) {
            actualModel = "base"
        }
        
        if currentModelSize != actualModel || whisperKitTask == nil {
            whisperKitTask?.cancel()
            currentModelSize = actualModel
            whisperKitTask = Task {
                let processor = AudioProcessor()
                processor.audioEngine = nil // Destroy AVAudioEngine so macOS drops the mic privacy indicator
                
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let downloadBase = appSupport.appendingPathComponent("HushAI_WhisperKit", isDirectory: true)
                try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
                
                return try await WhisperKit(model: actualModel, downloadBase: downloadBase, audioProcessor: processor)
            }
        }
    }

    func transcribe(fileURL: URL, modelSize: String, prompt: String? = nil, language: String? = nil) async throws -> String {
        // Map tiny, base, small to their respective WhisperKit identifiers
        var actualModel = modelSize
        let allowedModels = ["tiny", "tiny.en", "base", "base.en", "small", "small.en", "distil-large-v3", "large-v3", "large-v3-turbo"]
        if !allowedModels.contains(actualModel) {
            actualModel = "base"
        }
        
        if currentModelSize != actualModel || whisperKitTask == nil {
            whisperKitTask?.cancel()
            currentModelSize = actualModel
            whisperKitTask = Task {
                let processor = AudioProcessor()
                processor.audioEngine = nil // Destroy AVAudioEngine so macOS drops the mic privacy indicator
                
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let downloadBase = appSupport.appendingPathComponent("HushAI_WhisperKit", isDirectory: true)
                try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
                
                return try await WhisperKit(model: actualModel, downloadBase: downloadBase, audioProcessor: processor)
            }
        }
        
        let pipe: WhisperKit
        do {
            pipe = try await whisperKitTask!.value
        } catch {
            throw LocalTranscriptionError.initializationFailed(error.localizedDescription)
        }
        
        var options = DecodingOptions()
        if let p = prompt, !p.isEmpty {
            // Encode the string prompt into tokens
            if let tokenizer = pipe.tokenizer {
                options.promptTokens = tokenizer.encode(text: p)
            }
        }
        if let l = language, !l.isEmpty, l != "Auto-detect" {
            options.language = l
        }
        
        // WhisperKit transcribe returns an array of TranscriptionResult
        let results = try await pipe.transcribe(audioPath: fileURL.path, decodeOptions: options)
        
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
