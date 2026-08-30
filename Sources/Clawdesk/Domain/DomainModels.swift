import Foundation

public enum PetState: String, CaseIterable, Codable, Sendable {
    case idle
    case thinking
    case typing
    case building
    case juggling
    case error
    case attention
    case notification
    case sweeping
    case carrying
    case yawning
    case sleeping
    case dozing
    case collapsing
    case waking
    case wakingFromDoze = "waking-from-doze"
    case dragging
    case miniIdle = "mini-idle"
    case miniPeek = "mini-peek"
    case miniAlert = "mini-alert"
    case miniHappy = "mini-happy"
    case reactDouble = "react-double"
    case reactFlail = "react-flail"

    public var isTransient: Bool {
        switch self {
        case .thinking, .error, .attention, .notification, .sweeping, .carrying,
             .yawning, .waking, .wakingFromDoze, .reactDouble, .reactFlail, .miniAlert, .miniHappy:
            return true
        default:
            return false
        }
    }

    public var isMini: Bool {
        switch self {
        case .miniIdle, .miniPeek, .miniAlert, .miniHappy:
            return true
        default:
            return false
        }
    }

    /// Pointer interaction states do not have an accessory of their own.
    /// Keeping this explicit prevents a theme's optional interaction artwork
    /// from reintroducing the old corner bars.
    public var isPointerInteraction: Bool {
        switch self {
        case .dragging, .miniPeek:
            return true
        default:
            return false
        }
    }

    public var isSleepSequence: Bool {
        switch self {
        case .yawning, .dozing, .collapsing, .sleeping:
            return true
        default:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .typing: return "Working"
        case .building: return "Building"
        case .juggling: return "Subagents"
        case .error: return "Error"
        case .attention: return "Complete"
        case .notification: return "Needs attention"
        case .sweeping: return "Compacting"
        case .carrying: return "Preparing"
        case .yawning: return "Yawning"
        case .sleeping: return "Sleeping"
        case .dozing: return "Dozing"
        case .collapsing: return "Falling asleep"
        case .waking: return "Waking"
        case .wakingFromDoze: return "Waking"
        case .dragging: return "Dragging"
        case .miniIdle: return "Mini mode"
        case .miniPeek: return "Peeking"
        case .miniAlert: return "Alert"
        case .miniHappy: return "Complete"
        case .reactDouble: return "Poked"
        case .reactFlail: return "Overstimulated"
        }
    }
}

public enum PermissionMode: String, CaseIterable, Codable, Sendable {
    case askEveryTime = "ask-every-time"
    case toolsOnly = "tools-only"
    case autoApprove = "auto-approve"

    public var displayName: String {
        switch self {
        case .askEveryTime: return "Ask every time"
        case .toolsOnly: return "Question prompts only"
        case .autoApprove: return "Auto-approve"
        }
    }
}

public enum PermissionBubbleCorner: String, CaseIterable, Codable, Sendable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    public var displayName: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

public struct QuestionOption: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
    public let isOther: Bool
    public let isSecret: Bool

    public init(
        id: String = UUID().uuidString,
        label: String,
        description: String? = nil,
        isOther: Bool = false,
        isSecret: Bool = false
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.isOther = isOther
        self.isSecret = isSecret
    }
}

public struct QuestionItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let header: String?
    public let question: String
    public let options: [QuestionOption]

    public init(
        id: String = UUID().uuidString,
        header: String? = nil,
        question: String,
        options: [QuestionOption] = []
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
    }
}

/// A Codex request_user_input preview. It is deliberately read-only: the
/// answer is entered in Codex itself and never crosses the Clawdesk bridge.
public struct QuestionPrompt: Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let agentID: String
    public let title: String
    public let questions: [QuestionItem]
    public let createdAt: Date

    public init(
        id: String,
        sessionID: String,
        agentID: String,
        title: String = "Agent question",
        questions: [QuestionItem],
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentID = agentID
        self.title = title
        self.questions = questions
        self.createdAt = createdAt
    }
}

public struct AgentEvent: Equatable, Sendable {
    public var sessionID: String
    public var agentID: String
    public var eventName: String
    public var stateHint: PetState?
    public var toolName: String?
    public var title: String?
    public var folder: String?
    public var terminalPID: Int?
    public var subagentCount: Int
    public var backgroundTasksCount: Int?
    public var backgroundSubagentCount: Int?
    public var sessionCronsCount: Int?
    public var stopHookActive: Bool
    public var permission: PermissionRequest?
    public var question: QuestionPrompt?
    public var quota: QuotaReport?
    public var contextUsage: ContextUsage?
    public var metadataOnly: Bool
    public var toolCallID: String?
    public var permissionSuspect: Bool
    public var permissionSuspectDelayMilliseconds: Int?
    public var permissionGateID: String?
    public var permissionGated: Bool
    public var questionResolution: Bool
    public var payload: [String: String]
    public var timestamp: Date

    public init(
        sessionID: String,
        agentID: String = "custom",
        eventName: String,
        stateHint: PetState? = nil,
        toolName: String? = nil,
        title: String? = nil,
        folder: String? = nil,
        terminalPID: Int? = nil,
        subagentCount: Int = 0,
        backgroundTasksCount: Int? = nil,
        backgroundSubagentCount: Int? = nil,
        sessionCronsCount: Int? = nil,
        stopHookActive: Bool = false,
        permission: PermissionRequest? = nil,
        question: QuestionPrompt? = nil,
        quota: QuotaReport? = nil,
        contextUsage: ContextUsage? = nil,
        metadataOnly: Bool = false,
        toolCallID: String? = nil,
        permissionSuspect: Bool = false,
        permissionSuspectDelayMilliseconds: Int? = nil,
        permissionGateID: String? = nil,
        permissionGated: Bool = false,
        questionResolution: Bool = false,
        payload: [String: String] = [:],
        timestamp: Date = .now
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.eventName = eventName
        self.stateHint = stateHint
        self.toolName = toolName
        self.title = title
        self.folder = folder
        self.terminalPID = terminalPID
        self.subagentCount = max(0, subagentCount)
        self.backgroundTasksCount = backgroundTasksCount.map { max(0, $0) }
        self.backgroundSubagentCount = backgroundSubagentCount.map { max(0, $0) }
        self.sessionCronsCount = sessionCronsCount.map { max(0, $0) }
        self.stopHookActive = stopHookActive
        self.permission = permission
        self.question = question
        self.quota = quota
        self.contextUsage = contextUsage
        self.metadataOnly = metadataOnly
        self.toolCallID = toolCallID
        self.permissionSuspect = permissionSuspect
        self.permissionSuspectDelayMilliseconds = permissionSuspectDelayMilliseconds
        self.permissionGateID = permissionGateID
        self.permissionGated = permissionGated
        self.questionResolution = questionResolution
        self.payload = payload
        self.timestamp = timestamp
    }
}

public struct PermissionRequest: Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let agentID: String
    public let title: String
    public let action: String?
    public let command: String?
    public let input: String?
    public let suggestions: [PermissionSuggestion]
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        agentID: String,
        title: String,
        action: String? = nil,
        command: String? = nil,
        input: String? = nil,
        suggestions: [PermissionSuggestion] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentID = agentID
        self.title = title
        self.action = action
        self.command = command
        self.input = input
        self.suggestions = suggestions
        self.createdAt = createdAt
    }
}

/// A concrete allow/deny choice offered by the agent as part of a permission
/// request (for example a "yes" or "no" suggestion button).
public struct PermissionSuggestion: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let decision: PermissionDecision

    public init(id: String = UUID().uuidString, label: String, decision: PermissionDecision) {
        self.id = id
        self.label = label
        self.decision = decision
    }
}

/// Per-session context-window telemetry. It is deliberately separate from
/// account quota: context usage belongs to one running session and may be
/// refreshed by a statusline without changing the session lifecycle.
public struct ContextUsage: Equatable, Sendable {
    public let used: Double
    public let limit: Double?
    public let percent: Int?
    public let source: String?

    public init(
        used: Double,
        limit: Double? = nil,
        percent: Int? = nil,
        source: String? = nil
    ) {
        let normalizedUsed = max(0, used.isFinite ? used : 0)
        let normalizedLimit = limit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.used = normalizedUsed
        self.limit = normalizedLimit
        let calculated = normalizedLimit.map { Int((normalizedUsed / $0 * 100).rounded()) }
        let normalizedPercent = percent ?? calculated
        self.percent = normalizedPercent.map { min(100, max(0, $0)) }
        self.source = source
    }

    public var wireObject: [String: Any] {
        var object: [String: Any] = ["used": used]
        if let limit { object["limit"] = limit }
        if let percent { object["percent"] = percent }
        if let source { object["source"] = source }
        return object
    }
}

public struct SessionSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public var agentID: String
    public var title: String
    public var folder: String?
    public var state: PetState
    public var subagentCount: Int
    public var lastEvent: String
    public var lastActivity: Date
    public var terminalPID: Int?
    public var recentEvents: [String]
    public var contextUsage: ContextUsage?

    public init(
        id: String,
        agentID: String,
        title: String,
        folder: String? = nil,
        state: PetState,
        subagentCount: Int = 0,
        lastEvent: String,
        lastActivity: Date = .now,
        terminalPID: Int? = nil,
        recentEvents: [String] = [],
        contextUsage: ContextUsage? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.folder = folder
        self.state = state
        self.subagentCount = subagentCount
        self.lastEvent = lastEvent
        self.lastActivity = lastActivity
        self.terminalPID = terminalPID
        self.recentEvents = recentEvents
        self.contextUsage = contextUsage
    }
}

public struct StateTransition: Equatable, Sendable {
    public let state: PetState
    public let sessions: [SessionSnapshot]
    public let completedSessionID: String?
    public let permission: PermissionRequest?

    public init(
        state: PetState,
        sessions: [SessionSnapshot],
        completedSessionID: String? = nil,
        permission: PermissionRequest? = nil
    ) {
        self.state = state
        self.sessions = sessions
        self.completedSessionID = completedSessionID
        self.permission = permission
    }
}
