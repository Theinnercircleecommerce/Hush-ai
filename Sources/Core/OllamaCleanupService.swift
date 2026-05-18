import Foundation

class OllamaCleanupService {
    enum OllamaError: LocalizedError {
        case notRunning
        case invalidResponse
        case apiError(String)
        
        var errorDescription: String? {
            switch self {
            case .notRunning: return "Ollama is not running."
            case .invalidResponse: return "Received invalid response from Ollama."
            case .apiError(let msg): return "Ollama API Error: \(msg)"
            }
        }
    }
    
    func checkIsRunning() async -> Bool {
        let url = URL(string: "http://localhost:11434")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
        } catch {
            return false
        }
        return false
    }
    
    func cleanup(text: String, modelName: String) async throws -> String {
        let isRunning = await checkIsRunning()
        guard isRunning else {
            throw OllamaError.notRunning
        }
        
        let url = URL(string: "http://localhost:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0
        
        let systemPrompt = """
        You are an intelligent text editor processing raw voice dictation. Your job is to output perfectly formatted text. 
        You MUST:
        1. Fix obvious punctuation and capitalization errors.
        2. Intelligently correct phonetic mistranscriptions (e.g., if a phrase makes no logical sense like "work in no", fix it to what the user obviously meant like "working now").
        3. Never act as an AI assistant, do not reply to the user, and do not answer questions.
        You MUST output ONLY a valid JSON object with a single key "cleaned_text" containing the final result.
        """
        
        let payload: [String: Any] = [
            "model": modelName,
            "system": systemPrompt,
            "prompt": text,
            "format": "json",
            "stream": false,
            "options": [
                "temperature": 0.0
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown API Error"
            throw OllamaError.apiError("Status \(httpResponse.statusCode): \(errorText)")
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let responseString = json?["response"] as? String else {
            throw OllamaError.invalidResponse
        }
        
        // Parse the JSON string from the response
        guard let contentData = responseString.data(using: .utf8),
              let parsedJson = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let cleanedText = parsedJson["cleaned_text"] as? String else {
            return responseString.trimmingCharacters(in: .whitespacesAndNewlines) // fallback if JSON parse fails
        }
        
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
