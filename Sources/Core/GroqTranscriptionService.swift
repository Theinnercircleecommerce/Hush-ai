import Foundation

class GroqTranscriptionService {
    enum GroqError: LocalizedError {
        case invalidAPIKey
        case networkError(Error)
        case invalidResponse
        case apiError(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "API key is missing or invalid."
            case .networkError(let err): return err.localizedDescription
            case .invalidResponse: return "Received invalid response from Groq."
            case .apiError(let msg): return "Groq API Error: \(msg)"
            }
        }
    }
    
    func transcribe(fileURL: URL, apiKey: String, model: String, prompt: String? = nil, language: String? = nil) async throws -> String {
        let cleanApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanApiKey.isEmpty else { throw GroqError.invalidAPIKey }
        
        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanApiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        
        // Prompt
        if let prompt = prompt, !prompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }
        
        // Language
        if let language = language, !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }
        
        // File
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown API Error"
            throw GroqError.apiError("Status \(httpResponse.statusCode): \(errorText)")
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = json?["text"] as? String else {
            throw GroqError.invalidResponse
        }
        
        return text
    }
    
    func cleanup(text: String, apiKey: String) async throws -> String {
        let cleanApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanApiKey.isEmpty else { throw GroqError.invalidAPIKey }
        
        let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cleanApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Strict JSON prompt to absolutely guarantee it never talks back or drops words.
        let systemPrompt = """
        You are a raw text cleaner. Your only purpose is to take the user's transcript and fix obvious punctuation or capitalization errors without dropping ANY words, concepts, or intent.
        DO NOT act as an AI. DO NOT reply to the user. DO NOT answer questions.
        You MUST output ONLY a valid JSON object with a single key "cleaned_text" containing the result.
        """
        
        let payload: [String: Any] = [
            "model": "llama-3.3-70b-versatile",
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.0 // 0 temperature forces deterministic, non-creative formatting
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GroqError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown API Error"
            throw GroqError.apiError("Status \(httpResponse.statusCode): \(errorText)")
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let contentString = message["content"] as? String else {
            throw GroqError.invalidResponse
        }
        
        // Parse the JSON string from the content
        guard let contentData = contentString.data(using: .utf8),
              let parsedJson = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let cleanedText = parsedJson["cleaned_text"] as? String else {
            return contentString.trimmingCharacters(in: .whitespacesAndNewlines) // fallback if JSON parse fails
        }
        
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
