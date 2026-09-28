import Cocoa

/// The body's few requests to the brain's shell: quit everything, open the
/// dashboard, check for updates. Berrie.app (Electron) owns all three.
@MainActor
enum BrainShell {
    nonisolated static func request(path: String, body: [String: Any], connection: BerriesConnection) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(connection.port)\(path)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        return req
    }

    private static func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let c = BerriesBridge.berrieConnection(),
              let req = request(path: path, body: body, connection: c),
              let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The brain kills this process on quit; if the brain is gone, quit alone.
    static func quit() {
        Task {
            if await post("/shell", ["quit": true]) == nil { NSApplication.shared.terminate(nil) }
        }
    }

    static func openBoard() {
        Task {
            if await post("/shell", ["open": "board"]) == nil {
                AnswerBubbleController.shared.append("Berrie's brain isn't running, so there's no dashboard to open.")
            }
        }
    }

    static func checkForUpdates() {
        Task {
            let reply = await post("/update", ["action": "check"])
            let update = reply?["update"] as? [String: Any]
            let message = update?["message"] as? String ?? "Berrie's brain isn't running, so I can't check."
            AnswerBubbleController.shared.append(message)
        }
    }
}
