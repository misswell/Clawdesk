import Foundation

public enum SessionHUDStatusKind: String, Equatable, Hashable, Sendable {
    case thinking
    case working
    case building
    case juggling
    case compacting
    case preparing
    case complete
    case attention
    case error

    public var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .building: return "Building"
        case .juggling: return "Subagents"
        case .compacting: return "Compacting"
        case .preparing: return "Preparing"
        case .complete: return "Complete"
        case .attention: return "Needs attention"
        case .error: return "Error"
        }
    }
}

public struct SessionHUDStatus: Equatable, Sendable {
    public let kind: SessionHUDStatusKind

    public init(kind: SessionHUDStatusKind) {
        self.kind = kind
    }

    public var label: String { kind.label }
}

/// Converts the lifecycle state and the latest event into the compact chip
/// shown on a HUD row. Idle sessions intentionally have no chip: the status
/// dot still identifies the row, while active/attention states get a readable
/// label just like the upstream HUD.
public enum SessionHUDPresentation {
    public static func status(for session: SessionSnapshot) -> SessionHUDStatus? {
        let event = normalizedEvent(session.lastEvent)
        switch event {
        case "precompact", "precompress", "compacting", "sweeping":
            return SessionHUDStatus(kind: .compacting)
        case "permissionrequest", "permission", "notification", "elicitation", "needsattention", "requestuserinput":
            return SessionHUDStatus(kind: .attention)
        case "worktreecreate", "carrying", "preparing":
            return SessionHUDStatus(kind: .preparing)
        default:
            break
        }

        switch session.state {
        case .thinking:
            return SessionHUDStatus(kind: .thinking)
        case .typing:
            return SessionHUDStatus(kind: .working)
        case .building:
            return SessionHUDStatus(kind: .building)
        case .juggling:
            return SessionHUDStatus(kind: .juggling)
        case .sweeping:
            return SessionHUDStatus(kind: .compacting)
        case .carrying:
            return SessionHUDStatus(kind: .preparing)
        case .attention, .miniHappy:
            return SessionHUDStatus(kind: .complete)
        case .notification, .miniAlert:
            return SessionHUDStatus(kind: .attention)
        case .error:
            return SessionHUDStatus(kind: .error)
        default:
            return nil
        }
    }

    private static func normalizedEvent(_ value: String) -> String {
        EventStateMapper.normalizedEventName(value)
    }
}
