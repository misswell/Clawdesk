import Foundation

/// Permission automation modes. `off` shows the bubble for every request;
/// `autoTools` auto-approves only clearly read-only tools and defers the rest;
/// `unattended` auto-approves read-only tools and denies everything else.
///
/// The two automated modes are intentionally fail-closed: unknown tools are
/// never auto-approved, and `unattended` denies rather than guesses. This is a
/// deliberate safety-first divergence from the upstream "handle every request"
/// behavior.
public enum PermissionAutomation: String, CaseIterable, Codable, Sendable {
    case off
    case autoTools = "auto-tools"
    case unattended

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .autoTools: return "Auto-allow read-only tools"
        case .unattended: return "Unattended (fail closed)"
        }
    }
}

public enum PermissionPolicy {
    /// Tool names that are treated as read-only. Matching is on the agent's
    /// reported tool name only, never on the command text, so a "Bash" call
    /// can never be auto-approved no matter what its command contains.
    private static let readOnlyTools: Set<String> = [
        "read", "glob", "grep", "ls", "search", "websearch", "webfetch", "fetch"
    ]

    public static func decide(request: PermissionRequest, automation: PermissionAutomation) -> PermissionDecision? {
        switch automation {
        case .off:
            return nil
        case .autoTools:
            return isReadOnly(request) ? .allow : nil
        case .unattended:
            return isReadOnly(request) ? .allow : .deny
        }
    }

    private static func isReadOnly(_ request: PermissionRequest) -> Bool {
        guard let tool = request.action?.lowercased() else { return false }
        let normalized = tool.split(whereSeparator: { $0 == ":" || $0 == "." }).last.map(String.init) ?? tool
        return readOnlyTools.contains(normalized)
    }
}
