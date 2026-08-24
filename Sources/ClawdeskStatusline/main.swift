import Foundation

@main
struct ClawdeskStatusline {
    static func main() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            print("Clawdesk")
            return
        }

        let rateLimits = payload["rate_limits"] as? [String: Any]
        let contextUsage = contextUsage(from: payload)
        if rateLimits != nil || contextUsage != nil {
            postTelemetry(payload: payload, rateLimits: rateLimits, contextUsage: contextUsage)
        }
        print(statusText(for: payload))
    }

    private static func postTelemetry(
        payload: [String: Any],
        rateLimits: [String: Any]?,
        contextUsage: [String: Any]?
    ) {
        let runtimeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clawdesk/runtime.json")
        guard let runtimeData = try? Data(contentsOf: runtimeURL),
              let runtime = try? JSONSerialization.jsonObject(with: runtimeData) as? [String: Any],
              let port = runtime["port"] as? NSNumber else { return }

        let workspace = payload["workspace"] as? [String: Any]
        let event = rateLimits == nil ? "ContextUsage" : "QuotaUpdate"
        var body: [String: Any] = [
            "event": event,
            "agent_id": "claude-code",
            "metadata_only": true
        ]
        if let rateLimits { body["rate_limits"] = rateLimits }
        if let contextUsage { body["context_usage"] = contextUsage }
        if let sessionID = payload["session_id"] as? String, !sessionID.isEmpty {
            body["session_id"] = sessionID
        }
        if let cwd = workspace?["current_dir"] as? String, !cwd.isEmpty {
            body["cwd"] = cwd
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "http://127.0.0.1:\(port.intValue)/state?event=\(event)&agent=claude-code&clawdesk-hook-v1=1") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 0.15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + .milliseconds(120))
    }

    private static func contextUsage(from payload: [String: Any]) -> [String: Any]? {
        guard let window = payload["context_window"] as? [String: Any],
              let current = window["current_usage"] as? [String: Any] else { return nil }

        let components = [
            number(current["input_tokens"]),
            number(current["cache_read_input_tokens"]),
            number(current["cache_creation_input_tokens"])
        ]
        guard components.allSatisfy({ ($0 ?? 0) >= 0 }),
              components.contains(where: { $0 != nil }) else { return nil }
        let used = components.compactMap(\.self).reduce(0, +)
        guard used > 0 else { return nil }

        var result: [String: Any] = [
            "used": used,
            "source": "claude"
        ]
        if let limit = number(window["context_window_size"]), limit > 0 {
            result["limit"] = limit
        }
        if let percent = number(window["used_percentage"]) {
            result["percent"] = min(100, max(0, Int(percent.rounded())))
        }
        return result
    }

    private static func statusText(for payload: [String: Any]) -> String {
        var pieces: [String] = []
        if let model = payload["model"] as? [String: Any],
           let displayName = model["display_name"] as? String,
           !displayName.isEmpty {
            pieces.append(String(displayName.prefix(80)))
        }
        if let context = payload["context_window"] as? [String: Any],
           let used = number(context["used_percentage"]) {
            pieces.append("\(Int(used.rounded()))% ctx")
        }
        if let rateLimits = payload["rate_limits"] as? [String: Any],
           let weekly = rateLimits["seven_day"] as? [String: Any],
           let used = number(weekly["used_percentage"]) {
            pieces.append("\(Int(used.rounded()))% weekly")
        }
        return pieces.isEmpty ? "Clawdesk" : pieces.joined(separator: " · ")
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
