import Foundation

/// Native Feishu/Lark approval transport.
///
/// The official SDK is intentionally not embedded in the macOS app. The
/// transport keeps the small REST surface and the protobuf frame used by the
/// platform's long connection in one adapter, leaving the permission model
/// independent from the vendor protocol.
@MainActor
final class FeishuApprovalTransport {
    typealias DecisionHandler = @Sendable (PermissionDecision) -> Void

    private struct Pending {
        let request: PermissionRequest
        let completion: DecisionHandler
    }

    private struct ConnectionEndpoint {
        let url: URL
        let serviceID: Int
        let pingInterval: TimeInterval
    }

    private enum TransportError: Error {
        case notConfigured
        case invalidResponse
        case invalidEndpoint
        case invalidFrame
    }

    private let session: URLSession
    private var settings = RemoteChannelSettings()
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var pending: [String: Pending] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var messageIDs: [String: String] = [:]
    private var accessToken: String?
    private var accessTokenExpiresAt: Date = .distantPast

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConfigured: Bool {
        guard settings.feishuApprovalEnabled,
              ["feishu", "lark"].contains(settings.feishuPlatform.lowercased()),
              let appID = settings.feishuAppID,
              let appSecret = settings.feishuAppSecret,
              let approverID = settings.feishuApproverID else { return false }
        return !appID.isEmpty && !appSecret.isEmpty && !approverID.isEmpty
    }

    func configure(_ settings: RemoteChannelSettings) {
        let changed = self.settings != settings
        self.settings = settings
        accessToken = nil
        accessTokenExpiresAt = .distantPast
        if !isConfigured {
            cancelAllApprovals()
            stopConnection()
        } else if changed {
            stopConnection()
            ensureConnection()
        } else {
            ensureConnection()
        }
    }

    @discardableResult
    func startApproval(
        for request: PermissionRequest,
        completion: @escaping DecisionHandler
    ) -> Bool {
        guard isConfigured else { return false }
        cancelApproval(id: request.id)
        pending[request.id] = Pending(request: request, completion: completion)
        let timeout = max(15, settings.feishuConnectionTimeoutSeconds) * 4
        timeoutTasks[request.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pending.removeValue(forKey: request.id)
            self.messageIDs.removeValue(forKey: request.id)
            self.timeoutTasks.removeValue(forKey: request.id)
        }

        ensureConnection()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let messageID = try await self.sendApprovalCard(for: request)
                guard self.pending[request.id] != nil else { return }
                self.messageIDs[request.id] = messageID
            } catch {
                // A failed remote delivery never decides a local permission.
                // The desktop bubble remains the source of truth.
            }
        }
        return true
    }

    func cancelApproval(id: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)
        messageIDs.removeValue(forKey: id)
    }

    func cancelAllApprovals() {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        pending.removeAll()
        messageIDs.removeAll()
    }

    func stop() {
        cancelAllApprovals()
        stopConnection()
    }

    private var apiHost: String {
        settings.feishuPlatform.lowercased() == "lark"
            ? "https://open.larksuite.com"
            : "https://open.feishu.cn"
    }

    private func ensureConnection() {
        guard isConfigured, connectionTask == nil else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        connectionTask = Task { @MainActor [weak self] in
            await self?.runConnectionLoop(generation: generation)
            guard let self, self.connectionGeneration == generation else { return }
            self.connectionTask = nil
        }
    }

    private func stopConnection() {
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
    }

    private func runConnectionLoop(generation: Int) async {
        while !Task.isCancelled, generation == connectionGeneration, isConfigured {
            do {
                let endpoint = try await fetchConnectionEndpoint()
                try await runSocket(endpoint, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == connectionGeneration else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func runSocket(_ endpoint: ConnectionEndpoint, generation: Int) async throws {
        let socket = session.webSocketTask(with: endpoint.url)
        socket.resume()
        // URLSession does not expose a readyState. A small handshake grace
        // period followed by a ping gives the task a bounded open check; a
        // failed send is surfaced as a reconnectable transport error.
        try await Task.sleep(for: .milliseconds(250))
        try await socket.send(.data(FeishuFrameCodec.ping(serviceID: endpoint.serviceID)))

        let heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.connectionGeneration == generation {
                do {
                    try await Task.sleep(for: .seconds(max(10, endpoint.pingInterval)))
                    let frame = FeishuFrameCodec.ping(serviceID: endpoint.serviceID)
                    try await socket.send(.data(frame))
                } catch {
                    return
                }
            }
        }
        defer {
            heartbeat.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }

        var fragments: [String: [Int: Data]] = [:]
        while !Task.isCancelled, generation == connectionGeneration {
            let message = try await socket.receive()
            switch message {
            case let .data(data):
                try await handleFrame(
                    data,
                    socket: socket,
                    fragments: &fragments
                )
            case let .string(text):
                // A few reverse proxies expose diagnostics as a text frame.
                // Ignore them; only the binary pbbp2 frame is actionable.
                _ = text
            @unknown default:
                break
            }
        }
    }

    private func handleFrame(
        _ data: Data,
        socket: URLSessionWebSocketTask,
        fragments: inout [String: [Int: Data]]
    ) async throws {
        let frame = try FeishuFrameCodec.decode(data)
        let type = frame.headers.first(where: { $0.key == "type" })?.value
        if frame.method == 0 {
            return
        }
        guard type == "event" else { return }

        let headers = Dictionary(uniqueKeysWithValues: frame.headers.map { ($0.key, $0.value) })
        let messageID = headers["message_id"] ?? UUID().uuidString
        let sequence = max(0, Int(headers["seq"] ?? "0") ?? 0)
        let total = max(1, Int(headers["sum"] ?? "1") ?? 1)
        var parts = fragments[messageID] ?? [:]
        parts[sequence] = frame.payload
        fragments[messageID] = parts
        guard parts.count >= total, (0..<total).allSatisfy({ parts[$0] != nil }) else { return }
        fragments.removeValue(forKey: messageID)

        let payload = (0..<total).compactMap { parts[$0] }.reduce(into: Data()) { $0.append($1) }
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let action = Self.parseApprovalAction(object, settings: settings) {
            complete(action.requestID, decision: action.decision)
        }

        var responseHeaders = frame.headers
        responseHeaders.append(.init(key: "biz_rt", value: "0"))
        let response = FeishuFrameCodec.Frame(
            sequenceID: frame.sequenceID,
            logID: frame.logID,
            serviceID: frame.serviceID,
            method: 1,
            headers: responseHeaders,
            payload: Data(#"{"code":200}"#.utf8)
        )
        try await socket.send(.data(FeishuFrameCodec.encode(response)))
    }

    private func complete(_ requestID: String, decision: PermissionDecision) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
        let messageID = messageIDs.removeValue(forKey: requestID)
        entry.completion(decision)
        guard let messageID else { return }
        Task { @MainActor [weak self] in
            try? await self?.updateCard(messageID: messageID, request: entry.request, decision: decision)
        }
    }

    private func sendApprovalCard(for request: PermissionRequest) async throws -> String {
        let content = try JSONSerialization.data(withJSONObject: Self.approvalCard(for: request))
        let object = try await apiRequest(
            method: "POST",
            path: "/open-apis/im/v1/messages?receive_id_type=\(settings.feishuApproverIDType)",
            body: [
                "receive_id": settings.feishuApproverID ?? "",
                "msg_type": "interactive",
                "content": String(decoding: content, as: UTF8.self)
            ],
            requiresToken: true
        )
        guard let messageID = (object["data"] as? [String: Any])?["message_id"] as? String,
              !messageID.isEmpty else { throw TransportError.invalidResponse }
        return messageID
    }

    private func updateCard(messageID: String, request: PermissionRequest, decision: PermissionDecision) async throws {
        let content = try JSONSerialization.data(withJSONObject: Self.statusCard(for: request, decision: decision))
        _ = try await apiRequest(
            method: "PATCH",
            path: "/open-apis/im/v1/messages/\(messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageID)",
            body: ["content": String(decoding: content, as: UTF8.self)],
            requiresToken: true
        )
    }

    private func fetchConnectionEndpoint() async throws -> ConnectionEndpoint {
        let object = try await apiRequest(
            method: "POST",
            path: "/open-apis/callback/ws/endpoint",
            body: [
                "AppID": settings.feishuAppID ?? "",
                "AppSecret": settings.feishuAppSecret ?? ""
            ],
            requiresToken: false
        )
        guard let data = object["data"] as? [String: Any],
              let urlString = data["URL"] as? String,
              let url = URL(string: urlString),
              url.scheme == "wss" || url.scheme == "ws" else {
            throw TransportError.invalidEndpoint
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let serviceID = Int(query.first(where: { $0.name == "service_id" })?.value ?? "0") ?? 0
        let clientConfig = data["ClientConfig"] as? [String: Any]
        let pingInterval = (clientConfig?["PingInterval"] as? NSNumber)?.doubleValue ?? 120
        return ConnectionEndpoint(url: url, serviceID: serviceID, pingInterval: pingInterval)
    }

    private func accessTokenValue() async throws -> String {
        if let accessToken, accessTokenExpiresAt > Date.now.addingTimeInterval(30) {
            return accessToken
        }
        let object = try await apiRequest(
            method: "POST",
            path: "/open-apis/auth/v3/tenant_access_token/internal",
            body: [
                "app_id": settings.feishuAppID ?? "",
                "app_secret": settings.feishuAppSecret ?? ""
            ],
            requiresToken: false
        )
        guard let token = object["tenant_access_token"] as? String, !token.isEmpty else {
            throw TransportError.invalidResponse
        }
        let expires = (object["expire"] as? NSNumber)?.doubleValue ?? 7_200
        accessToken = token
        accessTokenExpiresAt = Date.now.addingTimeInterval(max(60, expires))
        return token
    }

    private func apiRequest(
        method: String,
        path: String,
        body: [String: Any],
        requiresToken: Bool
    ) async throws -> [String: Any] {
        guard isConfigured || path.contains("tenant_access_token") || path.contains("callback/ws") else {
            throw TransportError.notConfigured
        }
        guard let url = URL(string: apiHost + path), JSONSerialization.isValidJSONObject(body) else {
            throw TransportError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Clawdesk/0.1", forHTTPHeaderField: "User-Agent")
        if requiresToken { request.setValue("Bearer \(try await accessTokenValue())", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? NSNumber, code.intValue == 0 else {
            throw TransportError.invalidResponse
        }
        return object
    }

    static func approvalCard(for request: PermissionRequest) -> [String: Any] {
        // Same egress rule as Telegram: redacted title + action + a
        // path/URL fallback only. Commands and raw tool input never leave
        // the desktop.
        var lines = [
            "Clawdesk permission request",
            bounded(SecretRedactor.redact(request.title), maxLength: 900)
        ]
        if let action = request.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            lines.append("Action: \(bounded(action, maxLength: 120))")
        }
        if let detail = RemoteNotifier.fallbackDetail(from: request.input) {
            lines.append("Target: \(bounded(detail, maxLength: 300))")
        }
        return card(title: "Permission request", detail: lines.joined(separator: "\n"), decision: nil, requestID: request.id)
    }

    private static func statusCard(for request: PermissionRequest, decision: PermissionDecision) -> [String: Any] {
        let label: String
        switch decision {
        case .allow: label = "Allowed from Clawdesk"
        case .deny: label = "Denied from Clawdesk"
        case .defer: label = "Returned to desktop"
        }
        return card(
            title: "Permission request · \(label)",
            detail: bounded(SecretRedactor.redact(request.title), maxLength: 1_200),
            decision: decision,
            requestID: request.id
        )
    }

    private static func card(
        title: String,
        detail: String,
        decision: PermissionDecision?,
        requestID: String
    ) -> [String: Any] {
        var elements: [[String: Any]] = [["tag": "markdown", "content": bounded(detail, maxLength: 3_000)]]
        if decision == nil {
            elements.append([
                "tag": "action",
                "actions": [
                    [
                        "tag": "button",
                        "text": ["tag": "plain_text", "content": "Allow"],
                        "type": "primary",
                        "value": ["requestID": requestID, "decision": "allow"]
                    ],
                    [
                        "tag": "button",
                        "text": ["tag": "plain_text", "content": "Deny"],
                        "type": "danger",
                        "value": ["requestID": requestID, "decision": "deny"]
                    ]
                ]
            ])
        }
        return [
            "schema": "2.0",
            "config": ["wide_screen_mode": true],
            "header": [
                "template": decision == .allow ? "green" : decision == .deny ? "red" : "orange",
                "title": ["tag": "plain_text", "content": bounded(title, maxLength: 120)]
            ],
            "body": ["elements": elements]
        ]
    }

    internal static func parseApprovalAction(
        _ object: [String: Any],
        settings: RemoteChannelSettings
    ) -> (requestID: String, decision: PermissionDecision)? {
        let event = object["event"] as? [String: Any] ?? object
        let action = event["action"] as? [String: Any] ?? object["action"] as? [String: Any] ?? [:]
        let valueObject: [String: Any]
        if let value = action["value"] as? [String: Any] {
            valueObject = value
        } else if let value = action["value"] as? String,
                  let data = value.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            valueObject = parsed
        } else {
            valueObject = [:]
        }
        guard let requestID = (valueObject["requestID"] as? String) ?? (valueObject["requestId"] as? String),
              !requestID.isEmpty else { return nil }
        let decision: PermissionDecision
        switch (valueObject["decision"] as? String)?.lowercased() {
        case "allow", "approve": decision = .allow
        case "deny", "reject": decision = .deny
        default: return nil
        }

        let operatorID = operatorID(in: event, idType: settings.feishuApproverIDType)
        guard let expected = settings.feishuApproverID,
              let operatorID,
              operatorID == expected else { return nil }
        return (requestID, decision)
    }

    private static func operatorID(in event: [String: Any], idType: String) -> String? {
        let operatorObject = event["operator"] as? [String: Any]
            ?? event["operator_id"] as? [String: Any]
            ?? [:]
        let nested = operatorObject["operator_id"] as? [String: Any] ?? operatorObject
        return nested[idType] as? String
            ?? nested[idType.replacingOccurrences(of: "_", with: "")] as? String
            ?? nested["id"] as? String
    }

    private static func bounded(_ value: String, maxLength: Int) -> String {
        let clean = value.replacingOccurrences(of: "\u{0000}", with: " ")
        guard clean.count > maxLength else { return clean }
        return String(clean.prefix(maxLength - 1)) + "…"
    }
}

enum FeishuFrameCodec {
    struct Header: Equatable {
        let key: String
        let value: String
    }

    struct Frame: Equatable {
        let sequenceID: UInt64
        let logID: UInt64
        let serviceID: Int32
        let method: Int32
        let headers: [Header]
        let payload: Data
    }

    static func ping(serviceID: Int) -> Data {
        encode(Frame(
            sequenceID: 0,
            logID: 0,
            serviceID: Int32(serviceID),
            method: 0,
            headers: [Header(key: "type", value: "ping")],
            payload: Data()
        ))
    }

    static func encode(_ frame: Frame) -> Data {
        var data = Data()
        appendVarint(8, to: &data)
        appendVarint(frame.sequenceID, to: &data)
        appendVarint(16, to: &data)
        appendVarint(frame.logID, to: &data)
        appendVarint(24, to: &data)
        appendVarint(UInt64(bitPattern: Int64(frame.serviceID)), to: &data)
        appendVarint(32, to: &data)
        appendVarint(UInt64(bitPattern: Int64(frame.method)), to: &data)
        for header in frame.headers {
            var nested = Data()
            appendStringField(1, value: header.key, to: &nested)
            appendStringField(2, value: header.value, to: &nested)
            appendLengthField(5, value: nested, to: &data)
        }
        if !frame.payload.isEmpty { appendLengthField(8, value: frame.payload, to: &data) }
        return data
    }

    static func decode(_ data: Data) throws -> Frame {
        var reader = Reader(bytes: Array(data))
        var sequenceID: UInt64 = 0
        var logID: UInt64 = 0
        var serviceID: Int32 = 0
        var method: Int32 = 0
        var headers: [Header] = []
        var payload = Data()
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let field = Int(tag >> 3)
            switch field {
            case 1: sequenceID = try reader.readVarint()
            case 2: logID = try reader.readVarint()
            case 3: serviceID = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            case 4: method = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            case 5:
                let nested = try reader.readBytes()
                headers.append(try decodeHeader(nested))
            case 8: payload = try reader.readBytes()
            default: try reader.skip(wireType: Int(tag & 0x7))
            }
        }
        return Frame(sequenceID: sequenceID, logID: logID, serviceID: serviceID, method: method, headers: headers, payload: payload)
    }

    private static func decodeHeader(_ data: Data) throws -> Header {
        var reader = Reader(bytes: Array(data))
        var key = ""
        var value = ""
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            switch Int(tag >> 3) {
            case 1: key = try reader.readString()
            case 2: value = try reader.readString()
            default: try reader.skip(wireType: Int(tag & 0x7))
            }
        }
        return Header(key: key, value: value)
    }

    private static func appendStringField(_ field: Int, value: String, to data: inout Data) {
        appendLengthField(field, value: Data(value.utf8), to: &data)
    }

    private static func appendLengthField(_ field: Int, value: Data, to data: inout Data) {
        appendVarint(UInt64(field << 3 | 2), to: &data)
        appendVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        mutating func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard index < bytes.count else { throw FeishuApprovalTransportError.invalidFrame }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            throw FeishuApprovalTransportError.invalidFrame
        }

        mutating func readBytes() throws -> Data {
            let length = Int(try readVarint())
            guard length >= 0, index + length <= bytes.count else { throw FeishuApprovalTransportError.invalidFrame }
            defer { index += length }
            return Data(bytes[index..<(index + length)])
        }

        mutating func readString() throws -> String {
            guard let string = String(data: try readBytes(), encoding: .utf8) else {
                throw FeishuApprovalTransportError.invalidFrame
            }
            return string
        }

        mutating func skip(wireType: Int) throws {
            switch wireType {
            case 0: _ = try readVarint()
            case 1: index += 8
            case 2: _ = try readBytes()
            case 5: index += 4
            default: throw FeishuApprovalTransportError.invalidFrame
            }
            guard index <= bytes.count else { throw FeishuApprovalTransportError.invalidFrame }
        }
    }
}

private enum FeishuApprovalTransportError: Error {
    case invalidFrame
}
