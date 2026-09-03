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
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for listener in self.remoteIngressListeners.values {
                listener.newConnectionHandler = nil
                listener.cancel()
            }
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
            if let listener = self.remoteIngressListeners.removeValue(forKey: nonce) {
                listener.newConnectionHandler = nil
                listener.cancel()
            }
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
                candidateListener.stateUpdateHandler = { [weak self, weak candidateListener] state in
                    if case .ready = state, let actual = candidateListener?.port?.rawValue {
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
        connection.stateUpdateHandler = { [weak connection] state in
            if case .failed = state { connection?.cancel() }
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
                    eventName: event.eventName,
                    toolInput: permission.input
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

    /// Upstream normalizes `assistant_last_output` before storage: control
    /// characters become spaces and the text is capped at 2400 characters.
    static func scrubbedAssistantOutput(_ value: String) -> String {
        let control = CharacterSet.controlCharacters
        var cleaned = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            cleaned.append(control.contains(scalar) ? " " : scalar)
        }
        let text = String(cleaned)
        guard text.count > 2400 else { return text }
        return String(text.prefix(2400))
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

        func arrayCount(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = object[key] as? [Any] { return value.count }
            }
            return nil
        }

        let queryAgent = [query["agent_id"], query["agent"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let rawAgentID = queryAgent ?? string(["agent_id", "agentId", "source", "agent"]) ?? "custom"
        let agentID = AgentRegistry.canonicalID(for: rawAgentID)
        let normalizedAgentID = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Sessionless posts coalesce onto a per-agent default key like
        // upstream (`codex:default`, …) instead of minting an orphan UUID
        // per event.
        let rawSessionID = string(["session_id", "sessionId", "session", "id"])
            ?? query["session_id"]
            ?? query["sessionId"]
            ?? "\(normalizedAgentID):default"
        let namespacedSessionID = normalizedAgentID == "traecode" && !rawSessionID.hasPrefix("traecode:")
            ? "traecode:\(rawSessionID)"
            : rawSessionID
        let remotePrefix = query["remote_prefix"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionID = remotePrefix.isEmpty ? namespacedSessionID : "\(remotePrefix):\(namespacedSessionID)"
        // `state` is a visual hint, not a lifecycle event. In particular a
        // Claude Stop payload commonly contains `state: "working"` while
        // the query carries the real `event=Stop`; allowing the hint into
        // this candidate list turns a completed turn into ordinary work.
        // Hook URLs are authoritative because the adapter that installed the
        // hook chose that event explicitly. Only fall back to body event
        // fields when the URL does not provide one.
        let eventName = fallbackEvent.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
            ?? string(["event", "event_name", "eventName", "type", "name"])
            ?? (forcePermission ? "PermissionRequest" : "Notification")
        let parsedContextUsage = parseContextUsage(from: object, agentID: agentID)
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
        let suppliedTitle = string(["title", "session_title", "sessionTitle"])
        let eventTitle = suppliedTitle ?? traecodePromptTitle(
            object: object,
            agentID: normalizedAgentID,
            eventName: eventName
        )
        let backgroundTasks = object["background_tasks"] as? [Any]
        let backgroundSubagentCount = backgroundTasks.map { tasks in
            tasks.reduce(into: 0) { count, entry in
                guard let task = entry as? [String: Any],
                      let type = task["type"] as? String,
                      type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "subagent" else { return }
                count += 1
            }
        }
        return AgentEvent(
            sessionID: sessionID,
            agentID: agentID,
            eventName: eventName,
            stateHint: adapterResult.immediateNotification ? .notification : hint,
            toolName: string(["tool_name", "toolName", "tool"]),
            title: eventTitle,
            folder: string(["folder", "cwd", "working_directory", "workingDirectory"]),
            terminalPID: int(["pid", "terminal_pid", "terminalPid"]),
            subagentCount: int(["subagent_count", "subagentCount", "subagents"]) ?? 0,
            subagentID: string(["subagent_id", "subagentId", "child_id", "childId"]),
            subagentType: string(["subagent_type", "subagentType", "child_type", "childType"]),
            preserveState: bool(["preserve_state", "preserveState"]),
            backgroundTasksCount: backgroundTasks?.count ?? int(["background_tasks_count", "backgroundTasksCount"]),
            backgroundSubagentCount: backgroundSubagentCount ?? int(["background_subagents_count", "backgroundSubagentsCount"]),
            sessionCronsCount: arrayCount(["session_crons"]) ?? int(["session_crons_count", "sessionCronsCount"]),
            stopHookActive: bool(["stop_hook_active", "stopHookActive"]),
            assistantLastOutput: string([
                "assistant_last_output", "assistantLastOutput",
                "last_assistant_output", "lastAssistantOutput"
            ]).map(Self.scrubbedAssistantOutput),
            assistantLastOutputTruncated: bool([
                "assistant_last_output_truncated", "assistantLastOutputTruncated",
                "last_assistant_output_truncated", "lastAssistantOutputTruncated"
            ]),
            headless: bool(["headless", "is_headless", "isHeadless"]),
            permission: permission,
            question: adapterResult.question,
            quota: quota,
            contextUsage: parsedContextUsage,
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

    private func traecodePromptTitle(object: [String: Any], agentID: String, eventName: String) -> String? {
        guard agentID == "traecode",
              EventStateMapper.normalizedEventName(eventName) == "userpromptsubmit",
              let prompt = object["prompt"] as? String else { return nil }
        let secretPattern = #"(?i)\b(api[_-]?key|authorization|bearer|password|passwd|private[_-]?key|secret|token)\b|sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}"#
        for line in prompt.components(separatedBy: .newlines) {
            let candidate = line
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            guard !candidate.isEmpty else { continue }
            guard candidate.range(of: secretPattern, options: .regularExpression) == nil else { return nil }
            if candidate.count <= 40 { return candidate }
            return String(candidate.prefix(39)) + "…"
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func parseContextUsage(from object: [String: Any], agentID: String) -> ContextUsage? {
        let values: [String: Any]?
        if let raw = object["context_usage"] {
            values = raw as? [String: Any]
        } else {
            values = object["contextUsage"] as? [String: Any]
        }
        let window = object["context_window"] as? [String: Any]
        var used: Double?
        if let values, let rawUsed = values["used"] {
            used = Self.number(rawUsed)
        }

        if used == nil, let current = window?["current_usage"] as? [String: Any] {
            var total = 0.0
            var foundComponent = false
            var hasInvalidComponent = false
            for key in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                guard let value = current[key] else { continue }
                guard let amount = Self.number(value), amount >= 0 else {
                    hasInvalidComponent = true
                    break
                }
                foundComponent = true
                total += amount
            }
            if !hasInvalidComponent, foundComponent, total > 0 {
                used = total
            }
        }

        if used == nil, let rawUsed = window?["used"] {
            used = Self.number(rawUsed)
        }
        guard let used, used > 0 else { return nil }

        var limit: Double?
        if let values, let rawLimit = values["limit"] {
            limit = Self.number(rawLimit)
        } else {
            limit = nil
        }
        if limit == nil, let rawLimit = window?["context_window_size"] {
            limit = Self.number(rawLimit)
        }

        var percent: Double?
        if let values, let rawPercent = values["percent"] {
            percent = Self.number(rawPercent)
        } else {
            percent = nil
        }
        if percent == nil, let rawPercent = window?["used_percentage"] {
            percent = Self.number(rawPercent)
        }

        var source = Self.stringValue(in: object, keys: ["context_source", "contextSource"])
        if source == nil, let values {
            source = Self.stringValue(in: values, keys: ["source"])
        }
        if source == nil {
            let normalizedAgent = agentID.lowercased()
            if normalizedAgent.contains("claude") {
                source = "claude"
            } else if normalizedAgent.contains("codex") {
                source = "codex"
            } else if normalizedAgent.contains("antigravity") {
                source = "antigravity"
            } else if normalizedAgent.contains("opencode") {
                source = "opencode"
            }
        }

        return ContextUsage(
            used: used,
            limit: limit,
            percent: percent.map { Int($0.rounded()) },
            source: source
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
        var regular: [PermissionSuggestion] = []
        var addRules: [String] = []
        for item in list.prefix(12) {
            if let dictionary = item as? [String: Any] {
                // Upstream merges every `addRules` entry into one "always
                // allow" suggestion instead of rendering N raw entries.
                if (dictionary["type"] as? String)?.lowercased() == "addrules" {
                    if let rules = dictionary["rules"] as? [Any] {
                        addRules.append(contentsOf: rules.compactMap(Self.ruleLabel))
                    } else if let merged = Self.ruleLabel(dictionary) {
                        addRules.append(merged)
                    }
                    continue
                }
                guard let label = stringValueIn(dictionary, keys: ["label", "title", "text", "name"]),
                      !label.isEmpty else { continue }
                let decision = suggestionDecision(from: dictionary)
                regular.append(
                    PermissionSuggestion(
                        id: stringValueIn(dictionary, keys: ["id", "suggestion_id"]) ?? UUID().uuidString,
                        label: String(label.prefix(80)),
                        decision: decision
                    )
                )
                continue
            }
            guard let label = item as? String, !label.isEmpty else { continue }
            let normalized = label.lowercased()
            let decision: PermissionDecision = ["no", "deny", "denied", "reject", "拒绝"].contains(normalized)
                ? .deny
                : .allow
            regular.append(PermissionSuggestion(label: String(label.prefix(80)), decision: decision))
        }
        if !addRules.isEmpty {
            let label = "Always allow " + addRules.map { "`\($0)`" }.joined(separator: ", ")
            regular.append(PermissionSuggestion(label: String(label.prefix(160)), decision: .allow))
        }
        return Array(regular.prefix(6))
    }

    private static func ruleLabel(_ rule: Any) -> String? {
        if let text = rule as? String, !text.isEmpty { return text }
        guard let dictionary = rule as? [String: Any] else { return nil }
        let tool = dictionary["toolName"] as? String
            ?? (dictionary["tool_name"] as? String)
            ?? ""
        let content = dictionary["ruleContent"] as? String
            ?? (dictionary["rule_content"] as? String)
            ?? ""
        if tool.isEmpty && content.isEmpty { return nil }
        if content.isEmpty { return tool }
        if tool.isEmpty { return content }
        return "\(tool): \(content)"
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
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let state = PetState(rawValue: value) { return state }
        switch EventStateMapper.normalizedEventName(value) {
        case "idle", "ready", "agentspawn": return .idle
        case "thinking", "think", "prompt": return .thinking
        case "working", "work", "typing": return .typing
        case "building", "build": return .building
        case "juggling", "subagents": return .juggling
        case "error", "failed", "failure": return .error
        case "complete", "completed", "done", "happy": return .attention
        case "permission", "alert", "notification", "needsattention": return .notification
        case "dizzy", "spinning": return .dizzy
        case "sweeping", "compacting", "compaction": return .sweeping
        case "carrying", "preparing": return .carrying
        case "sleep": return .sleeping
        case "wakingfromdoze": return .wakingFromDoze
        case "miniidle": return .miniIdle
        case "minipeek": return .miniPeek
        case "minialert": return .miniAlert
        case "minihappy": return .miniHappy
        case "miniworking": return .miniWorking
        case "minicrabwalk": return .miniCrabwalk
        case "minienter": return .miniEnter
        case "minientersleep": return .miniEnterSleep
        case "minisleep": return .miniSleep
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
