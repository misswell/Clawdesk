import Foundation

public struct RemoteChannelSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var slackWebhookURL: String?
    public var telegramBotToken: String?
    public var telegramChatID: String?
    public var telegramApprovalEnabled: Bool = false
    public var telegramApprovalUserID: String?
    public var telegramApprovalTimeoutSeconds: Int = 60
    public var feishuWebhookURL: String?
    public var feishuApprovalEnabled: Bool = false
    public var feishuPlatform: String = "feishu"
    public var feishuAppID: String?
    public var feishuAppSecret: String?
    public var feishuApproverID: String?
    public var feishuApproverIDType: String = "open_id"
    public var feishuConnectionTimeoutSeconds: Int = 15

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled
        case slackWebhookURL
        case telegramBotToken
        case telegramChatID
        case telegramApprovalEnabled
        case telegramApprovalUserID
        case telegramApprovalTimeoutSeconds
        case feishuWebhookURL
        case feishuApprovalEnabled
        case feishuPlatform
        case feishuAppID
        case feishuAppSecret
        case feishuApproverID
        case feishuApproverIDType
        case feishuConnectionTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        slackWebhookURL = try container.decodeIfPresent(String.self, forKey: .slackWebhookURL)
        telegramBotToken = try container.decodeIfPresent(String.self, forKey: .telegramBotToken)
        telegramChatID = try container.decodeIfPresent(String.self, forKey: .telegramChatID)
        telegramApprovalEnabled = try container.decodeIfPresent(Bool.self, forKey: .telegramApprovalEnabled) ?? false
        telegramApprovalUserID = try container.decodeIfPresent(String.self, forKey: .telegramApprovalUserID)
        telegramApprovalTimeoutSeconds = Self.normalizedTimeout(
            try container.decodeIfPresent(Int.self, forKey: .telegramApprovalTimeoutSeconds) ?? 60
        )
        feishuWebhookURL = try container.decodeIfPresent(String.self, forKey: .feishuWebhookURL)
        feishuApprovalEnabled = try container.decodeIfPresent(Bool.self, forKey: .feishuApprovalEnabled) ?? false
        feishuPlatform = Self.normalizedFeishuPlatform(
            try container.decodeIfPresent(String.self, forKey: .feishuPlatform) ?? "feishu"
        )
        feishuAppID = Self.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .feishuAppID))
        feishuAppSecret = Self.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .feishuAppSecret))
        feishuApproverID = Self.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .feishuApproverID))
        feishuApproverIDType = Self.normalizedFeishuIDType(
            try container.decodeIfPresent(String.self, forKey: .feishuApproverIDType) ?? "open_id"
        )
        feishuConnectionTimeoutSeconds = Self.normalizedFeishuTimeout(
            try container.decodeIfPresent(Int.self, forKey: .feishuConnectionTimeoutSeconds) ?? 15
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(slackWebhookURL, forKey: .slackWebhookURL)
        try container.encodeIfPresent(telegramBotToken, forKey: .telegramBotToken)
        try container.encodeIfPresent(telegramChatID, forKey: .telegramChatID)
        try container.encode(telegramApprovalEnabled, forKey: .telegramApprovalEnabled)
        try container.encodeIfPresent(telegramApprovalUserID, forKey: .telegramApprovalUserID)
        try container.encode(Self.normalizedTimeout(telegramApprovalTimeoutSeconds), forKey: .telegramApprovalTimeoutSeconds)
        try container.encodeIfPresent(feishuWebhookURL, forKey: .feishuWebhookURL)
        try container.encode(feishuApprovalEnabled, forKey: .feishuApprovalEnabled)
        try container.encode(Self.normalizedFeishuPlatform(feishuPlatform), forKey: .feishuPlatform)
        try container.encodeIfPresent(Self.normalizedOptionalString(feishuAppID), forKey: .feishuAppID)
        try container.encodeIfPresent(Self.normalizedOptionalString(feishuAppSecret), forKey: .feishuAppSecret)
        try container.encodeIfPresent(Self.normalizedOptionalString(feishuApproverID), forKey: .feishuApproverID)
        try container.encode(Self.normalizedFeishuIDType(feishuApproverIDType), forKey: .feishuApproverIDType)
        try container.encode(Self.normalizedFeishuTimeout(feishuConnectionTimeoutSeconds), forKey: .feishuConnectionTimeoutSeconds)
    }

    private static func normalizedTimeout(_ value: Int) -> Int {
        min(300, max(15, value))
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(512))
    }

    private static func normalizedFeishuPlatform(_ value: String) -> String {
        ["feishu", "lark"].contains(value.lowercased()) ? value.lowercased() : "feishu"
    }

    private static func normalizedFeishuIDType(_ value: String) -> String {
        ["open_id", "union_id", "user_id"].contains(value) ? value : "open_id"
    }

    private static func normalizedFeishuTimeout(_ value: Int) -> Int {
        [5, 10, 15, 30, 60].contains(value) ? value : 15
    }
}

public struct RemoteNotification: Sendable {
    public let title: String
    public let body: String
    public let sessionTitle: String?

    public init(title: String, body: String, sessionTitle: String? = nil) {
        self.title = title
        self.body = body
        self.sessionTitle = sessionTitle
    }
}

@MainActor
public final class RemoteNotifier {
    public let configurationURL: URL
    public private(set) var settings: RemoteChannelSettings

    private let fileManager: FileManager
    private let feishuTransport: FeishuApprovalTransport
    private var approvalHandlers: [String: @Sendable (PermissionDecision) -> Void] = [:]
    private var approvalTasks: [String: Task<Void, Never>] = [:]
    private var telegramPollTask: Task<Void, Never>?
    private var telegramUpdateOffset: Int64 = 0

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let directory = homeDirectory.appendingPathComponent("Library/Application Support/Clawdesk", isDirectory: true)
        configurationURL = directory.appendingPathComponent("remote-channels.json")
        feishuTransport = FeishuApprovalTransport()
        if let data = try? Data(contentsOf: configurationURL),
           let decoded = try? JSONDecoder().decode(RemoteChannelSettings.self, from: data) {
            settings = decoded
        } else {
            settings = RemoteChannelSettings()
        }
        feishuTransport.configure(settings)
    }

    public func save(_ settings: RemoteChannelSettings) throws {
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: configurationURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        self.settings = settings
        feishuTransport.configure(settings)
        if !settings.telegramApprovalEnabled {
            cancelTelegramApprovals()
        } else {
            ensureTelegramPolling()
        }
    }

    public func send(_ notification: RemoteNotification) {
        guard settings.enabled else { return }
        if let slackWebhookURL = settings.slackWebhookURL, let url = URL(string: slackWebhookURL) {
            post(url: url, object: [
                "text": "\(notification.title)\n\(notification.body)"
            ])
        }
        if let token = settings.telegramBotToken,
           let chatID = settings.telegramChatID,
           let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") {
            post(url: url, object: ["chat_id": chatID, "text": "*\(notification.title)*\n\(notification.body)", "parse_mode": "Markdown"])
        }
        if let webhook = settings.feishuWebhookURL, let url = URL(string: webhook) {
            post(url: url, object: [
                "msg_type": "text",
                "content": ["text": "\(notification.title)\n\(notification.body)"]
            ])
        }
    }

    /// Mirrors a permission request to Telegram without taking ownership of
    /// the local decision. The supplied completion is invoked at most once;
    /// callers can safely race it with the desktop bubble's PermissionReply.
    @discardableResult
    public func startApproval(
        for request: PermissionRequest,
        completion: @escaping @Sendable (PermissionDecision) -> Void
    ) -> Bool {
        let telegramConfigured = isTelegramApprovalConfigured
        let feishuConfigured = feishuTransport.isConfigured
        guard telegramConfigured || feishuConfigured else { return false }
        cancelApproval(id: request.id)
        var started = false
        if telegramConfigured {
            approvalHandlers[request.id] = completion
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let messageID = try await self.sendTelegramApprovalCard(for: request)
                    guard !Task.isCancelled, self.approvalHandlers[request.id] != nil else { return }
                    _ = messageID
                    try await Task.sleep(for: Self.approvalTimeout(for: self.settings))
                    guard !Task.isCancelled else { return }
                    self.removeTelegramApproval(id: request.id)
                } catch is CancellationError {
                    return
                } catch {
                    // Remote transport failure is deliberately non-decisioning:
                    // the local bubble remains pending and usable.
                    self.removeTelegramApproval(id: request.id)
                }
            }
            approvalTasks[request.id] = task
            ensureTelegramPolling()
            started = true
        }
        if feishuConfigured {
            started = feishuTransport.startApproval(for: request, completion: completion) || started
        }
        return started
    }

    public func cancelApproval(id: String) {
        approvalTasks.removeValue(forKey: id)?.cancel()
        approvalHandlers.removeValue(forKey: id)
        feishuTransport.cancelApproval(id: id)
        if approvalHandlers.isEmpty {
            telegramPollTask?.cancel()
            telegramPollTask = nil
        }
    }

    public func stop() {
        cancelAllApprovals()
        feishuTransport.stop()
    }

    internal var isTelegramApprovalConfigured: Bool {
        guard settings.telegramApprovalEnabled,
              let token = settings.telegramBotToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let chatID = settings.telegramChatID,
              !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return telegramApproverID != nil
    }

    internal var isFeishuApprovalConfigured: Bool { feishuTransport.isConfigured }

    internal static func parseTelegramApprovalCallback(_ value: String) -> (requestID: String, decision: PermissionDecision)? {
        let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "clawdesk", !parts[1].isEmpty else { return nil }
        switch parts[2] {
        case "allow": return (parts[1], .allow)
        case "deny": return (parts[1], .deny)
        default: return nil
        }
    }

    internal static func telegramApprovalPayload(for request: PermissionRequest) -> [String: Any] {
        let command = request.command.map { "\nCommand: \(bounded($0, maxLength: 900))" } ?? ""
        let input = request.input.map { "\nInput: \(bounded($0, maxLength: 900))" } ?? ""
        let text = "Clawdesk permission request\n\(bounded(request.title, maxLength: 900))\(command)\(input)"
        return [
            "chat_id": "",
            "text": bounded(text, maxLength: 3500),
            "reply_markup": [
                "inline_keyboard": [[
                    ["text": "Allow", "callback_data": "clawdesk:\(request.id):allow"],
                    ["text": "Deny", "callback_data": "clawdesk:\(request.id):deny"]
                ]]
            ]
        ]
    }

    private func post(url: URL, object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        URLSession.shared.dataTask(with: request).resume()
    }

    private var telegramApproverID: String? {
        let candidate = settings.telegramApprovalUserID ?? settings.telegramChatID
        guard let candidate else { return nil }
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, Int64(normalized) != nil else { return nil }
        return normalized
    }

    private static func approvalTimeout(for settings: RemoteChannelSettings) -> Duration {
        .seconds(Double(min(300, max(15, settings.telegramApprovalTimeoutSeconds))))
    }

    private static func bounded(_ value: String, maxLength: Int) -> String {
        let normalized = value.replacingOccurrences(of: "\u{0000}", with: " ")
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength - 1)) + "…"
    }

    private func sendTelegramApprovalCard(for request: PermissionRequest) async throws -> Int? {
        guard let token = settings.telegramBotToken,
              let chatID = settings.telegramChatID,
              !token.isEmpty, !chatID.isEmpty else {
            throw RemoteNotifierError.notConfigured
        }
        var payload = Self.telegramApprovalPayload(for: request)
        payload["chat_id"] = chatID
        let response = try await telegramRequest(token: token, method: "sendMessage", payload: payload)
        return ((response["result"] as? [String: Any])?["message_id"] as? NSNumber)?.intValue
    }

    private func ensureTelegramPolling() {
        guard telegramPollTask == nil, isTelegramApprovalConfigured, !approvalHandlers.isEmpty else { return }
        telegramPollTask = Task { @MainActor [weak self] in
            await self?.telegramPollLoop()
        }
    }

    private func telegramPollLoop() async {
        defer { telegramPollTask = nil }
        while !Task.isCancelled, isTelegramApprovalConfigured, !approvalHandlers.isEmpty {
            guard let token = settings.telegramBotToken else { break }
            do {
                let response = try await telegramRequest(
                    token: token,
                    method: "getUpdates",
                    payload: [
                        "offset": telegramUpdateOffset,
                        "timeout": 20,
                        "allowed_updates": ["callback_query"]
                    ],
                    timeout: 30
                )
                if let updates = response["result"] as? [[String: Any]] {
                    for update in updates {
                        await consumeTelegramUpdate(update)
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func consumeTelegramUpdate(_ update: [String: Any]) async {
        if let updateID = (update["update_id"] as? NSNumber)?.int64Value {
            telegramUpdateOffset = max(telegramUpdateOffset, updateID + 1)
        }
        guard let callback = update["callback_query"] as? [String: Any],
              let callbackID = callback["id"] as? String,
              let data = callback["data"] as? String,
              let parsed = Self.parseTelegramApprovalCallback(data),
              let allowedUserID = telegramApproverID,
              let from = callback["from"] as? [String: Any],
              let fromID = (from["id"] as? NSNumber)?.stringValue,
              fromID == allowedUserID,
              let handler = approvalHandlers.removeValue(forKey: parsed.requestID) else {
            return
        }
        approvalTasks.removeValue(forKey: parsed.requestID)?.cancel()
        feishuTransport.cancelApproval(id: parsed.requestID)
        handler(parsed.decision)
        if let token = settings.telegramBotToken {
            _ = try? await telegramRequest(
                token: token,
                method: "answerCallbackQuery",
                payload: ["callback_query_id": callbackID]
            )
        }
    }

    private func removeRemoteApproval(id: String) {
        removeTelegramApproval(id: id)
        feishuTransport.cancelApproval(id: id)
    }

    private func removeTelegramApproval(id: String) {
        approvalTasks.removeValue(forKey: id)?.cancel()
        approvalHandlers.removeValue(forKey: id)
        if approvalHandlers.isEmpty { telegramPollTask?.cancel(); telegramPollTask = nil }
    }

    private func cancelAllApprovals() {
        cancelTelegramApprovals()
        feishuTransport.cancelAllApprovals()
    }

    private func cancelTelegramApprovals() {
        approvalTasks.values.forEach { $0.cancel() }
        approvalTasks.removeAll()
        approvalHandlers.removeAll()
        feishuTransport.cancelAllApprovals()
        telegramPollTask?.cancel()
        telegramPollTask = nil
    }

    private func telegramRequest(
        token: String,
        method: String,
        payload: [String: Any],
        timeout: TimeInterval = 10
    ) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)"),
              JSONSerialization.isValidJSONObject(payload) else {
            throw RemoteNotifierError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true else {
            throw RemoteNotifierError.invalidResponse
        }
        return object
    }
}

private enum RemoteNotifierError: Error {
    case notConfigured
    case invalidResponse
}
