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

    /// Like `transcribe`, but returns per-segment timestamps for the meeting
    /// merger. WhisperKit windows long audio internally (30 s frames) and
    /// reports absolute segment times, so no external chunking is needed.
    func transcribeSegments(fileURL: URL,
                            modelSize: String,
                            language: String? = nil) async throws -> [TranscriptSegment] {
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
        if let l = language, !l.isEmpty, l != "Auto-detect" {
            options.language = l
        }

        let results = try await pipe.transcribe(audioPath: fileURL.path, decodeOptions: options)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                // Strip Whisper's special tokens like <|startoftranscript|>.
                let text = seg.text
                    .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(start: TimeInterval(seg.start),
                                                  end: TimeInterval(seg.end),
                                                  text: text))
            }
        }
        return segments
    }
}
