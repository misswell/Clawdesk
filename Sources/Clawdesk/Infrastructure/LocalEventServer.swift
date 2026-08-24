import Foundation
@preconcurrency import Network

public enum PermissionDecision: String, Equatable, Sendable {
    case allow
    case deny
    case `defer`
}

public enum LocalEventServerError: LocalizedError, Equatable, Sendable {
    case invalidRemoteNonce
    case remoteIngressUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidRemoteNonce: return "The remote SSH routing nonce is invalid."
        case .remoteIngressUnavailable: return "No loopback port was available for the remote SSH ingress."
        }
    }
}

public final class PermissionReply: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResolved = false
    private let resolver: @Sendable (PermissionDecision) -> Void

    public init(resolver: @escaping @Sendable (PermissionDecision) -> Void) {
        self.resolver = resolver
    }

    public func resolve(_ decision: PermissionDecision) {
        lock.lock()
        guard !hasResolved else {
            lock.unlock()
            return
        }
        hasResolved = true
        lock.unlock()
        resolver(decision)
    }
}

private final class RemoteIngressStartState: @unchecked Sendable {
    var completed = false
}

public enum ServerMessage: @unchecked Sendable {
    case event(AgentEvent)
    case permission(AgentEvent, PermissionReply)
}

public final class LocalEventServer: @unchecked Sendable {
    public typealias MessageHandler = @Sendable (ServerMessage) -> Void

    public private(set) var port: UInt16
    public var onMessage: MessageHandler?

    private let queue = DispatchQueue(label: "com.clawdesk.local-event-server", qos: .utility)
    private let snapshotLock = NSLock()
    private let remoteNonceLock = NSLock()
    private var listener: NWListener?
    private var remoteIngressListeners: [String: NWListener] = [:]
    private var remoteIngressPorts: [String: UInt16] = [:]
    private var snapshotData = Data("{\"sessions\":[],\"state\":\"idle\"}".utf8)
    private var remoteNonces = Set<String>()
    private let quotaAdapter: any AgentQuotaAdapter
    private let eventAdapter: any AgentEventAdapter

    public init(
        preferredPort: UInt16 = 37777,
        quotaAdapter: any AgentQuotaAdapter = DefaultAgentQuotaAdapter(),
        eventAdapter: any AgentEventAdapter = DefaultAgentEventAdapter()
    ) {
        self.port = preferredPort
        self.quotaAdapter = quotaAdapter
        self.eventAdapter = eventAdapter
    }

    public func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for listener in self.remoteIngressListeners.values { listener.cancel() }
            self.remoteIngressListeners.removeAll()
            self.remoteIngressPorts.removeAll()
        }
    }

    /// Starts a loopback-only listener dedicated to one Remote SSH profile.
    /// The reverse tunnel points at this listener rather than the general
    /// local event server, so an arbitrary process on the remote host cannot
    /// bypass the profile nonce by posting to a shared route.
    public func startRemoteIngress(
        nonce: String,
        completion: @escaping @Sendable (Result<UInt16, LocalEventServerError>) -> Void
    ) {
        queue.async { [weak self] in
            self?.startRemoteIngressOnQueue(nonce: nonce, completion: completion)
        }
    }

    public func stopRemoteIngress(nonce: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.remoteIngressListeners.removeValue(forKey: nonce)?.cancel()
            self.remoteIngressPorts.removeValue(forKey: nonce)
            self.unregisterRemoteNonce(nonce)
        }
    }

    public func updateSnapshot(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        snapshotLock.lock()
        snapshotData = data
        snapshotLock.unlock()
    }

    /// Registers the nonces used by managed reverse SSH tunnels. Local hooks
    /// continue to use the ordinary marker; a request explicitly marked as a
    /// remote ingress must prove it belongs to one of these profiles.
    public func registerRemoteNonce(_ nonce: String) {
        guard !nonce.isEmpty else { return }
        remoteNonceLock.lock()
        remoteNonces.insert(nonce)
        remoteNonceLock.unlock()
    }

    public func unregisterRemoteNonce(_ nonce: String) {
        remoteNonceLock.lock()
        remoteNonces.remove(nonce)
        remoteNonceLock.unlock()
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        for candidate in port...(port + 10) {
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            do {
                let candidateListener = try NWListener(using: parameters)
                candidateListener.stateUpdateHandler = { [weak self] state in
                    if case .ready = state, let actual = candidateListener.port?.rawValue {
                        self?.port = actual
                    }
                }
                candidateListener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                candidateListener.start(queue: queue)
                listener = candidateListener
                return
            } catch {
                continue
            }
        }
    }

    private func startRemoteIngressOnQueue(
        nonce: String,
        completion: @escaping @Sendable (Result<UInt16, LocalEventServerError>) -> Void,
        startingCandidate: Int = 37_800
    ) {
        guard Self.isValidRemoteNonce(nonce) else {
            completion(.failure(.invalidRemoteNonce))
            return
        }
        registerRemoteNonce(nonce)
        if let port = remoteIngressPorts[nonce] {
            completion(.success(port))
            return
        }
        guard remoteIngressListeners[nonce] == nil else { return }
        guard startingCandidate <= 37_900 else {
            completion(.failure(.remoteIngressUnavailable))
            return
        }

        let candidates = startingCandidate...37_900
        for candidate in candidates {
            guard candidate != Int(port),
                  let nwPort = NWEndpoint.Port(rawValue: UInt16(candidate)) else { continue }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
            guard let candidateListener = try? NWListener(using: parameters) else { continue }
            let startState = RemoteIngressStartState()
            candidateListener.stateUpdateHandler = { [weak self, weak candidateListener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !startState.completed, let actual = candidateListener?.port?.rawValue else { return }
                    startState.completed = true
                    self.remoteIngressPorts[nonce] = actual
                    completion(.success(actual))
                case let .failed(error):
                    guard !startState.completed else { return }
                    startState.completed = true
                    self.remoteIngressListeners.removeValue(forKey: nonce)
                    candidateListener?.cancel()
                    self.startRemoteIngressOnQueue(
                        nonce: nonce,
                        completion: completion,
                        startingCandidate: candidate + 1
                    )
                    _ = error
                case .cancelled:
                    guard !startState.completed else { return }
                    startState.completed = true
                    self.remoteIngressListeners.removeValue(forKey: nonce)
                    self.remoteIngressPorts.removeValue(forKey: nonce)
                    completion(.failure(.remoteIngressUnavailable))
                default:
                    break
                }
            }
            candidateListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, requiredRemoteNonce: nonce)
            }
            remoteIngressListeners[nonce] = candidateListener
            candidateListener.start(queue: queue)
            return
        }
        completion(.failure(.remoteIngressUnavailable))
    }

    private func accept(_ connection: NWConnection, requiredRemoteNonce: String? = nil) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), requiredRemoteNonce: requiredRemoteNonce)
    }

    private func receive(on connection: NWConnection, buffer: Data, requiredRemoteNonce: String? = nil) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            let combined = buffer + (data ?? Data())
            // The connection is loopback-only, but a misbehaving local
            // process must not be able to grow an unbounded receive buffer.
            // Cap the accumulated request at 512 KiB; anything larger is
            // either not a valid Clawdesk event or a broken client.
            if combined.count > 512 * 1024 {
                connection.cancel()
                return
            }
            if let request = self?.parseRequest(combined) {
                self?.handle(request, on: connection, requiredRemoteNonce: requiredRemoteNonce)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self?.receive(on: connection, buffer: combined, requiredRemoteNonce: requiredRemoteNonce)
        }
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    private func parseRequest(_ data: Data) -> ParsedRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2, pieces[0].lowercased() == "content-length" {
                contentLength = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let rawURL = String(parts[1])
        let urlParts = rawURL.split(separator: "?", maxSplits: 1).map(String.init)
        let path = urlParts.first ?? rawURL
        let query = (urlParts.count == 2 ? urlParts[1] : "")
            .split(separator: "&")
            .reduce(into: [String: String]()) { result, pair in
                let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = pieces.first else { return }
                result[key] = pieces.count == 2 ? pieces[1].removingPercentEncoding ?? pieces[1] : ""
            }
        return ParsedRequest(method: String(parts[0]), path: path, query: query, body: body)
    }

    private func handle(_ request: ParsedRequest, on connection: NWConnection, requiredRemoteNonce: String? = nil) {
        if let requiredRemoteNonce {
            let supplied = request.query["clawdesk-remote-nonce"] ?? ""
            guard request.query["clawdesk-remote-v1"] != nil, supplied == requiredRemoteNonce else {
                sendJSON(["ok": false, "error": "invalid_remote_nonce"], status: 404, on: connection)
                return
            }
            guard request.method == "POST", request.path == "/state" || request.path == "/permission" else {
                sendJSON(["ok": false, "error": "not_found"], status: 404, on: connection)
                return
            }
        }
        if request.query["clawdesk-remote-v1"] != nil {
            let nonce = request.query["clawdesk-remote-nonce"] ?? ""
            remoteNonceLock.lock()
            let accepted = remoteNonces.contains(nonce)
            remoteNonceLock.unlock()
            guard accepted else {
                sendJSON(["ok": false, "error": "invalid_remote_nonce"], status: 404, on: connection)
                return
            }
        }
        if request.method == "GET", request.path == "/health" {
            sendJSON(["ok": true, "name": "Clawdesk", "port": Int(port)], on: connection)
            return
        }
        if request.method == "GET", request.path == "/sessions" {
            snapshotLock.lock()
            let data = snapshotData
            snapshotLock.unlock()
            sendBytes(data, contentType: "application/json", on: connection)
            return
        }
        if request.method == "GET", request.path == "/mobile" {
            sendBytes(Data(Self.mobileHTML.utf8), contentType: "text/html; charset=utf-8", on: connection)
            return
        }
        guard request.method == "POST", request.path == "/state" || request.path == "/permission" else {
            sendJSON(["ok": false, "error": "not_found"], status: 404, on: connection)
            return
        }
        let object: [String: Any]
        if request.body.isEmpty {
            object = [:]
        } else if let decoded = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            object = decoded
        } else {
            sendJSON(["ok": false, "error": "invalid_json"], status: 400, on: connection)
            return
        }
        let event = makeEvent(from: object, query: request.query, forcePermission: request.path == "/permission", fallbackEvent: request.query["event"])
        if let permission = event.permission {
            let reply = PermissionReply { [weak connection] decision in
                guard let connection else { return }
                let response = self.eventAdapter.permissionResponse(
                    for: decision,
                    agentID: permission.agentID,
                    eventName: event.eventName
                )
                self.send(response, on: connection)
            }
            onMessage?(.permission(event, reply))
        } else {
            if request.path == "/permission" {
                let response = eventAdapter.permissionFallbackResponse(
                    agentID: event.agentID,
                    eventName: event.eventName
                )
                send(response, on: connection)
            } else {
                sendJSON(["ok": true], on: connection)
            }
            onMessage?(.event(event))
        }
    }

    private func makeEvent(from object: [String: Any], query: [String: String], forcePermission: Bool, fallbackEvent: String?) -> AgentEvent {
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if let value = object[key] as? NSNumber { return value.stringValue }
            }
            return nil
        }
        func int(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = object[key] as? Int { return value }
                if let value = object[key] as? NSNumber { return value.intValue }
                if let value = object[key] as? String, let parsed = Int(value) { return parsed }
            }
            return nil
        }

        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? String { return Double(value) }
            return nil
        }

        func bool(_ keys: [String]) -> Bool {
            for key in keys {
                if let value = object[key] as? Bool { return value }
                if let value = object[key] as? NSNumber { return value.boolValue }
                if let value = object[key] as? String {
                    if value.lowercased() == "true" || value == "1" { return true }
                }
            }
            return false
        }

        let rawSessionID = string(["session_id", "sessionId", "session", "id"]) ?? query["session_id"] ?? query["sessionId"] ?? UUID().uuidString
        let remotePrefix = query["remote_prefix"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = remotePrefix.isEmpty ? rawSessionID : "\(remotePrefix):\(rawSessionID)"
        let queryAgent = [query["agent_id"], query["agent"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let agentID = queryAgent ?? string(["agent_id", "agentId", "source", "agent"]) ?? "custom"
        let eventName = string(["event", "event_name", "eventName", "type", "name", "state"])
            ?? fallbackEvent
            ?? (forcePermission ? "PermissionRequest" : "Notification")
        let contextUsage: ContextUsage? = {
            let raw = object["context_usage"] ?? object["contextUsage"]
            let values = raw as? [String: Any]
            let window = object["context_window"] as? [String: Any]
            let current = window?["current_usage"] as? [String: Any]
            let usedFromComponents = current.map { usage -> Double? in
                let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                var total = 0.0
                for key in keys {
                    guard let value = usage[key] else { continue }
                    guard let number = number(value), number >= 0 else { return nil }
                    total += number
                }
                return total > 0 ? total : nil
            } ?? nil
            let used = number(values?["used"])
                ?? usedFromComponents
                ?? number(window?["used"])
            guard let used, used > 0 else { return nil }
            let limit = number(values?["limit"])
                ?? number(window?["context_window_size"])
            let percent = number(values?["percent"])
                ?? number(window?["used_percentage"])
            let normalizedAgent = agentID.lowercased()
            let source = string(["context_source", "contextSource"])
                ?? (values?["source"] as? String)
                ?? (normalizedAgent.contains("claude") ? "claude" : nil)
                ?? (normalizedAgent.contains("codex") ? "codex" : nil)
                ?? (normalizedAgent.contains("antigravity") ? "antigravity" : nil)
                ?? (normalizedAgent.contains("opencode") ? "opencode" : nil)
            return ContextUsage(
                used: used,
                limit: limit,
                percent: percent.map { Int($0.rounded()) },
                source: source
            )
        }()
        let metadataOnly = bool(["metadata_only", "metadataOnly"])
        let hint = string(["state", "pet_state", "petState"]).flatMap(normalizeState)
        let quotaObject = (object["rate_limits"] as? [String: Any])
            ?? ((object["quota"] as? [String: Any])?["rate_limits"] as? [String: Any])
        let quota: QuotaReport?
        if let quotaObject {
            let capturedAt = date(from: object["timestamp"] ?? object["captured_at"])
            quota = quotaAdapter.quotaReport(
                agentID: agentID,
                rateLimits: quotaObject,
                capturedAt: capturedAt ?? .now,
                now: .now
            )
        } else {
            quota = nil
        }
        let adapterResult = eventAdapter.adapt(
            agentID: agentID,
            eventName: eventName,
            object: object,
            query: query,
            sessionID: sessionID
        )
        let permissionRequired = adapterResult.permissionEligible && ((forcePermission && !adapterResult.isQuestionEvent)
            || (eventName.lowercased().contains("permission") && !adapterResult.isQuestionEvent)
            || (object["permission"] != nil && !adapterResult.immediateNotification && !adapterResult.permissionSuspect))
        let permission: PermissionRequest?
        if permissionRequired {
            permission = PermissionRequest(
                id: string(["request_id", "requestId", "permission_id"]) ?? UUID().uuidString,
                sessionID: sessionID,
                agentID: agentID,
                title: string(["title", "message", "description", "prompt", "tool_name", "toolName"]) ?? "Agent is waiting for permission",
                action: string(["action", "permission_action"]),
                command: string(["command", "cmd"]),
                input: string(["input", "tool_input", "toolInput"]) ?? adapterResult.permissionInput,
                suggestions: adapterResult.forwardsPermissionSuggestions
                    ? permissionSuggestions(from: object)
                    : []
            )
        } else {
            permission = nil
        }

        var payload: [String: String] = [:]
        for (key, value) in object {
            if let stringValue = value as? String { payload[key] = stringValue }
        }
        return AgentEvent(
            sessionID: sessionID,
            agentID: agentID,
            eventName: eventName,
            stateHint: adapterResult.immediateNotification ? .notification : hint,
            toolName: string(["tool_name", "toolName", "tool"]),
            title: string(["title", "session_title", "sessionTitle"]),
            folder: string(["folder", "cwd", "working_directory", "workingDirectory"]),
            terminalPID: int(["pid", "terminal_pid", "terminalPid"]),
            subagentCount: int(["subagent_count", "subagentCount", "subagents"]) ?? 0,
            permission: permission,
            question: adapterResult.question,
            quota: quota,
            contextUsage: contextUsage,
            metadataOnly: metadataOnly,
            toolCallID: string(["tool_call_id", "toolCallId", "call_id", "callId"]),
            permissionSuspect: adapterResult.permissionSuspect,
            permissionSuspectDelayMilliseconds: adapterResult.permissionSuspectDelayMilliseconds,
            permissionGateID: adapterResult.permissionGateID,
            permissionGated: adapterResult.permissionGated,
            questionResolution: adapterResult.questionResolution,
            payload: payload
        )
    }

    /// Parses the agent's concrete allow/deny suggestions offered alongside a
    /// permission request. Plain strings map to allow unless they clearly
    /// mean deny; structured entries read their own label and decision.
    private func permissionSuggestions(from object: [String: Any]) -> [PermissionSuggestion] {
        let raw: Any? = object["permission_suggestions"]
            ?? object["permissionSuggestions"]
            ?? object["suggestions"]
        guard let list = raw as? [Any] else { return [] }
        return list.prefix(6).compactMap { item -> PermissionSuggestion? in
            if let dictionary = item as? [String: Any] {
                guard let label = stringValueIn(dictionary, keys: ["label", "title", "text", "name"]),
                      !label.isEmpty else { return nil }
                let decision = suggestionDecision(from: dictionary)
                return PermissionSuggestion(
                    id: stringValueIn(dictionary, keys: ["id", "suggestion_id"]) ?? UUID().uuidString,
                    label: String(label.prefix(80)),
                    decision: decision
                )
            }
            guard let label = item as? String, !label.isEmpty else { return nil }
            let normalized = label.lowercased()
            let decision: PermissionDecision = ["no", "deny", "denied", "reject", "拒绝"].contains(normalized)
                ? .deny
                : .allow
            return PermissionSuggestion(label: String(label.prefix(80)), decision: decision)
        }
    }

    private func stringValueIn(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
            if let value = dictionary[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func suggestionDecision(from dictionary: [String: Any]) -> PermissionDecision {
        if let value = dictionary["decision"] as? String {
            return value.lowercased().contains("deny") || value.lowercased().contains("no") ? .deny : .allow
        }
        if let value = dictionary["action"] as? String {
            return value.lowercased().contains("deny") ? .deny : .allow
        }
        if let bool = dictionary["allow"] as? Bool, bool { return .allow }
        if let bool = dictionary["deny"] as? Bool, bool { return .deny }
        if let value = dictionary["behavior"] as? String {
            return value.lowercased() == "deny" ? .deny : .allow
        }
        return .allow
    }

    private func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private func normalizeState(_ raw: String) -> PetState? {
        if let state = PetState(rawValue: raw.lowercased()) { return state }
        switch raw.lowercased() {
        case "working", "work": return .typing
        case "complete", "completed", "done": return .attention
        case "permission", "alert": return .notification
        default: return nil
        }
    }

    private static func isValidRemoteNonce(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private func sendJSON(_ object: [String: Any], status: Int = 200, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        sendBytes(body, contentType: "application/json", status: status, on: connection)
    }

    private func send(_ response: AgentPermissionHTTPResponse, on connection: NWConnection) {
        guard response.statusCode != 204 else {
            sendNoContent(on: connection)
            return
        }
        sendBytes(
            response.body,
            contentType: response.contentType,
            status: response.statusCode,
            on: connection
        )
    }

    private func sendNoContent(on connection: NWConnection) {
        let header = "HTTP/1.1 204 No Content\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendBytes(_ body: Data, contentType: String, status: Int = 200, on connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let mobileHTML = """
    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Clawdesk Mobile</title>
    <style>body{font:16px -apple-system;background:#111;color:#f4f4f4;margin:0;padding:20px}h1{font-size:22px}.card{background:#222;border:1px solid #444;border-radius:14px;padding:14px;margin:10px 0}.state{color:#ff9a3d;font-weight:700}.muted{color:#aaa;font-size:13px}</style>
    <h1>🦀 Clawdesk</h1><div id="app">Connecting…</div>
    <script>async function tick(){try{const s=await fetch('/sessions',{cache:'no-store'}).then(r=>r.json());document.querySelector('#app').innerHTML='<p class="state">'+s.state+'</p>'+(s.sessions||[]).map(x=>'<div class="card"><b>'+x.title+'</b><br><span class="state">'+x.state+'</span><br><span class="muted">'+(x.folder||x.agentID)+'</span></div>').join('')||'<p class="muted">No live sessions</p>'}catch(e){document.querySelector('#app').textContent='Clawdesk is offline'}}tick();setInterval(tick,2000)</script>
    """
}
