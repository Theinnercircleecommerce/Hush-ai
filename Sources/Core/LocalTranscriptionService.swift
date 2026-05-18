import Foundation
import WhisperKit

class LocalTranscriptionService {
    private var whisperKit: WhisperKit?
    private var currentModelSize: String = ""
    
    enum LocalTranscriptionError: LocalizedError {
        case initializationFailed
        case fileReadFailed
        
        var errorDescription: String? {
            switch self {
            case .initializationFailed: return "Failed to initialize WhisperKit."
            case .fileReadFailed: return "Failed to read audio file for transcription."
            }
        }
    }

    func transcribe(fileURL: URL, modelSize: String, prompt: String? = nil, language: String? = nil) async throws -> String {
        // Map tiny, base, small to their respective WhisperKit identifiers
        var actualModel = modelSize
        if actualModel != "tiny" && actualModel != "base" && actualModel != "small" {
            actualModel = "base"
        }
        
        if whisperKit == nil || currentModelSize != actualModel {
            whisperKit = try await WhisperKit(model: actualModel)
            currentModelSize = actualModel
        }
        
        guard let pipe = whisperKit else {
            throw LocalTranscriptionError.initializationFailed
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
