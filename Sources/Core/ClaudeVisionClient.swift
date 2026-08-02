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
    /// The user held the hotkey but said nothing.
    case noSpeech
    /// Claude returned a 200 with no text in it.
    case empty

    /// Longest server text we'll splice into a user-facing string. The stream
    /// body is already capped at 8 KB on collection; this stops that 8 KB from
    /// reaching a label.
    private static let maxBodyInDescription = 300

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "add your anthropic api key in settings"
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "claude returned an error (\(status))"
            }
            let limit = ClaudeError.maxBodyInDescription
            let shown = trimmed.count > limit
                ? String(trimmed.prefix(limit)) + "…"
                : trimmed
            return "claude returned an error (\(status)): \(shown)"
        case .network(let error):
            return "couldn't reach claude: \(error.localizedDescription)"
        case .noSpeech:
            return "i didn't catch that"
        case .empty:
            return "claude didn't say anything"
        }
    }
}

/// Endpoint, model, and prompt constants.
///
/// Deliberately at file scope rather than inside the `@MainActor` class so the
/// off-actor request builder can read them without hopping back to the main
/// actor.
private enum Claude {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Chosen deliberately for latency. Do not swap this out or add a picker.
    static let model = "claude-sonnet-4-6"
    static let maxTokens = 1024
    static let apiVersion = "2023-06-01"
    static let timeout: TimeInterval = 20

    /// Number of `(user, assistant)` turns kept for follow-up questions.
    static let maxHistoryExchanges = 10
    /// History older than this is stale — a new question isn't a follow-up.
    static let historyExpiry: TimeInterval = 600  // 10 minutes

    /// Largest error body we'll buffer off a failed response.
    static let maxErrorBodyBytes = 8192

    static let systemPrompt = """
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
        configuration.timeoutIntervalForRequest = Claude.timeout
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
    ///
    /// - Important: Not reentrant. Overlapping calls can't corrupt `history`
    ///   (it's main-actor isolated and only written on success), but both would
    ///   stream `onChunk` into the same UI and interleave the spoken answer —
    ///   the caller must serialize asks.
    @discardableResult
    func ask(transcript: String,
             screens: [CapturedScreen],
             croppedRegion: Data?,
             onChunk: @escaping (String) -> Void) async throws -> String {

        // Missing key first: it's the actionable failure. A user with no key
        // who fumbles the hotkey must be told to add the key, not that we
        // didn't catch what they said.
        guard let apiKey = KeychainStore.get(.anthropic) else {
            throw ClaudeError.missingKey
        }

        // An empty transcript is an ordinary outcome — hotkey held and released
        // without speaking. The API rejects empty text blocks with a 400, so
        // catch it here rather than showing the user raw error JSON. Task 7
        // guards this too; the client must not rely on its caller for this.
        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw ClaudeError.noSpeech }

        expireStaleHistory()

        // Snapshot history so the request can be built off the main actor.
        let priorTurns = history.map { ($0.user, $0.assistant) }

        // Base64-encoding several screenshots and serializing a multi-megabyte
        // JSON body are both expensive. `makeRequest` is a nonisolated async
        // function, so awaiting it runs the work on the cooperative pool and
        // keeps the main thread free while the overlay animates.
        let request = try await makeRequest(
            apiKey: apiKey,
            transcript: question,
            screens: screens,
            croppedRegion: croppedRegion,
            priorTurns: priorTurns
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
                // Throws on a mid-stream `error` event — a 200 response can still
                // fail partway through, and we must not treat the partial text as
                // a complete answer.
                guard let text = try textDelta(fromSSELine: line), !text.isEmpty else { continue }
                answer += text
                // Already on the main actor, i.e. the main queue.
                onChunk(text)
            }
        } catch let error as ClaudeError {
            throw error
        } catch {
            throw ClaudeError.network(error)
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeError.empty }

        record(user: question, assistant: trimmed)
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
    ///
    /// - Throws: `ClaudeError.http` when the stream carries an `error` event.
    ///   The API can fail *after* a 200 — overload, an inference error — and
    ///   silently returning the partial text would speak half a sentence and
    ///   then record that fragment as a completed turn.
    private nonisolated func textDelta(fromSSELine line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }

        let payload = line.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        if type == "error" {
            let error = object["error"] as? [String: Any]
            let kind = error?["type"] as? String ?? "api_error"
            let message = error?["message"] as? String ?? kind
            // 529 is what an overload would have been had it arrived as a
            // status code; anything else maps to a generic server error.
            throw ClaudeError.http(kind == "overloaded_error" ? 529 : 500, message)
        }

        guard type == "content_block_delta",
              let delta = object["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta"
        else { return nil }

        return delta["text"] as? String
    }

    /// Drains a failed response's body for the error message. Capped so a
    /// pathological body can't be buffered forever.
    private nonisolated func collectErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= Claude.maxErrorBodyBytes { break }
            }
        } catch {
            // Partial body is still worth surfacing.
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Request building (off the main actor)

    /// Builds the request body. `nonisolated async` so the base64 encoding and
    /// JSON serialization run on the cooperative pool, never the main thread.
    private nonisolated func makeRequest(apiKey: String,
                                         transcript: String,
                                         screens: [CapturedScreen],
                                         croppedRegion: Data?,
                                         priorTurns: [(user: String, assistant: String)]) async throws -> URLRequest {

        var messages: [[String: Any]] = []
        for turn in priorTurns {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        messages.append(["role": "user", "content": userContentBlocks(
            transcript: transcript,
            screens: screens,
            croppedRegion: croppedRegion
        )])

        let body: [String: Any] = [
            "model": Claude.model,
            "max_tokens": Claude.maxTokens,
            "stream": true,
            "system": Claude.systemPrompt,
            "messages": messages
        ]

        var request = URLRequest(url: Claude.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Claude.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Claude.apiVersion, forHTTPHeaderField: "anthropic-version")
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
    ///
    /// Every text block is non-empty by construction: the API rejects blank
    /// text blocks with a 400, so an unlabelled screen contributes its image
    /// only.
    private nonisolated func userContentBlocks(transcript: String,
                                               screens: [CapturedScreen],
                                               croppedRegion: Data?) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        if let crop = croppedRegion, !crop.isEmpty {
            blocks.append(textBlock("the user circled this region"))
            blocks.append(imageBlock(crop))
        }

        for screen in screens where !screen.jpeg.isEmpty {
            let label = screen.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                blocks.append(textBlock(label))
            }
            blocks.append(imageBlock(screen.jpeg))
        }

        blocks.append(textBlock(transcript))
        return blocks
    }

    private nonisolated func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private nonisolated func imageBlock(_ jpeg: Data) -> [String: Any] {
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
        if Date().timeIntervalSince(last) > Claude.historyExpiry {
            resetConversation()
        }
    }

    private func record(user: String, assistant: String) {
        history.append(Exchange(user: user, assistant: assistant))
        if history.count > Claude.maxHistoryExchanges {
            history.removeFirst(history.count - Claude.maxHistoryExchanges)
        }
        lastExchangeAt = Date()
    }
}
