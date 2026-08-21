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
    case sleeping
    case dozing
    case waking
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
             .waking, .reactDouble, .reactFlail, .miniAlert, .miniHappy:
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
        case .sleeping: return "Sleeping"
        case .dozing: return "Dozing"
        case .waking: return "Waking"
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
    public var permission: PermissionRequest?
    public var question: QuestionPrompt?
    public var quota: QuotaReport?
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
        permission: PermissionRequest? = nil,
        question: QuestionPrompt? = nil,
        quota: QuotaReport? = nil,
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
        self.permission = permission
        self.question = question
        self.quota = quota
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
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        agentID: String,
        title: String,
        action: String? = nil,
        command: String? = nil,
        input: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentID = agentID
        self.title = title
        self.action = action
        self.command = command
        self.input = input
        self.createdAt = createdAt
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
        recentEvents: [String] = []
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
