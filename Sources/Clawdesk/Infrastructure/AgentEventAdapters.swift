import Foundation

public struct AgentPermissionHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let body: Data
    public let contentType: String

    public init(statusCode: Int = 200, body: Data = Data(), contentType: String = "application/json") {
        self.statusCode = statusCode
        self.body = body
        self.contentType = contentType
    }

    public static let noContent = AgentPermissionHTTPResponse(statusCode: 204)
}

public struct AgentEventAdapterResult: Sendable {
    public let immediateNotification: Bool
    public let permissionSuspect: Bool
    public let permissionSuspectDelayMilliseconds: Int?
    public let permissionGateID: String?
    public let permissionGated: Bool
    public let permissionEligible: Bool
    public let permissionInput: String?
    public let forwardsPermissionSuggestions: Bool
    public let isQuestionEvent: Bool
    public let question: QuestionPrompt?
    public let questionResolution: Bool
    public let questionResolutionID: String?

    public init(
        immediateNotification: Bool = false,
        permissionSuspect: Bool = false,
        permissionSuspectDelayMilliseconds: Int? = nil,
        permissionGateID: String? = nil,
        permissionGated: Bool = false,
        permissionEligible: Bool = true,
        permissionInput: String? = nil,
        forwardsPermissionSuggestions: Bool = true,
        isQuestionEvent: Bool = false,
        question: QuestionPrompt? = nil,
        questionResolution: Bool = false,
        questionResolutionID: String? = nil
    ) {
        self.immediateNotification = immediateNotification
        self.permissionSuspect = permissionSuspect
        self.permissionSuspectDelayMilliseconds = permissionSuspectDelayMilliseconds
        self.permissionGateID = permissionGateID
        self.permissionGated = permissionGated
        self.permissionEligible = permissionEligible
        self.permissionInput = permissionInput
        self.forwardsPermissionSuggestions = forwardsPermissionSuggestions
        self.isQuestionEvent = isQuestionEvent
        self.question = question
        self.questionResolution = questionResolution
        self.questionResolutionID = questionResolutionID
    }
}

/// The local event server owns HTTP framing and generic field extraction. This
/// adapter owns agent-specific interpretation such as Kimi's legacy approval
/// heuristic and Codex's request_user_input shape, keeping future upstream
/// payload changes out of the transport.
public protocol AgentEventAdapter {
    func adapt(
        agentID: String,
        eventName: String,
        object: [String: Any],
        query: [String: String],
        sessionID: String
    ) -> AgentEventAdapterResult

    func permissionResponse(
        for decision: PermissionDecision,
        agentID: String,
        eventName: String,
        toolInput: String?
    ) -> AgentPermissionHTTPResponse

    func permissionFallbackResponse(
        agentID: String,
        eventName: String
    ) -> AgentPermissionHTTPResponse
}

public extension AgentEventAdapter {
    func permissionResponse(
        for decision: PermissionDecision,
        agentID: String,
        eventName: String,
        toolInput: String? = nil
    ) -> AgentPermissionHTTPResponse {
        standardPermissionResponse(for: decision)
    }

    func permissionFallbackResponse(
        agentID: String,
        eventName: String
    ) -> AgentPermissionHTTPResponse {
        standardJSONResponse(["ok": true])
    }
}

public struct DefaultAgentEventAdapter: AgentEventAdapter {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func adapt(
        agentID: String,
        eventName: String,
        object: [String: Any],
        query: [String: String],
        sessionID: String
    ) -> AgentEventAdapterResult {
        let normalizedEvent = normalizeEventName(eventName)
        let isKimi = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("kimi")
        let tool = toolName(from: object["tool_name"] ?? object["toolName"] ?? object["tool"]) ?? ""
        let normalizedTool = tool.lowercased().replacingOccurrences(of: "_", with: "")
        let gatedTool = ["shell", "writefile", "strreplacefile", "background"].contains(normalizedTool)
        let explicit = hasExplicitPermissionSignal(object)
        let persistedMode = (query["clawdesk-kimi-permission-mode"] ?? stringValue(object["permission_mode"]))?.lowercased()
        let runtimeMode = environment["CLAWD_KIMI_PERMISSION_MODE"]?.lowercased()
        let mode = ["explicit", "suspect"].contains(runtimeMode ?? "") ? runtimeMode : persistedMode
        let disablePretool = isKimi && boolValue(environment["CLAWD_KIMI_DISABLE_PRETOOL_PERMISSION"])
        let immediateOverride = isKimi && boolValue(environment["CLAWD_KIMI_PERMISSION_IMMEDIATE"])
        let suspectOverride = isKimi && boolValue(environment["CLAWD_KIMI_PERMISSION_SUSPECT"])
        let suspect = isKimi && !disablePretool && !immediateOverride && normalizedEvent == "pretooluse" && gatedTool
            && !explicit && (mode == "suspect" || suspectOverride)
        let immediate = isKimi && normalizedEvent == "pretooluse" && gatedTool
            && (explicit || (!disablePretool && immediateOverride))
        let gateOpen = suspect || immediate
        let gateClosed = isKimi
            && (normalizedEvent == "posttooluse" || normalizedEvent == "posttoolusefailure")
            && gatedTool
        let suspectDelay = suspect ? suspectDelayMilliseconds : nil

        let isCodex = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("codex")
        let isQuestionEvent = isCodex && normalizedEvent == "requestuserinput"
        let isQuestionResolution = isCodex
            && (normalizedEvent == "posttooluse" || normalizedEvent == "questionresolved")
        let questionResolutionID = isQuestionResolution
            ? stringValue(object["call_id"] ?? object["callId"] ?? object["tool_call_id"] ?? object["toolCallId"] ?? object["question_call_id"])
            : nil
        let isZCodePermission = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "zcode"
            && normalizedEvent.contains("permission")
        let zcodeToolInput: Any = {
            guard let candidate = object["tool_input"],
                  candidate is [String: Any] || candidate is [Any] else {
                return [String: Any]()
            }
            return candidate
        }()
        // ZCode's hook contract intentionally has no aliases here. The hook
        // only sends tool_name/tool_input; accepting toolName/toolInput would
        // make a direct caller look like a supported ZCode request when the
        // native hook would have fallen back to its own permission UI.
        let zcodeTool = stringValue(object["tool_name"]) ?? ""
        let zcodePermissionEligible = !isZCodePermission || (
            !zcodeTool.isEmpty && zcodeTool.lowercased() != "unknown"
                && isZCodeToolInputWithinBudget(zcodeToolInput)
        )
        return AgentEventAdapterResult(
            immediateNotification: immediate,
            permissionSuspect: suspect,
            permissionSuspectDelayMilliseconds: suspectDelay,
            permissionGateID: stringValue(object["tool_call_id"] ?? object["toolCallId"] ?? object["call_id"] ?? object["callId"]),
            permissionGated: gateOpen || gateClosed,
            permissionEligible: zcodePermissionEligible,
            permissionInput: isZCodePermission
                ? compactJSONString(zcodeToolInput)
                : nil,
            forwardsPermissionSuggestions: !isZCodePermission,
            isQuestionEvent: isQuestionEvent,
            question: isQuestionEvent ? questionPrompt(from: object, sessionID: sessionID, agentID: agentID) : nil,
            questionResolution: isQuestionResolution,
            questionResolutionID: questionResolutionID
        )
    }

    public func permissionResponse(
        for decision: PermissionDecision,
        agentID: String,
        eventName: String,
        toolInput: String? = nil
    ) -> AgentPermissionHTTPResponse {
        if isZCodePermission(agentID: agentID, eventName: eventName) {
            guard decision != .defer else { return .noContent }
            return standardJSONResponse([
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": ["behavior": decision == .allow ? "allow" : "deny"]
                ]
            ])
        }
        // Claude Code and CodeBuddy parse the hookSpecificOutput envelope;
        // anything else is ignored and the request falls back to the native
        // prompt. A no-decision keeps that native flow (204 like upstream).
        guard Self.usesHookSpecificOutput(agentID: agentID) else {
            return standardPermissionResponse(for: decision)
        }
        guard decision != .defer else { return .noContent }
        var decisionObject: [String: Any] = ["behavior": decision == .allow ? "allow" : "deny"]
        if decision == .deny {
            decisionObject["message"] = "Denied from Clawdesk"
        } else if let toolInput,
                  let data = toolInput.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // Claude requires the exact tool input echoed back on plan-mode
            // allows; for ordinary tools the identical input is a no-op.
            decisionObject["updatedInput"] = parsed
        }
        return standardJSONResponse([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decisionObject
            ]
        ])
    }

    static func usesHookSpecificOutput(agentID: String) -> Bool {
        let normalized = EventStateMapper.normalizedEventName(agentID)
        return ["claudecode", "claude", "codebuddy"].contains(normalized)
    }

    public func permissionFallbackResponse(
        agentID: String,
        eventName: String
    ) -> AgentPermissionHTTPResponse {
        isZCodePermission(agentID: agentID, eventName: eventName) ? .noContent : standardJSONResponse(["ok": true])
    }

    private var suspectDelayMilliseconds: Int {
        let raw = Int(environment["CLAWD_KIMI_PERMISSION_SUSPECT_MS"] ?? "") ?? 800
        return min(60_000, max(50, raw))
    }

    private func questionPrompt(from object: [String: Any], sessionID: String, agentID: String) -> QuestionPrompt? {
        var source: Any = object["questions"] ?? object["input"] ?? object["arguments"] ?? object["question"] ?? []
        if let string = source as? String,
           let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            source = decoded
        }
        if let nested = source as? [String: Any], nested["questions"] != nil {
            source = nested["questions"] as Any
        }
        let rawQuestions = source as? [[String: Any]] ?? []
        let items = rawQuestions.prefix(4).compactMap { raw -> QuestionItem? in
            let prompt = stringValue(raw["question"] ?? raw["prompt"] ?? raw["text"])
            guard let prompt, !prompt.isEmpty else { return nil }
            let rawOptions = raw["options"] as? [[String: Any]] ?? []
            let options = rawOptions.prefix(6).compactMap { option -> QuestionOption? in
                if let label = stringValue(option["label"] ?? option["title"]), !label.isEmpty {
                    return QuestionOption(
                        id: stringValue(option["id"]) ?? UUID().uuidString,
                        label: String(label.prefix(160)),
                        description: stringValue(option["description"]).map { String($0.prefix(240)) },
                        isOther: boolValue(option["is_other"] ?? option["isOther"]),
                        isSecret: boolValue(option["is_secret"] ?? option["isSecret"])
                    )
                }
                guard let label = stringValue(option), !label.isEmpty else { return nil }
                return QuestionOption(label: String(label.prefix(160)))
            }
            return QuestionItem(
                id: stringValue(raw["id"]) ?? UUID().uuidString,
                header: stringValue(raw["header"]).map { String($0.prefix(80)) },
                question: String(prompt.prefix(500)),
                options: options
            )
        }
        guard !items.isEmpty else { return nil }
        let callID = stringValue(object["call_id"] ?? object["callId"] ?? object["request_id"] ?? object["requestId"])
            ?? UUID().uuidString
        let title = String((stringValue(object["title"]) ?? "Codex question").prefix(160))
        return QuestionPrompt(
            id: callID,
            sessionID: sessionID,
            agentID: agentID,
            title: title,
            questions: items,
            createdAt: date(from: object["timestamp"] ?? object["created_at"]) ?? .now
        )
    }

    private func normalizeEventName(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }

    private func toolName(from value: Any?) -> String? {
        if let direct = stringValue(value) { return direct }
        if let object = value as? [String: Any] {
            return stringValue(object["name"] ?? object["tool_name"] ?? object["toolName"])
        }
        return nil
    }

    private func isZCodePermission(agentID: String, eventName: String) -> Bool {
        agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "zcode"
            && normalizeEventName(eventName).contains("permission")
    }

    private func compactJSONString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= 8 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func isZCodeToolInputWithinBudget(_ value: Any?, depth: Int = 0) -> Bool {
        guard let value else { return true }
        guard depth <= 6 else { return false }
        if let array = value as? [Any] {
            return array.count <= 16 && array.allSatisfy {
                isZCodeToolInputWithinBudget($0, depth: depth + 1)
            }
        }
        if let object = value as? [String: Any] {
            return object.count <= 32 && object.values.allSatisfy {
                isZCodeToolInputWithinBudget($0, depth: depth + 1)
            }
        }
        if let string = value as? String { return string.count <= 240 }
        return true
    }

    private func hasExplicitPermissionSignal(_ object: [String: Any]) -> Bool {
        let directKeys = [
            "permission_required", "permissionRequired", "requires_approval", "requiresApproval",
            "waiting_for_approval", "waitingForApproval", "is_permission_request", "isPermissionRequest",
            "approval_required", "needs_approval", "needsApproval"
        ]
        if directKeys.contains(where: { boolValue(object[$0]) }) { return true }
        if ["permission_status", "permissionStatus", "approval_status", "approvalStatus"]
            .compactMap({ stringValue(object[$0]) })
            .contains(where: isWaitingApprovalStatus) { return true }

        for key in ["permission", "approval", "permission_request", "permissionRequest"] {
            guard let nested = object[key] as? [String: Any] else { continue }
            if [
                "required", "requires_approval", "requiresApproval", "waiting_for_approval",
                "waitingForApproval", "is_permission_request", "isPermissionRequest",
                "needs_approval", "needsApproval"
            ].contains(where: { boolValue(nested[$0]) }) { return true }
            if ["status", "state"]
                .compactMap({ stringValue(nested[$0]) })
                .contains(where: isWaitingApprovalStatus) { return true }
        }
        return hasKeywordPermissionSignal(object, depth: 0)
    }

    private func isWaitingApprovalStatus(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return [
            "waiting_for_approval", "awaiting_approval", "requires_approval",
            "approval_required", "permission_required", "needs_approval"
        ].contains(normalized)
    }

    private func hasKeywordPermissionSignal(_ value: Any, depth: Int) -> Bool {
        guard depth <= 3 else { return false }
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let normalizedKey = key.lowercased()
                    .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
                if (normalizedKey.contains("permission") || normalizedKey.contains("approval")
                    || normalizedKey.contains("authorize") || normalizedKey.contains("consent")),
                   isPendingApprovalValue(child) { return true }
                if hasKeywordPermissionSignal(child, depth: depth + 1) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains { hasKeywordPermissionSignal($0, depth: depth + 1) }
        }
        return false
    }

    private func isPendingApprovalValue(_ value: Any) -> Bool {
        if boolValue(value) { return true }
        guard let string = stringValue(value)?.lowercased().replacingOccurrences(of: " ", with: "_") else {
            return false
        }
        return string.contains("wait") || string.contains("pend") || string.contains("request")
            || string.contains("require") || string.contains("need_approval") || string == "ask"
    }
}

private func standardPermissionResponse(for decision: PermissionDecision) -> AgentPermissionHTTPResponse {
    standardJSONResponse([
        "ok": true,
        "decision": decision.rawValue,
        "approved": decision == .allow,
        "behavior": decision == .allow ? "allow" : decision == .deny ? "deny" : "ask"
    ])
}

private func standardJSONResponse(_ object: [String: Any]) -> AgentPermissionHTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return AgentPermissionHTTPResponse(body: data)
}
