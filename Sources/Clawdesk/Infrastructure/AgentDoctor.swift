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

/// One upstream-style system health check (doctor.js runs eight; Clawdesk
/// covers the same ground minus the Windows-only probes).
public struct SystemDiagnostic: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ok
        case warn
        case fail
        case notApplicable
    }

    public let id: String
    public let displayName: String
    public let state: State
    public let message: String

    public init(id: String, displayName: String, state: State, message: String) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.message = message
    }
}

/// Inputs for the system checks, supplied by the model so the doctor stays
/// a pure read-only reporter.
public struct SystemCheckInputs: Equatable, Sendable {
    public var serverResponding: Bool
    public var serverPort: UInt16
    public var preferencesReadable: Bool
    public var themeID: String
    public var themeStateCount: Int
    public var permissionBubblesEnabled: Bool
    public var permissionAutomationOff: Bool
    public var remoteChannels: RemoteChannelSettings?
    public var remoteSSHProfileCount: Int
    public var remoteSSHIngressActive: Bool

    public init(
        serverResponding: Bool,
        serverPort: UInt16,
        preferencesReadable: Bool,
        themeID: String,
        themeStateCount: Int,
        permissionBubblesEnabled: Bool,
        permissionAutomationOff: Bool,
        remoteChannels: RemoteChannelSettings?,
        remoteSSHProfileCount: Int,
        remoteSSHIngressActive: Bool
    ) {
        self.serverResponding = serverResponding
        self.serverPort = serverPort
        self.preferencesReadable = preferencesReadable
        self.themeID = themeID
        self.themeStateCount = themeStateCount
        self.permissionBubblesEnabled = permissionBubblesEnabled
        self.permissionAutomationOff = permissionAutomationOff
        self.remoteChannels = remoteChannels
        self.remoteSSHProfileCount = remoteSSHProfileCount
        self.remoteSSHIngressActive = remoteSSHIngressActive
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

    /// The upstream doctor's system-level checks. `agent-integrations` is the
    /// per-agent table above; the rest run here against injected inputs.
    public func diagnoseSystem(_ inputs: SystemCheckInputs) -> [SystemDiagnostic] {
        var checks: [SystemDiagnostic] = []

        checks.append(SystemDiagnostic(
            id: "prefs",
            displayName: "Preferences",
            state: inputs.preferencesReadable ? .ok : .fail,
            message: inputs.preferencesReadable
                ? "Preferences load and persist."
                : "Preferences failed to load; settings may reset."
        ))

        checks.append(SystemDiagnostic(
            id: "local-server",
            displayName: "Local event server",
            state: inputs.serverResponding ? .ok : .fail,
            message: inputs.serverResponding
                ? "Listening on 127.0.0.1:\(inputs.serverPort)."
                : "The local hook server is not answering on port \(inputs.serverPort)."
        ))

        checks.append(SystemDiagnostic(
            id: "permission-bubble-policy",
            displayName: "Permission policy",
            state: {
                if inputs.permissionBubblesEnabled { return .ok }
                let remoteConfigured = (inputs.remoteChannels?.telegramApprovalEnabled ?? false)
                    || (inputs.remoteChannels?.feishuApprovalEnabled ?? false)
                if remoteConfigured { return .ok }
                return inputs.permissionAutomationOff ? .warn : .ok
            }(),
            message: {
                if inputs.permissionBubblesEnabled { return "Desktop approval bubble enabled." }
                let remoteConfigured = (inputs.remoteChannels?.telegramApprovalEnabled ?? false)
                    || (inputs.remoteChannels?.feishuApprovalEnabled ?? false)
                if remoteConfigured { return "Bubbles off; remote approval configured." }
                return inputs.permissionAutomationOff
                    ? "Bubbles and remote approval are both off; agents fall back to their native prompts."
                    : "Bubbles off; automation policy answers natively."
            }()
        ))

        let channels = inputs.remoteChannels
        if channels?.feishuApprovalEnabled == true {
            let complete = !(channels?.feishuAppID ?? "").isEmpty
                && !(channels?.feishuAppSecret ?? "").isEmpty
                && !(channels?.feishuApproverID ?? "").isEmpty
            checks.append(SystemDiagnostic(
                id: "feishu-approval",
                displayName: "Feishu approval",
                state: complete ? .ok : .warn,
                message: complete
                    ? "App credentials and approver configured."
                    : "Feishu approval enabled but app ID, secret or approver is missing."
            ))
        } else {
            checks.append(SystemDiagnostic(
                id: "feishu-approval",
                displayName: "Feishu approval",
                state: .notApplicable,
                message: "Not enabled."
            ))
        }

        checks.append(SystemDiagnostic(
            id: "theme-health",
            displayName: "Theme",
            state: inputs.themeStateCount > 0 ? .ok : .warn,
            message: inputs.themeStateCount > 0
                ? "Theme \"\(inputs.themeID)\" provides \(inputs.themeStateCount) states."
                : "Theme \"\(inputs.themeID)\" exposes no states; the built-in pet is used."
        ))

        if inputs.remoteSSHProfileCount > 0 {
            checks.append(SystemDiagnostic(
                id: "remote-ssh-ingress",
                displayName: "Remote SSH ingress",
                state: inputs.remoteSSHIngressActive ? .ok : .warn,
                message: inputs.remoteSSHIngressActive
                    ? "Nonce-gated loopback ingress active for \(inputs.remoteSSHProfileCount) profile(s)."
                    : "\(inputs.remoteSSHProfileCount) profile(s) configured but the ingress is not listening."
            ))
            checks.append(SystemDiagnostic(
                id: "remote-ssh-isolation",
                displayName: "Remote SSH isolation",
                state: .ok,
                message: "Profiles connect through isolated per-profile ingress with rotating nonces."
            ))
        } else {
            checks.append(SystemDiagnostic(
                id: "remote-ssh-ingress",
                displayName: "Remote SSH ingress",
                state: .notApplicable,
                message: "No remote profiles configured."
            ))
            checks.append(SystemDiagnostic(
                id: "remote-ssh-isolation",
                displayName: "Remote SSH isolation",
                state: .notApplicable,
                message: "No remote profiles configured."
            ))
        }

        return checks
    }

    /// A copyable diagnostic report with secrets and absolute home paths
    /// redacted (upstream doctor-report.js).
    public func diagnosticReport(
        agentDiagnostics: [AgentDiagnostic],
        systemDiagnostics: [SystemDiagnostic],
        appVersion: String
    ) -> String {
        func redact(_ text: String) -> String {
            text
                .replacingOccurrences(of: installer.homeDirectory.path, with: "~")
                .replacingOccurrences(of: installer.codexHomeDirectory.path, with: "~")
        }
        var lines: [String] = []
        lines.append("# Clawdesk diagnostic report")
        lines.append("- Version: \(appVersion)")
        lines.append("- Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("## System checks")
        for check in systemDiagnostics {
            lines.append("- [\(check.state.rawValue.uppercased())] \(check.displayName): \(redact(check.message))")
        }
        lines.append("")
        lines.append("## Agent integrations")
        for diagnostic in agentDiagnostics {
            let urls = configURLs(for: diagnostic.agentID)
                .map { redact($0.path) }
                .joined(separator: ", ")
            lines.append("- [\(diagnostic.state.rawValue.uppercased())] \(diagnostic.displayName): \(diagnostic.message)\(urls.isEmpty ? "" : " (\(urls))")")
        }
        return lines.joined(separator: "\n")
    }

    public func configURLs(for agentID: String) -> [URL] {
        let home = installer.homeDirectory
        switch AgentRegistry.canonicalID(for: agentID) {
        case "claude-code": return [home.appendingPathComponent(".claude/settings.json")]
        case "codex": return [installer.codexHomeDirectory.appendingPathComponent("hooks.json")]
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
        case "traecode": return [home.appendingPathComponent(".trae-cn/hooks.json")]
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

    /// Returns agents for which Clawdesk can prove ownership of an existing
    /// integration. Startup reconciliation uses this instead of guessing
    /// from an agent's executable or creating every possible config file.
    public func managedAgentIDs() -> [String] {
        AgentRegistry.all.compactMap { agent in
            guard HookInstaller.supportedAgentIDs.contains(agent.id),
                  integrationResourceURLs(for: agent.id).contains(where: {
                      isManagedResource($0, agentID: agent.id)
                  }) else { return nil }
            return agent.id
        }
    }

    private func integrationResourceURLs(for agentID: String) -> [URL] {
        let home = installer.homeDirectory
        switch agentID {
        case "opencode":
            return configURLs(for: agentID) + [
                home.appendingPathComponent("Library/Application Support/Clawdesk/plugins/opencode-plugin", isDirectory: true)
            ]
        case "mimocode":
            return configURLs(for: agentID) + [
                home.appendingPathComponent("Library/Application Support/Clawdesk/plugins/mimocode-plugin", isDirectory: true)
            ]
        case "openclaw":
            return configURLs(for: agentID) + [
                home.appendingPathComponent("Library/Application Support/Clawdesk/plugins/openclaw-plugin", isDirectory: true)
            ]
        case "hermes":
            let root = ProcessInfo.processInfo.environment["HERMES_HOME"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home.appendingPathComponent(".hermes", isDirectory: true)
            return [root.appendingPathComponent("plugins/clawdesk", isDirectory: true)]
        case "pi":
            return [home.appendingPathComponent(".pi/agent/extensions/clawdesk", isDirectory: true)]
        case "deepseek-harness":
            let root = ProcessInfo.processInfo.environment["DSH_HOME"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home.appendingPathComponent(".dsh", isDirectory: true)
            return [root.appendingPathComponent("profiles/web/node_modules/@dsh-external/dsh-clawd-bridge", isDirectory: true)]
        default:
            return configURLs(for: agentID)
        }
    }

    private func isManagedResource(_ url: URL, agentID: String) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let markerURL = url.appendingPathComponent(".clawdesk-managed.json")
            guard let data = try? Data(contentsOf: markerURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["app"] as? String == "Clawdesk"
                && object["agent"] as? String == agentID
                && object["marker"] as? String == "clawdesk-plugin-v1"
        }

        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 2_000_000 {
            return false
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(HookInstaller.marker)
            || text.contains("# BEGIN CLAWDESK agent=\(agentID)")
            || text.contains("clawdesk-plugin-v1")
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
