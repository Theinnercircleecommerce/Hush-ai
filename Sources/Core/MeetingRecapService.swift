//
//  MeetingRecapService.swift
//  Hush
//
//  One non-streaming Claude call per meeting: labelled transcript in,
//  {title, recap, action items} out. Deliberately separate from
//  ClaudeVisionClient — that client streams, keeps circle-to-ask follow-up
//  history, and meeting transcripts must never enter that history.
//

import Foundation

enum MeetingRecapError: LocalizedError {
    case missingKey
    case http(Int, String)
    case network(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "add your anthropic api key in settings"
        case .http(let status, let body):
            let shown = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            return shown.isEmpty ? "claude returned an error (\(status))"
                                 : "claude returned an error (\(status)): \(shown)"
        case .network(let error): return "couldn't reach claude: \(error.localizedDescription)"
        case .badResponse: return "claude's recap couldn't be read"
        }
    }
}

enum MeetingRecapService {

    static let model = "claude-sonnet-4-6"
    static let maxTokens = 2000
    /// A long transcript takes a while to ingest; the 20 s circle-to-ask
    /// timeout is far too tight here.
    static let timeout: TimeInterval = 120

    static let systemPrompt = """
    You summarize meeting transcripts. The speaker "Me" is the user of this \
    app; other speakers are named as Google Meet's captions showed them, and \
    "Someone else" marks lines that couldn't be attributed. Reply with ONLY a \
    JSON object, no markdown fences, exactly this shape:
    {"title": "...", "recap": "...", "action_items": [{"owner": "...", "task": "..."}]}
    - "title": at most 8 words naming the meeting's subject.
    - "recap": 5-10 plain-text sentences covering topics, decisions, and outcomes.
    - "action_items": every commitment made, one entry per task, owner exactly \
    as named in the transcript. Empty array if none.
    """

    /// "[03:12] Sarah: ship friday" — one line per attributed line.
    static func formatTranscript(_ lines: [AttributedLine]) -> String {
        lines.map { line in
            let minutes = Int(line.t) / 60
            let seconds = Int(line.t) % 60
            return String(format: "[%02d:%02d] %@: %@", minutes, seconds, line.speaker, line.text)
        }.joined(separator: "\n")
    }

    /// Extracts the outermost JSON object; tolerates fences and stray prose.
    static func parse(_ text: String) -> MeetingRecapResult? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String,
              let recap = object["recap"] as? String
        else { return nil }

        let items = (object["action_items"] as? [[String: Any]] ?? []).compactMap { item -> ActionItem? in
            guard let owner = item["owner"] as? String,
                  let task = item["task"] as? String else { return nil }
            return ActionItem(owner: owner, task: task)
        }
        return MeetingRecapResult(title: title, recap: recap, actionItems: items)
    }

    static func recap(lines: [AttributedLine],
                      participants: [String]) async throws -> MeetingRecapResult {
        guard let apiKey = KeychainStore.get(.anthropic) else {
            throw MeetingRecapError.missingKey
        }

        let userMessage = "Participants: \(participants.joined(separator: ", "))\n\nTranscript:\n"
            + formatTranscript(lines)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MeetingRecapError.network(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw MeetingRecapError.http(status, String(data: data.prefix(8192), encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingRecapError.badResponse
        }

        // Anthropic bills whatever it generated — record before parse can fail.
        if let usage = object["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            await MainActor.run {
                UsageStore.shared.recordClaude(model: model, inputTokens: input, outputTokens: output)
            }
        }

        let text = ((object["content"] as? [[String: Any]]) ?? [])
            .compactMap { $0["text"] as? String }
            .joined()
        guard let result = parse(text) else { throw MeetingRecapError.badResponse }
        return result
    }
}
