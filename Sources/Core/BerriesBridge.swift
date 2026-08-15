//
//  BerriesBridge.swift
//  Hush
//
//  Sends a circle-to-ask session into Berries Code instead of answering it here.
//
//  Berries Code runs a small localhost server and, whenever a chat wears the
//  @hush pill, writes a handshake file naming the port, the token and that
//  chat. Hush reads that file — no polling, no port scan — so "is a chat
//  connected?" is answerable at hotkey-press time for the cost of one read.
//
//  What comes back is a whole Claude Code turn, not a token stream: it has
//  project context and can read the repo, but it arrives in one piece. Its
//  first paragraph is written to work as speech on its own (Berries Code's
//  @hush system prompt enforces that), and the server hands us that paragraph
//  pre-extracted as `spoken`.
//

import Foundation

/// A live @hush connection, as of the last handshake write.
struct BerriesConnection {
    let port: Int
    let token: String
    /// Chat title, for the diagnostic line on the answer bubble.
    let chatTitle: String
    let projectPath: String

    var askURL: URL? { URL(string: "http://127.0.0.1:\(port)/ask") }
}

/// Failures here are read aloud, so each message is a sentence the user can act on.
struct BerriesError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The answer Berries Code produced: everything it said, plus the part to speak.
struct BerriesAnswer {
    let full: String
    let spoken: String
}

@MainActor
enum BerriesBridge {

    /// A Claude Code turn can genuinely run for minutes (it reads files, greps,
    /// runs tests). Berries Code gives up at 300s; stay just above it so the
    /// server's own explanation is what the user hears, not a bare timeout.
    private static let requestTimeout: TimeInterval = 320

    /// Screenshots we hand over live here. Berries Code reads them by path, so
    /// they must outlive the request — they're cleaned up on the next session.
    private static var dropboxURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hush-berries", isDirectory: true)
    }

    private static var handshakeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BerriesCode/hush-bridge.json")
    }

    // MARK: - Connection

    /// The chat currently wearing the @hush pill, or nil when Berries Code is
    /// closed, has no pill set, or never ran on this Mac.
    ///
    /// Cheap enough to call on the hotkey press path: one small file read.
    static func connection() -> BerriesConnection? {
        guard let data = try? Data(contentsOf: handshakeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["connected"] as? Bool == true,
              let port = json["port"] as? Int, port > 0,
              let token = json["token"] as? String, !token.isEmpty
        else { return nil }

        return BerriesConnection(
            port: port,
            token: token,
            chatTitle: (json["chat"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Berries Code",
            projectPath: json["project"] as? String ?? ""
        )
    }

    // MARK: - Ask

    /// Drops the screenshots where Berries Code can read them and posts the
    /// question into the connected chat. Returns once that turn is finished.
    static func ask(transcript: String,
                    screens: [CapturedScreen],
                    croppedRegion: Data?,
                    connection: BerriesConnection) async throws -> BerriesAnswer {

        let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw BerriesError(message: "I didn't catch that.")
        }
        guard let url = connection.askURL else {
            throw BerriesError(message: "Couldn't reach Berries Code.")
        }

        let drop = try writeScreenshots(screens: screens, croppedRegion: croppedRegion)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": prompt(question: question, drop: drop),
            "images": drop.allPaths,
        ])

        // URLSession's own default would cut a long turn off at 60s regardless
        // of the request's timeout, so the session gets the same ceiling.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: config).data(for: request)
        } catch {
            throw BerriesError(message: "Berries Code didn't answer — is it still open?")
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw BerriesError(message: "Berries Code restarted — reconnect with @hush.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BerriesError(message: "Berries Code sent something I couldn't read.")
        }
        if json["ok"] as? Bool != true {
            throw BerriesError(message: json["error"] as? String ?? "Berries Code couldn't answer that.")
        }

        let full = json["text"] as? String ?? ""
        let spoken = (json["spoken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? full
        return BerriesAnswer(full: full, spoken: spoken)
    }

    // MARK: - Screenshots on disk

    private struct Dropbox {
        let cropPath: String?
        let screenPaths: [String]
        var allPaths: [String] { (cropPath.map { [$0] } ?? []) + screenPaths }
    }

    /// Berries Code takes file paths, not base64 — its attachment path is the
    /// same one a drag-drop uses, so the shots also show as thumbnails in the
    /// chat.
    ///
    /// Each ask gets its own uniquely-named files rather than reusing one name:
    /// the chat keeps those paths in its history, so overwriting them would
    /// blank the thumbnails on every earlier question. Old ones are swept on a
    /// day's delay instead.
    private static func writeScreenshots(screens: [CapturedScreen],
                                         croppedRegion: Data?) throws -> Dropbox {
        let dir = dropboxURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw BerriesError(message: "Couldn't save the screenshot to hand over.")
        }

        // Anyone else on this Mac has no business reading the user's screen.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        sweepOldScreenshots(in: dir)

        let stamp = UUID().uuidString.prefix(8)
        func write(_ data: Data, _ name: String) -> String? {
            let url = dir.appendingPathComponent("\(stamp)-\(name)")
            guard (try? data.write(to: url)) != nil else { return nil }
            return url.path
        }

        let cropPath = croppedRegion.flatMap { write($0, "circled.jpg") }
        var screenPaths: [String] = []
        for (index, screen) in screens.enumerated() {
            if let path = write(screen.jpeg, "screen-\(index + 1).jpg") { screenPaths.append(path) }
        }

        guard cropPath != nil || !screenPaths.isEmpty else {
            throw BerriesError(message: "Couldn't save the screenshot to hand over.")
        }
        return Dropbox(cropPath: cropPath, screenPaths: screenPaths)
    }

    /// A day is long enough that scrolling back through today's chat still
    /// shows its thumbnails, and short enough that screenshots of the user's
    /// screen don't pile up in temp forever.
    private static func sweepOldScreenshots(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-86_400)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// What lands in the chat. The attachments carry the images; this only has
    /// to say which one the user was pointing at, since attachment order alone
    /// doesn't tell Claude that.
    private static func prompt(question: String, drop: Dropbox) -> String {
        guard let cropPath = drop.cropPath else { return question }
        return """
        \(question)

        (I circled part of my screen — that crop is \(cropPath). Look at it \
        first; the other attachment is the whole screen for context.)
        """
    }
}
