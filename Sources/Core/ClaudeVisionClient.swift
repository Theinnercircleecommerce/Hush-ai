//
//  ClaudeVisionClient.swift
//  Hush
//
//  Streaming Claude vision client for circle-to-ask. Sends the circled crop,
//  every captured screen, and the spoken transcript to the Messages API and
//  streams the answer back a chunk at a time so speech can start early.
//
//  Raw URLSession is deliberate: there is no official Anthropic SDK for Swift,
//  and Hush ships with no HTTP dependencies.
//

import Foundation

/// Failures surfaced by `ClaudeVisionClient`. None of these ever carry the API
/// key: `.http` holds the server's *response* body only, and `.network` wraps
/// the transport error, whose description never includes request headers.
enum ClaudeError: LocalizedError {
    case missingKey
    case http(Int, String)
    case network(Error)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "add your anthropic api key in settings"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "claude returned an error (\(status))"
                : "claude returned an error (\(status)): \(trimmed)"
        case .network(let error):
            return "couldn't reach claude: \(error.localizedDescription)"
        case .empty:
            return "claude didn't say anything"
        }
    }
}

/// Asks Claude about the user's screen(s) and streams the spoken-style answer.
///
/// `@MainActor` isolated so `history` can never race: `ask` is async and will be
/// driven from a `Task`, but every mutation of the conversation state happens on
/// the main actor. It also means `onChunk` is always invoked on the main queue,
/// which is what the UI in Task 8 needs.
@MainActor
final class ClaudeVisionClient {

    static let shared = ClaudeVisionClient()

    // MARK: - Configuration

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Chosen deliberately for latency. Do not swap this out or add a picker.
    private static let model = "claude-sonnet-4-6"
    private static let maxTokens = 1024
    private static let apiVersion = "2023-06-01"
    private static let timeout: TimeInterval = 20

    /// Number of `(user, assistant)` turns kept for follow-up questions.
    private static let maxHistoryExchanges = 10
    /// History older than this is stale — a new question isn't a follow-up.
    private static let historyExpiry: TimeInterval = 600  // 10 minutes

    private let systemPrompt = """
    you're hush, a friendly assistant that lives in the user's menu bar. the \
    user just spoke to you and you can see their screen(s). your reply will be \
    spoken aloud, so write the way you'd actually talk.

    - default to one or two sentences. be direct and dense.
    - all lowercase, casual, warm. no emojis, no markdown, no lists.
    - write for the ear, not the eye. short sentences.
    - reference specific things you can see on their screen.
    - when the user circled a region, focus your answer on that region.
    - don't read code or errors out verbatim — describe what they mean.
    - if you can't see what they're asking about, say so briefly.
    """

    // MARK: - Conversation state

    /// Text only — images are never replayed. They're the expensive part of the
    /// request and a follow-up question is about the answer, not the pixels.
    private struct Exchange {
        let user: String
        let assistant: String
    }

    private var history: [Exchange] = []
    private var lastExchangeAt: Date?

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ClaudeVisionClient.timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// Clears the follow-up context. Call when starting a fresh question.
    func resetConversation() {
        history.removeAll()
        lastExchangeAt = nil
    }

    /// Streams Claude's answer. `onChunk` fires on the main queue for every text
    /// delta; the full accumulated answer is returned when the stream ends.
    @discardableResult
    func ask(transcript: String,
             screens: [CapturedScreen],
             croppedRegion: Data?,
             onChunk: @escaping (String) -> Void) async throws -> String {

        guard let apiKey = KeychainStore.get(.anthropic) else {
            throw ClaudeError.missingKey
        }

        expireStaleHistory()

        let request = try makeRequest(
            apiKey: apiKey,
            transcript: transcript,
            screens: screens,
            croppedRegion: croppedRegion
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ClaudeError.network(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw ClaudeError.http(status, await collectErrorBody(from: bytes))
        }

        var answer = ""
        do {
            // `.lines` buffers across chunk boundaries, so a delta split mid-line
            // by the network is reassembled before we ever see it.
            for try await line in bytes.lines {
                guard let text = textDelta(fromSSELine: line), !text.isEmpty else { continue }
                answer += text
                // Already on the main actor, i.e. the main queue.
                onChunk(text)
            }
        } catch {
            throw ClaudeError.network(error)
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeError.empty }

        record(user: transcript, assistant: trimmed)
        return trimmed
    }

    // MARK: - SSE parsing

    /// Extracts `delta.text` from one Server-Sent Events line, or nil if the
    /// line isn't a text delta.
    ///
    /// Tolerates everything the wire can throw at us: blank lines, `event:` /
    /// `id:` / `retry:` fields, `:` heartbeat comments, the optional
    /// `data: [DONE]` sentinel, non-JSON payloads, and any event type we don't
    /// care about (`message_start`, `content_block_start`, `ping`,
    /// `message_delta`, `message_stop`).
    private func textDelta(fromSSELine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }

        let payload = line.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "content_block_delta",
              let delta = object["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta"
        else { return nil }

        return delta["text"] as? String
    }

    /// Drains a failed response's body for the error message. Capped so a
    /// pathological body can't be buffered forever.
    private func collectErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8192 { break }
            }
        } catch {
            // Partial body is still worth surfacing.
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Request building

    private func makeRequest(apiKey: String,
                             transcript: String,
                             screens: [CapturedScreen],
                             croppedRegion: Data?) throws -> URLRequest {

        var messages: [[String: Any]] = []
        for exchange in history {
            messages.append(["role": "user", "content": exchange.user])
            messages.append(["role": "assistant", "content": exchange.assistant])
        }
        messages.append(["role": "user", "content": userContentBlocks(
            transcript: transcript,
            screens: screens,
            croppedRegion: croppedRegion
        )])

        let body: [String: Any] = [
            "model": ClaudeVisionClient.model,
            "max_tokens": ClaudeVisionClient.maxTokens,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        var request = URLRequest(url: ClaudeVisionClient.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = ClaudeVisionClient.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ClaudeVisionClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ClaudeError.network(error)
        }

        return request
    }

    /// Block order matters — it's how Claude decides what to look at:
    /// circled crop, then each labelled screen, then the spoken question.
    private func userContentBlocks(transcript: String,
                                   screens: [CapturedScreen],
                                   croppedRegion: Data?) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        if let crop = croppedRegion, !crop.isEmpty {
            blocks.append(textBlock("the user circled this region"))
            blocks.append(imageBlock(crop))
        }

        for screen in screens {
            blocks.append(textBlock(screen.label))
            blocks.append(imageBlock(screen.jpeg))
        }

        blocks.append(textBlock(transcript))
        return blocks
    }

    private func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private func imageBlock(_ jpeg: Data) -> [String: Any] {
        [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": jpeg.base64EncodedString()
            ]
        ]
    }

    // MARK: - History

    private func expireStaleHistory() {
        guard let last = lastExchangeAt else { return }
        if Date().timeIntervalSince(last) > ClaudeVisionClient.historyExpiry {
            resetConversation()
        }
    }

    private func record(user: String, assistant: String) {
        history.append(Exchange(user: user, assistant: assistant))
        if history.count > ClaudeVisionClient.maxHistoryExchanges {
            history.removeFirst(history.count - ClaudeVisionClient.maxHistoryExchanges)
        }
        lastExchangeAt = Date()
    }
}
