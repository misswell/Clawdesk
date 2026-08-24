import Foundation

public struct AgentDescriptor: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    public let permissionApproval: Bool
    public let stateOnly: Bool

    public init(id: String, displayName: String, detail: String, permissionApproval: Bool, stateOnly: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.permissionApproval = permissionApproval
        self.stateOnly = stateOnly
    }
}

public enum AgentRegistry {
    public static let all: [AgentDescriptor] = [
        AgentDescriptor(id: "claude-code", displayName: "Claude Code", detail: "Command hooks + HTTP permission hooks", permissionApproval: true),
        AgentDescriptor(id: "codex", displayName: "Codex CLI", detail: "Official hooks + JSONL fallback", permissionApproval: true),
        AgentDescriptor(id: "copilot-cli", displayName: "Copilot CLI", detail: "Optional lifecycle hooks", permissionApproval: true),
        AgentDescriptor(id: "gemini-cli", displayName: "Gemini CLI", detail: "Optional lifecycle hooks", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "antigravity-cli", displayName: "Antigravity CLI", detail: "State-only hooks", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "cursor-agent", displayName: "Cursor Agent", detail: "IDE hook integration", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "codebuddy", displayName: "CodeBuddy", detail: "Claude-compatible hooks", permissionApproval: true),
        AgentDescriptor(id: "workbuddy", displayName: "WorkBuddy", detail: "State + notification hooks", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "kiro-cli", displayName: "Kiro CLI", detail: "Agent config hook integration", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "kimi-cli", displayName: "Kimi Code CLI", detail: "TOML command hooks", permissionApproval: true),
        AgentDescriptor(id: "qwen-code", displayName: "Qwen Code", detail: "Lifecycle + permission hooks", permissionApproval: true),
        AgentDescriptor(id: "zcode", displayName: "ZCode", detail: "State + manual permission hooks", permissionApproval: true),
        AgentDescriptor(id: "codewhale", displayName: "CodeWhale", detail: "State-only lifecycle hooks", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "opencode", displayName: "opencode", detail: "Plugin events + permission requests", permissionApproval: true),
        AgentDescriptor(id: "mimocode", displayName: "MiMo Code", detail: "opencode-family plugin", permissionApproval: true),
        AgentDescriptor(id: "pi", displayName: "Pi", detail: "Global extension", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "openclaw", displayName: "OpenClaw", detail: "State-only plugin", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "hermes", displayName: "Hermes Agent", detail: "Managed plugin + permissions", permissionApproval: true),
        AgentDescriptor(id: "qoder", displayName: "Qoder", detail: "State-only command hooks", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "qoderwork", displayName: "QoderWork", detail: "State-only hooks + HUD", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "qwenwork", displayName: "QwenWork", detail: "State-only hooks + HUD", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "reasonix", displayName: "Reasonix CLI", detail: "State-only command hooks", permissionApproval: false, stateOnly: true),
        AgentDescriptor(id: "deepseek-harness", displayName: "DeepSeek Harness", detail: "Web profile bridge", permissionApproval: true),
        AgentDescriptor(id: "custom", displayName: "Custom HTTP agent", detail: "POST lifecycle events to Clawdesk", permissionApproval: false, stateOnly: true)
    ]

    public static func descriptor(for id: String) -> AgentDescriptor? {
        all.first { $0.id == id }
    }
}
