import Foundation
@preconcurrency import Network
import Darwin

/// A deliberately small, read-only LAN companion. The bridge serves the
/// embedded mobile page over HTTP and exposes the upstream v1 WebSocket
/// protocol on the same port. The HTTP snapshot endpoint remains as a
/// compatibility fallback for browsers that cannot keep a socket open.
public final class MobileBridge: @unchecked Sendable {
    public let tokenURL: URL

    private let homeDirectory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.clawdesk.mobile-bridge", qos: .utility)
    private let stateLock = NSLock()
    private let snapshotLock = NSLock()
    private let tokenLock = NSLock()
    private var listener: NWListener?
    private var currentPort: UInt16
    private var running = false
    private var snapshotData = Data("{\"version\":\"v1\",\"type\":\"snapshot\",\"timestamp\":0,\"state\":\"idle\",\"sessions\":{},\"quota\":[]}".utf8)
    private var snapshotSessions: [String: Data] = [:]
    private var token: String
    private var websocketClients: [ObjectIdentifier: WebSocketClient] = [:]
    private var heartbeatTimer: DispatchSourceTimer?

    private final class WebSocketClient: @unchecked Sendable {
        let connection: NWConnection
        var receiveBuffer = Data()
        var messageCount = 0
        var windowStartedAt = Date.now
        var lastPong = Date.now

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private struct SanitizedSnapshot {
        let object: [String: Any]
        let sessions: [String: Data]
    }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        preferredPort: UInt16 = 23334
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        currentPort = preferredPort
        let directory = homeDirectory.appendingPathComponent("Library/Application Support/Clawdesk", isDirectory: true)
        tokenURL = directory.appendingPathComponent("mobile-token.json")
        token = Self.loadOrCreateToken(at: tokenURL, fileManager: fileManager)
    }

    public var accessToken: String {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return token
    }

    public var port: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentPort
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.closeAllWebSocketClients(code: 1001, reason: "Server shutting down")
            self?.heartbeatTimer?.cancel()
            self?.heartbeatTimer = nil
            self?.listener?.stateUpdateHandler = nil
            self?.listener?.newConnectionHandler = nil
            self?.listener?.cancel()
            self?.listener = nil
            self?.setRunning(false)
        }
    }

    @discardableResult
    public func rotateToken() -> String {
        let next = Self.randomToken()
        tokenLock.lock()
        token = next
        tokenLock.unlock()
        persistToken(next)
        queue.async { [weak self] in
            self?.closeAllWebSocketClients(code: 1008, reason: "clawdesk-token:\(next)")
        }
        return next
    }

    public func updateSnapshot(_ object: [String: Any]) {
        let sanitized = sanitize(object)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized.object, options: [.sortedKeys]) else { return }

        var stateMessages: [Data] = []
        var deletedSessionIDs: [String] = []
        snapshotLock.lock()
        let previousSessions = snapshotSessions
        snapshotData = data
        snapshotSessions = sanitized.sessions
        for (sessionID, sessionData) in sanitized.sessions {
            if previousSessions[sessionID] != sessionData,
               let sessionObject = try? JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
               let message = Self.makeMessage(type: "state", payload: ["sessionId": sessionID, "data": sessionObject]) {
                stateMessages.append(message)
            }
        }
        deletedSessionIDs = previousSessions.keys.filter { sanitized.sessions[$0] == nil }
        snapshotLock.unlock()

        guard !stateMessages.isEmpty || !deletedSessionIDs.isEmpty else { return }
        let pendingStateMessages = stateMessages
        let pendingDeletedSessionIDs = deletedSessionIDs
        queue.async { [weak self] in
            guard let self else { return }
            for message in pendingStateMessages { self.broadcast(message) }
            for sessionID in pendingDeletedSessionIDs {
                if let message = Self.makeMessage(type: "session_deleted", payload: ["sessionId": sessionID]) {
                    self.broadcast(message)
                }
            }
        }
    }

    public func pairingURL() -> URL? {
        guard let address = Self.lanAddress(), var components = URLComponents(string: "http://\(address):\(port)/mobile/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "host", value: address),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: accessToken)
        ]
        return components.url
    }

    private func setPort(_ value: UInt16) {
        stateLock.lock()
        currentPort = value
        stateLock.unlock()
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        for offset in 0...10 {
            let candidateValue = Int(port) + offset
            guard candidateValue <= Int(UInt16.max), let candidate = NWEndpoint.Port(rawValue: UInt16(candidateValue)) else { continue }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: candidate)
            do {
                let candidateListener = try NWListener(using: parameters)
                candidateListener.stateUpdateHandler = { [weak self, weak candidateListener] state in
                    if case .ready = state, let actual = candidateListener?.port?.rawValue {
                        self?.setPort(actual)
                    }
                }
                candidateListener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                candidateListener.start(queue: queue)
                listener = candidateListener
                setRunning(true)
                return
            } catch {
                continue
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .failed, .cancelled:
                connection?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            let combined = buffer + (data ?? Data())
            guard let self else { connection.cancel(); return }
            if let request = self.parse(combined) {
                self.handle(request, on: connection)
            } else if !isComplete, error == nil, combined.count < 32 * 1024 {
                self.receive(on: connection, buffer: combined)
            } else {
                connection.cancel()
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    private func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data.prefix(upTo: end.lowerBound), encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2 { result[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespaces) }
        }
        let rawURL = String(parts[1])
        let pieces = rawURL.split(separator: "?", maxSplits: 1).map(String.init)
        let query = (pieces.count == 2 ? pieces[1] : "").split(separator: "&").reduce(into: [String: String]()) { result, pair in
            let pairParts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = pairParts.first else { return }
            result[key] = pairParts.count == 2 ? (pairParts[1].removingPercentEncoding ?? pairParts[1]) : ""
        }
        return Request(method: String(parts[0]), path: pieces[0], query: query, headers: headers)
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        if request.method == "GET",
           request.path == "/ws",
           request.headers["upgrade"]?.lowercased() == "websocket" {
            upgradeWebSocket(request, on: connection)
            return
        }

        guard request.method == "GET" else {
            sendJSON(["ok": false, "error": "read_only"], status: 405, on: connection)
            return
        }
        let suppliedToken = request.query["token"] ?? request.headers["x-clawdesk-token"]
        if request.path == "/health" {
            sendJSON(["ok": true, "name": "Clawdesk Mobile Bridge", "port": Int(port)], on: connection)
            return
        }

        if request.path == "/api/connection-info" {
            let address = Self.lanAddress() ?? "127.0.0.1"
            sendJSON([
                "status": listener == nil ? "starting" : "ok",
                "lanIp": address,
                "port": Int(port)
            ], on: connection)
            return
        }

        guard suppliedToken == accessToken else {
            sendJSON(["ok": false, "error": "unauthorized"], status: 401, on: connection)
            return
        }
        if request.path == "/mobile" || request.path == "/mobile/" {
            let token = request.query["token"] ?? accessToken
            sendBytes(Data(Self.mobileHTML(token: token).utf8), contentType: "text/html; charset=utf-8", on: connection)
            return
        }
        if request.path == "/mobile/sessions" {
            snapshotLock.lock()
            let data = snapshotData
            snapshotLock.unlock()
            sendBytes(data, contentType: "application/json", on: connection)
            return
        }
        sendJSON(["ok": false, "error": "not_found"], status: 404, on: connection)
    }

    private func upgradeWebSocket(_ request: Request, on connection: NWConnection) {
        guard let key = request.headers["sec-websocket-key"], !key.isEmpty else {
            sendJSON(["ok": false, "error": "missing_websocket_key"], status: 400, on: connection)
            return
        }
        guard request.headers["sec-websocket-version"] == nil || request.headers["sec-websocket-version"] == "13" else {
            sendJSON(["ok": false, "error": "unsupported_websocket_version"], status: 426, on: connection)
            return
        }
        guard request.query["token"] == accessToken else {
            sendJSON(["ok": false, "error": "unauthorized"], status: 401, on: connection)
            return
        }
        guard websocketClients.count < 10 else {
            sendJSON(["ok": false, "error": "server_busy"], status: 503, on: connection)
            return
        }

        let accept = Self.webSocketAccept(for: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        let client = WebSocketClient(connection: connection)
        let identifier = ObjectIdentifier(client)
        snapshotLock.lock()
        let snapshot = snapshotData
        snapshotLock.unlock()
        let initialResponse = Data(response.utf8) + Self.webSocketFrame(opcode: 0x1, payload: snapshot)
        websocketClients[identifier] = client
        startHeartbeatIfNeeded()
        connection.send(content: initialResponse, completion: .contentProcessed { [weak self, weak client] error in
            guard error != nil else { return }
            if let self, let client {
                self.removeWebSocketClient(client, cancel: true)
            } else {
                connection.cancel()
            }
        })
        receiveWebSocket(client)
    }

    private func receiveWebSocket(_ client: WebSocketClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let data { client.receiveBuffer.append(data) }
            if !self.processWebSocketFrames(for: client) {
                self.removeWebSocketClient(client, cancel: false)
                return
            }
            if !isComplete, error == nil, self.websocketClients[ObjectIdentifier(client)] != nil {
                self.receiveWebSocket(client)
            } else {
                self.removeWebSocketClient(client, cancel: false)
            }
        }
    }

    private func processWebSocketFrames(for client: WebSocketClient) -> Bool {
        while let frame = nextWebSocketFrame(from: client.receiveBuffer) {
            client.receiveBuffer.removeFirst(frame.consumed)
            switch frame.opcode {
            case 0x8: // close
                sendWebSocketFrame(opcode: 0x8, payload: frame.payload.prefix(2), to: client)
                removeWebSocketClient(client, cancel: false)
                return false
            case 0x9: // ping
                sendWebSocketFrame(opcode: 0xA, payload: frame.payload, to: client)
            case 0xA: // pong
                client.lastPong = .now
            case 0x1, 0x2, 0x0:
                let now = Date.now
                if now.timeIntervalSince(client.windowStartedAt) >= 60 {
                    client.windowStartedAt = now
                    client.messageCount = 0
                }
                client.messageCount += 1
                if client.messageCount > 60 {
                    sendWebSocketClose(code: 1008, reason: "Rate limit", to: client)
                    removeWebSocketClient(client, cancel: false)
                    return false
                }
                // Protocol v1 is read-only. Valid client messages, including
                // token acknowledgements from newer clients, are intentionally
                // ignored after rate accounting.
            default:
                sendWebSocketClose(code: 1002, reason: "Unsupported frame", to: client)
                removeWebSocketClient(client, cancel: false)
                return false
            }
        }
        return true
    }

    private struct WebSocketFrame {
        let opcode: UInt8
        let payload: Data
        let consumed: Int
    }

    private func nextWebSocketFrame(from data: Data) -> WebSocketFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let first = bytes[0]
        let second = bytes[1]
        let masked = second & 0x80 != 0
        guard masked else { return WebSocketFrame(opcode: 0xFF, payload: Data(), consumed: data.count) }
        var length = UInt64(second & 0x7F)
        var index = 2
        if length == 126 {
            guard bytes.count >= index + 2 else { return nil }
            length = UInt64(bytes[index]) << 8 | UInt64(bytes[index + 1])
            index += 2
        } else if length == 127 {
            guard bytes.count >= index + 8 else { return nil }
            length = 0
            for _ in 0..<8 { length = (length << 8) | UInt64(bytes[index]); index += 1 }
            guard length <= 1_048_576 else { return WebSocketFrame(opcode: 0xFF, payload: Data(), consumed: data.count) }
        }
        guard length <= UInt64(Int.max), bytes.count >= index + 4 else { return nil }
        let mask = Array(bytes[index..<(index + 4)])
        index += 4
        let payloadLength = Int(length)
        guard bytes.count >= index + payloadLength else { return nil }
        var payload = Array(bytes[index..<(index + payloadLength)])
        for offset in payload.indices { payload[offset] ^= mask[offset % 4] }
        return WebSocketFrame(opcode: first & 0x0F, payload: Data(payload), consumed: index + payloadLength)
    }

    private func sendWebSocketFrame(opcode: UInt8, payload: Data, to client: WebSocketClient) {
        let frame = Self.webSocketFrame(opcode: opcode, payload: payload)
        client.connection.send(content: frame, completion: .contentProcessed { [weak self, weak client] error in
            guard let client else { return }
            if opcode == 0x8 || error != nil {
                if let self { self.removeWebSocketClient(client, cancel: true) }
                else { client.connection.cancel() }
            }
        })
    }

    private func sendWebSocketClose(code: UInt16, reason: String, to client: WebSocketClient) {
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        payload.append(contentsOf: reason.data(using: .utf8) ?? Data())
        sendWebSocketFrame(opcode: 0x8, payload: payload, to: client)
    }

    private func broadcast(_ message: Data) {
        for client in websocketClients.values {
            sendWebSocketFrame(opcode: 0x1, payload: message, to: client)
        }
    }

    private func removeWebSocketClient(_ client: WebSocketClient, cancel: Bool) {
        websocketClients.removeValue(forKey: ObjectIdentifier(client))
        if cancel { client.connection.cancel() }
        if websocketClients.isEmpty {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
    }

    private func closeAllWebSocketClients(code: UInt16, reason: String) {
        let clients = Array(websocketClients.values)
        for client in clients {
            sendWebSocketClose(code: code, reason: reason, to: client)
            removeWebSocketClient(client, cancel: false)
        }
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date.now
            for client in Array(self.websocketClients.values) {
                if now.timeIntervalSince(client.lastPong) > 90 {
                    self.removeWebSocketClient(client, cancel: true)
                    continue
                }
                self.sendWebSocketFrame(opcode: 0x9, payload: Data(), to: client)
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendJSON(_ object: [String: Any], status: Int = 200, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        sendBytes(body, contentType: "application/json", status: status, on: connection)
    }

    private func sendBytes(_ body: Data, contentType: String, status: Int = 200, on connection: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 405: reason = "Method Not Allowed"
        case 426: reason = "Upgrade Required"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sanitize(_ object: [String: Any]) -> SanitizedSnapshot {
        var sessionObjects: [String: [String: Any]] = [:]
        for session in object["sessions"] as? [[String: Any]] ?? [] {
            let sessionID = session["id"] as? String ?? ""
            guard !sessionID.isEmpty else { continue }
            let state = session["state"] as? String ?? "idle"
            var safe: [String: Any] = [
                "sessionId": sessionID,
                "title": String((session["title"] as? String ?? "Agent session").prefix(120)),
                "state": state,
                "agentId": session["agentID"] as? String ?? "custom",
                "lastEvent": String((session["lastEvent"] as? String ?? "").prefix(80)),
                "updatedAt": session["lastActivity"] as? Double ?? 0
            ]
            if let folder = session["folder"] as? String, !folder.isEmpty {
                safe["basename"] = URL(fileURLWithPath: folder).lastPathComponent
            }
            if let subagents = session["subagentCount"] as? Int { safe["subagentCount"] = subagents }
            if let context = session["contextUsage"] as? [String: Any],
               let used = context["used"] as? Double,
               used.isFinite,
               used >= 0 {
                var safeContext: [String: Any] = ["used": used]
                if let limit = context["limit"] as? Double, limit.isFinite, limit > 0 {
                    safeContext["limit"] = limit
                }
                if let percent = context["percent"] as? Int {
                    safeContext["percent"] = min(100, max(0, percent))
                }
                if let source = context["source"] as? String, !source.isEmpty {
                    safeContext["source"] = String(source.prefix(40))
                }
                safe["contextUsage"] = safeContext
            }
            let events = (session["recentEvents"] as? [String] ?? []).suffix(10).map { event in
                ["event": String(event.prefix(80)), "at": safe["updatedAt"] as? Double ?? 0, "state": state] as [String: Any]
            }
            safe["recentEvents"] = events
            sessionObjects[sessionID] = safe
        }

        let quotaObjects: [[String: Any]] = (object["quota"] as? [[String: Any]] ?? []).compactMap { report in
            guard let provider = report["provider"] as? String, !provider.isEmpty else { return nil }
            let buckets: [[String: Any]] = (report["buckets"] as? [[String: Any]] ?? []).compactMap { bucket in
                guard let id = bucket["id"] as? String,
                      let usedPercent = bucket["usedPercent"] as? Int else { return nil }
                var safeBucket: [String: Any] = [
                    "id": String(id.prefix(40)),
                    "usedPercent": min(100, max(0, usedPercent))
                ]
                if let window = bucket["window"] as? String { safeBucket["window"] = String(window.prefix(16)) }
                if let windowMinutes = bucket["windowMinutes"] as? Int, windowMinutes > 0 {
                    safeBucket["windowMinutes"] = min(windowMinutes, 1_000_000)
                }
                if let resetAt = bucket["resetAt"] as? Double, resetAt.isFinite {
                    safeBucket["resetAt"] = resetAt
                }
                return safeBucket
            }
            guard !buckets.isEmpty else { return nil }
            return [
                "provider": String(provider.prefix(40)),
                "label": String((report["label"] as? String ?? provider).prefix(80)),
                "capturedAt": report["capturedAt"] as? Double ?? 0,
                "buckets": buckets
            ]
        }

        let sessionData = sessionObjects.compactMapValues { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let object: [String: Any] = [
            "version": "v1",
            "type": "snapshot",
            "timestamp": Date.now.timeIntervalSince1970 * 1000,
            "state": object["state"] as? String ?? "idle",
            "sessions": sessionObjects,
            "quota": quotaObjects
        ]
        return SanitizedSnapshot(object: object, sessions: sessionData)
    }

    private static func makeMessage(type: String, payload: [String: Any]) -> Data? {
        var message: [String: Any] = [
            "version": "v1",
            "type": type,
            "timestamp": Date.now.timeIntervalSince1970 * 1000
        ]
        for (key, value) in payload { message[key] = value }
        return try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    }

    private static func webSocketFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | (opcode & 0x0F)])
        switch payload.count {
        case 0...125:
            frame.append(UInt8(payload.count))
        case 126...65_535:
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    private static func sha1Base64(_ string: String) -> String {
        let digest = sha1(Array(string.utf8))
        return Data(digest).base64EncodedString()
    }

    static func webSocketAccept(for key: String) -> String {
        sha1Base64(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    }

    private static func sha1(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = UInt32(message[offset]) << 24
                    | UInt32(message[offset + 1]) << 16
                    | UInt32(message[offset + 2]) << 8
                    | UInt32(message[offset + 3])
            }
            for index in 16..<80 {
                words[index] = words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]
                words[index] = (words[index] << 1) | (words[index] >> 31)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4
            for index in 0..<80 {
                let (function, constant): (UInt32, UInt32)
                switch index {
                case 0..<20: (function, constant) = ((b & c) | ((~b) & d), 0x5A827999)
                case 20..<40: (function, constant) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (function, constant) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (function, constant) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let rotated = (a << 5) | (a >> 27)
                let temporary = rotated &+ function &+ e &+ constant &+ words[index]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temporary
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }

        return [
            UInt8(truncatingIfNeeded: h0 >> 24), UInt8(truncatingIfNeeded: h0 >> 16), UInt8(truncatingIfNeeded: h0 >> 8), UInt8(truncatingIfNeeded: h0),
            UInt8(truncatingIfNeeded: h1 >> 24), UInt8(truncatingIfNeeded: h1 >> 16), UInt8(truncatingIfNeeded: h1 >> 8), UInt8(truncatingIfNeeded: h1),
            UInt8(truncatingIfNeeded: h2 >> 24), UInt8(truncatingIfNeeded: h2 >> 16), UInt8(truncatingIfNeeded: h2 >> 8), UInt8(truncatingIfNeeded: h2),
            UInt8(truncatingIfNeeded: h3 >> 24), UInt8(truncatingIfNeeded: h3 >> 16), UInt8(truncatingIfNeeded: h3 >> 8), UInt8(truncatingIfNeeded: h3),
            UInt8(truncatingIfNeeded: h4 >> 24), UInt8(truncatingIfNeeded: h4 >> 16), UInt8(truncatingIfNeeded: h4 >> 8), UInt8(truncatingIfNeeded: h4)
        ]
    }

    private func persistToken(_ value: String) {
        do {
            try fileManager.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let object: [String: Any] = ["version": 1, "token": value, "updatedAt": Date.now.timeIntervalSince1970]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: tokenURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        } catch {
            // The in-memory token remains valid for the current process. The
            // next restart will generate a new token rather than persisting a
            // potentially exposed fallback.
        }
    }

    private static func loadOrCreateToken(at url: URL, fileManager: FileManager) -> String {
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["token"] as? String,
           value.count == 32,
           value.allSatisfy({ $0.isHexDigit }) {
            return value.lowercased()
        }
        let value = randomToken()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let object: [String: Any] = ["version": 1, "token": value, "updatedAt": Date.now.timeIntervalSince1970]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // The generated value still gates this process.
        }
        return value
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...UInt8.max, using: &generator)) }.joined()
    }

    private static func lanAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let flags = Int32(entry.pointee.ifa_flags)
            if flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var socketAddress = address.pointee
                if getnameinfo(&socketAddress, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            current = entry.pointee.ifa_next
        }
        return nil
    }

    private static func mobileHTML(token: String) -> String {
        """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#111">
        <title>Clawdesk Mobile</title>
        <style>body{font:16px -apple-system;background:#111;color:#f4f4f4;margin:0;padding:20px}h1{font-size:22px}.card{background:#222;border:1px solid #444;border-radius:14px;padding:14px;margin:10px 0}.state{color:#ff9a3d;font-weight:700}.muted{color:#aaa;font-size:13px}</style>
        <h1>🦀 Clawdesk</h1><div id="app">Connecting…</div>
        <script>
        let token=\"\(token)\";
        const app=document.querySelector('#app');
        function render(s){const entries=Object.values(s.sessions||{});app.innerHTML='<p class="state">'+(s.state||'idle')+'</p>'+(entries.length?entries.map(x=>'<div class="card"><b>'+String(x.title||'Agent session')+'</b><br><span class="state">'+String(x.state||'idle')+'</span><br><span class="muted">'+String(x.basename||x.agentId||'')+'</span></div>').join(''):'<p class="muted">No live sessions</p>')}
        function poll(){fetch('/mobile/sessions?token='+encodeURIComponent(token),{cache:'no-store'}).then(r=>r.json()).then(render).catch(()=>{app.textContent='Clawdesk is offline'})}
        function connect(){const ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws?token='+encodeURIComponent(token));ws.onmessage=e=>{const m=JSON.parse(e.data);if(m.type==='snapshot')render(m);if(m.type==='state')poll();if(m.type==='session_deleted')poll()};ws.onclose=e=>{const prefix='clawdesk-token:';if(e.reason&&e.reason.startsWith(prefix)){token=e.reason.slice(prefix.length)}setTimeout(connect,2000)};ws.onerror=()=>ws.close()}
        connect();poll();
        </script>
        """
    }
}
