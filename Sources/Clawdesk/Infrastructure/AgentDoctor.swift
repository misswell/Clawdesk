import Foundation

public struct AgentDiagnostic: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ok
        case notInstalled
        case fixable
        case notChecked
    }

    public let agentID: String
    public let displayName: String
    public let state: State
    public let message: String

    public init(agentID: String, displayName: String, state: State, message: String) {
        self.agentID = agentID
        self.displayName = displayName
        self.state = state
        self.message = message
    }
}

/// Read-only local integration diagnostics for the registered agents. It
/// checks the known config files for Clawdesk-managed entries and, for the
/// script-based integrations, that the shared hook script still exists.
@MainActor
public final class AgentDoctor {
    private let installer: HookInstaller
    private let fileManager: FileManager

    public init(installer: HookInstaller, fileManager: FileManager = .default) {
        self.installer = installer
        self.fileManager = fileManager
    }

    public func diagnose() -> [AgentDiagnostic] {
        AgentRegistry.all.compactMap { agent in
            guard HookInstaller.supportedAgentIDs.contains(agent.id) else {
                return AgentDiagnostic(
                    agentID: agent.id,
                    displayName: agent.displayName,
                    state: .notChecked,
                    message: "Not installed by Clawdesk."
                )
            }
            return diagnose(agent: agent)
        }
    }

    public func configURLs(for agentID: String) -> [URL] {
        let home = installer.homeDirectory
        switch agentID {
        case "claude-code": return [home.appendingPathComponent(".claude/settings.json")]
        case "codex": return [home.appendingPathComponent(".codex/hooks.json")]
        case "copilot-cli": return [home.appendingPathComponent(".copilot/hooks/hooks.json")]
        case "gemini-cli": return [home.appendingPathComponent(".gemini/settings.json")]
        case "antigravity-cli": return [home.appendingPathComponent(".gemini/config/hooks.json")]
        case "cursor-agent": return [home.appendingPathComponent(".cursor/hooks.json")]
        case "codebuddy": return [home.appendingPathComponent(".codebuddy/settings.json")]
        case "workbuddy": return [home.appendingPathComponent(".workbuddy-ai/settings.json")]
        case "kiro-cli": return [home.appendingPathComponent(".kiro/agents/clawdesk.json")]
        case "kimi-cli": return [
            home.appendingPathComponent(".kimi/config.toml"),
            home.appendingPathComponent(".kimi-code/config.toml")
        ]
        case "qwen-code": return [home.appendingPathComponent(".qwen/settings.json")]
        case "qoder": return [home.appendingPathComponent(".qoder/settings.json")]
        case "qoderwork": return [home.appendingPathComponent(".qoderwork/settings.json")]
        case "qwenwork": return [home.appendingPathComponent(".QwenWorkCN/settings.json")]
        case "reasonix": return [home.appendingPathComponent(".reasonix/settings.json")]
        case "zcode": return [home.appendingPathComponent(".zcode/cli/config.json")]
        case "codewhale": return [home.appendingPathComponent(".codewhale/config.toml")]
        case "opencode": return [
            home.appendingPathComponent(".config/opencode/opencode.jsonc"),
            home.appendingPathComponent(".config/opencode/opencode.json")
        ]
        case "mimocode": return [
            home.appendingPathComponent(".config/mimocode/mimocode.jsonc"),
            home.appendingPathComponent(".config/mimocode/mimocode.json")
        ]
        case "openclaw": return [home.appendingPathComponent(".openclaw/openclaw.json")]
        default: return []
        }
    }

    private func diagnose(agent: AgentDescriptor) -> AgentDiagnostic {
        let urls = configURLs(for: agent.id)
        guard !urls.isEmpty else {
            return AgentDiagnostic(
                agentID: agent.id,
                displayName: agent.displayName,
                state: .notChecked,
                message: "No checked config path."
            )
        }
        let existing = urls.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            return AgentDiagnostic(
                agentID: agent.id,
                displayName: agent.displayName,
                state: .notInstalled,
                message: "No config file found."
            )
        }
        let managed = existing.contains { url in
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.localizedCaseInsensitiveContains("clawdesk")
        }
        guard managed else {
            return AgentDiagnostic(
                agentID: agent.id,
                displayName: agent.displayName,
                state: .fixable,
                message: "Config exists without managed hooks."
            )
        }
        if agent.id == "claude-code" || agent.id == "codex", !fileManager.fileExists(atPath: installer.hookScript.path) {
            return AgentDiagnostic(
                agentID: agent.id,
                displayName: agent.displayName,
                state: .fixable,
                message: "Managed hook script is missing."
            )
        }
        return AgentDiagnostic(
            agentID: agent.id,
            displayName: agent.displayName,
            state: .ok,
            message: "Healthy."
        )
    }
}
