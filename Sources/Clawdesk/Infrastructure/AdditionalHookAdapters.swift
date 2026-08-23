import Foundation

/// Configuration adapters for agents whose hook files are not Claude/Codex
/// compatible. Keeping these descriptions data-driven is deliberate: the
/// upstream project adds events and agents frequently, while the transport
/// and ownership rules should remain stable.
@MainActor
extension HookInstaller {
    public static let supportedAgentIDs: Set<String> = [
        "claude-code", "codex", "copilot-cli", "gemini-cli", "antigravity-cli",
        "cursor-agent", "codebuddy", "workbuddy", "kiro-cli", "kimi-cli",
        "qwen-code", "zcode", "codewhale", "qoder", "qoderwork", "qwenwork",
        "reasonix", "opencode", "mimocode", "openclaw", "hermes", "pi", "deepseek-harness"
    ]

    func installAdditionalAgentHooks(agentID: String, port: UInt16) throws -> HookInstallResult {
        switch agentID {
        case "kimi-cli":
            return try installKimiHooks()
        case "codewhale":
            return try installCodeWhaleHooks()
        case "kiro-cli":
            return try installKiroHooks()
        case "opencode", "mimocode":
            return try installOpenCodeFamilyPlugin(agentID: agentID, port: port)
        case "openclaw":
            return try installOpenClawPlugin(port: port)
        case "hermes":
            return try installHermesPlugin(port: port)
        case "pi":
            return try installPiExtension(port: port)
        case "deepseek-harness":
            return try installDeepSeekHarnessPlugin(port: port)
        default:
            guard let spec = AgentHookSpec(agentID: agentID) else {
                throw HookInstallerError.unsupportedAgent(agentID)
            }
            return try installJSONHooks(spec: spec, port: port)
        }
    }

    func uninstallAdditionalAgentHooks(agentID: String) throws -> HookInstallResult {
        switch agentID {
        case "kimi-cli":
            return try uninstallKimiHooks()
        case "codewhale":
            return try uninstallCodeWhaleHooks()
        case "kiro-cli":
            return try uninstallKiroHooks()
        case "opencode", "mimocode":
            return try uninstallOpenCodeFamilyPlugin(agentID: agentID)
        case "openclaw":
            return try uninstallOpenClawPlugin()
        case "hermes":
            return try uninstallHermesPlugin()
        case "pi":
            return try uninstallPiExtension()
        case "deepseek-harness":
            return try uninstallDeepSeekHarnessPlugin()
        default:
            guard let spec = AgentHookSpec(agentID: agentID) else {
                throw HookInstallerError.unsupportedAgent(agentID)
            }
            return try uninstallJSONHooks(spec: spec)
        }
    }

    private func installJSONHooks(spec: AgentHookSpec, port: UInt16) throws -> HookInstallResult {
        try writeSharedHookScript()
        _ = port
        let configURL = homeDirectory.appendingPathComponent(spec.relativeConfigPath)
        var settings = try readJSON(at: configURL)
        var hookMap = dictionaryAtPath(settings, keys: spec.hookPath)
        var changed = false

        for event in spec.events {
            var entries = hookMap[event] as? [Any] ?? []
            if !entries.contains(where: { containsClawdeskMarker($0) }) {
                entries.append(spec.entry(for: event, hookScript: hookScript, port: port))
                hookMap[event] = entries
                changed = true
            }
        }

        if changed {
            setDictionaryAtPath(&settings, keys: spec.hookPath, value: hookMap)
            try writeJSON(settings, to: configURL)
        }

        let status = changed ? "installed" : "already installed"
        return HookInstallResult(
            agentID: spec.agentID,
            configPath: configURL,
            changed: changed,
            message: "\(spec.displayName) hooks \(status) at \(configURL.path). Existing entries were preserved."
        )
    }

    private func uninstallJSONHooks(spec: AgentHookSpec) throws -> HookInstallResult {
        let configURL = homeDirectory.appendingPathComponent(spec.relativeConfigPath)
        guard fileManager.fileExists(atPath: configURL.path) else {
            return HookInstallResult(
                agentID: spec.agentID,
                configPath: configURL,
                changed: false,
                message: "No managed \(spec.displayName) hooks found."
            )
        }

        var settings = try readJSON(at: configURL)
        var hookMap = dictionaryAtPath(settings, keys: spec.hookPath)
        var changed = false
        for event in spec.events {
            guard let original = hookMap[event] as? [Any] else { continue }
            let filtered = original.compactMap { removeClawdeskEntries(from: $0) }
            if !jsonValuesEqual(original, filtered) {
                changed = true
                if filtered.isEmpty { hookMap.removeValue(forKey: event) }
                else { hookMap[event] = filtered }
            }
        }
        if changed {
            setDictionaryAtPath(&settings, keys: spec.hookPath, value: hookMap)
            try writeJSON(settings, to: configURL)
        }
        return HookInstallResult(
            agentID: spec.agentID,
            configPath: configURL,
            changed: changed,
            message: changed ? "Managed \(spec.displayName) hooks removed." : "No managed \(spec.displayName) hooks found."
        )
    }

    private func installKiroHooks() throws -> HookInstallResult {
        try writeSharedHookScript()
        let configURL = homeDirectory.appendingPathComponent(".kiro/agents/clawdesk.json")
        var settings = try readJSON(at: configURL)
        if fileManager.fileExists(atPath: configURL.path), !containsClawdeskMarker(settings) {
            throw HookInstallerError.invalidConfiguration(configURL)
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        let events = ["agentSpawn", "userPromptSubmit", "preToolUse", "postToolUse", "stop"]
        for event in events {
            var entries = hooks[event] as? [Any] ?? []
            if !entries.contains(where: { containsClawdeskMarker($0) }) {
                entries.append(["command": shellCommand(event: event, agentID: "kiro-cli")])
                hooks[event] = entries
                changed = true
            }
        }
        settings["name"] = "clawdesk"
        settings["description"] = "Clawdesk desktop pet integration"
        settings["hooks"] = hooks
        if changed || !fileManager.fileExists(atPath: configURL.path) {
            try writeJSON(settings, to: configURL)
        }
        return HookInstallResult(
            agentID: "kiro-cli",
            configPath: configURL,
            changed: changed,
            message: changed ? "Kiro hooks installed in the managed clawdesk agent." : "Kiro hooks already installed."
        )
    }

    private func uninstallKiroHooks() throws -> HookInstallResult {
        let configURL = homeDirectory.appendingPathComponent(".kiro/agents/clawdesk.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            return HookInstallResult(agentID: "kiro-cli", configPath: configURL, changed: false, message: "No managed Kiro agent found.")
        }
        let settings = try readJSON(at: configURL)
        guard containsClawdeskMarker(settings) else {
            return HookInstallResult(agentID: "kiro-cli", configPath: configURL, changed: false, message: "Unmanaged Kiro agent preserved.")
        }
        try fileManager.removeItem(at: configURL)
        return HookInstallResult(agentID: "kiro-cli", configPath: configURL, changed: true, message: "Managed Kiro clawdesk agent removed.")
    }

    private func installKimiHooks() throws -> HookInstallResult {
        try writeSharedHookScript()
        let paths = [
            homeDirectory.appendingPathComponent(".kimi/config.toml"),
            homeDirectory.appendingPathComponent(".kimi-code/config.toml")
        ]
        var changedPaths: [URL] = []
        for path in paths {
            // Do not create a second-generation profile merely because the
            // user installed the legacy CLI. An existing directory is the
            // same presence signal used by the upstream installer.
            let parent = path.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: parent.path) || path == paths[0] else { continue }
            var source = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            let permissionMode = kimiPermissionMode(source: source, configURL: path)
            let region = tomlRegion(agentID: "kimi-cli", events: [
                "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PostToolUseFailure", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
                "PreCompact", "PostCompact", "Notification", "PermissionRequest", "PermissionResult", "Interrupt"
            ], style: "hooks", permissionMode: permissionMode)
            let updated = replaceTomlRegion(in: source, agentID: "kimi-cli", region: region)
            if updated != source {
                try writeText(updated, to: path)
                changedPaths.append(path)
                source = updated
            }
            _ = source
        }
        let primary = changedPaths.first ?? paths[0]
        return HookInstallResult(
            agentID: "kimi-cli",
            configPath: primary,
            changed: !changedPaths.isEmpty,
            message: changedPaths.isEmpty ? "Kimi hooks already installed." : "Kimi hooks installed for available config profiles."
        )
    }

    private func uninstallKimiHooks() throws -> HookInstallResult {
        let paths = [
            homeDirectory.appendingPathComponent(".kimi/config.toml"),
            homeDirectory.appendingPathComponent(".kimi-code/config.toml")
        ]
        var changed = false
        var primary = paths[0]
        for path in paths where fileManager.fileExists(atPath: path.path) {
            let source = try String(contentsOf: path, encoding: .utf8)
            let updated = removeTomlRegion(from: source, agentID: "kimi-cli")
            if updated != source {
                try writeText(updated, to: path)
                primary = path
                changed = true
            }
        }
        return HookInstallResult(agentID: "kimi-cli", configPath: primary, changed: changed, message: changed ? "Managed Kimi hooks removed." : "No managed Kimi hooks found.")
    }

    private func installCodeWhaleHooks() throws -> HookInstallResult {
        try writeSharedHookScript()
        let configURL = homeDirectory.appendingPathComponent(".codewhale/config.toml")
        let events = ["session_start", "session_end", "message_submit", "tool_call_before", "tool_call_after", "mode_change", "on_error"]
        let region = tomlRegion(agentID: "codewhale", events: events, style: "hooks.hooks")
        let source = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = replaceTomlRegion(in: source, agentID: "codewhale", region: region)
        let changed = updated != source
        if changed { try writeText(updated, to: configURL) }
        return HookInstallResult(agentID: "codewhale", configPath: configURL, changed: changed, message: changed ? "CodeWhale hooks installed." : "CodeWhale hooks already installed.")
    }

    private func uninstallCodeWhaleHooks() throws -> HookInstallResult {
        let configURL = homeDirectory.appendingPathComponent(".codewhale/config.toml")
        guard fileManager.fileExists(atPath: configURL.path) else {
            return HookInstallResult(agentID: "codewhale", configPath: configURL, changed: false, message: "No CodeWhale config found.")
        }
        let source = try String(contentsOf: configURL, encoding: .utf8)
        let updated = removeTomlRegion(from: source, agentID: "codewhale")
        let changed = updated != source
        if changed { try writeText(updated, to: configURL) }
        return HookInstallResult(agentID: "codewhale", configPath: configURL, changed: changed, message: changed ? "Managed CodeWhale hooks removed." : "No managed CodeWhale hooks found.")
    }

    private func writeSharedHookScript() throws {
        try fileManager.createDirectory(at: hookScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # clawdesk-hook-v1 — fail-open, dependency-free hook transport.
        RUNTIME="$HOME/Library/Application Support/Clawdesk/runtime.json"
        PORT=$(/usr/bin/grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' "$RUNTIME" 2>/dev/null | /usr/bin/tr -cd '0-9')
        AUTOSTART=$(/usr/bin/grep -o '"autoStart"[[:space:]]*:[[:space:]]*true' "$RUNTIME" 2>/dev/null | /usr/bin/grep -o 'true' | /usr/bin/head -1)
        if [ -n "$PORT" ] && [ "$AUTOSTART" = "true" ]; then
          /usr/bin/curl --silent --max-time 0.3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 || /usr/bin/open -ga Clawdesk >/dev/null 2>&1 || true
        elif [ -z "$PORT" ] && [ "$AUTOSTART" = "true" ]; then
          /usr/bin/open -ga Clawdesk >/dev/null 2>&1 || true
        fi
        [ -z "$PORT" ] && exit 0
        EVENT="${1:-Notification}"
        AGENT="${2:-custom}"
        MODE_FLAG="${3:-}"
        LOWER_EVENT=$(printf '%s' "$EVENT" | /usr/bin/tr '[:upper:]' '[:lower:]')
        ROUTE="state"
        case "$LOWER_EVENT" in
          *permission*|permissionrequest) ROUTE="permission" ;;
        esac
        MODE_QUERY=""
        case "$MODE_FLAG" in
          --permission-mode=suspect|--permission-mode=explicit) MODE_QUERY="&clawdesk-kimi-permission-mode=${MODE_FLAG#*=}" ;;
        esac
        URL="http://127.0.0.1:${PORT}/${ROUTE}?event=${EVENT}&agent=${AGENT}&clawdesk-hook-v1=1${MODE_QUERY}"
        BODY=$(/usr/bin/cat)
        [ -z "$BODY" ] && BODY='{}'
        if [ "$ROUTE" = "permission" ]; then
          printf '%s' "$BODY" | /usr/bin/curl --silent --show-error --max-time 540 --connect-timeout 1 \
            -H 'Content-Type: application/json' --data-binary @- "$URL" 2>/dev/null || \
            printf '%s' '{"behavior":"ask","approved":false}'
        else
          printf '%s' "$BODY" | /usr/bin/curl --silent --max-time 5 --connect-timeout 1 \
            -H 'Content-Type: application/json' --data-binary @- "$URL" >/dev/null 2>&1 || true
        fi
        exit 0
        """
        try script.data(using: .utf8)?.write(to: hookScript, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookScript.path)
    }

    private func shellCommand(event: String, agentID: String, extraArgument: String? = nil) -> String {
        let base = "\(hookScript.path.shellQuoted) \(event.shellQuoted) \(agentID.shellQuoted)"
        guard let extraArgument, !extraArgument.isEmpty else { return base }
        return base + " " + extraArgument.shellQuoted
    }

    private func readJSON(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.invalidConfiguration(url)
        }
        return object
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            let backup = url.deletingPathExtension().appendingPathExtension("clawdesk-backup.json")
            if !fileManager.fileExists(atPath: backup.path) { try fileManager.copyItem(at: url, to: backup) }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeText(_ source: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            let backup = url.deletingPathExtension().appendingPathExtension("clawdesk-backup\(url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")")
            if !fileManager.fileExists(atPath: backup.path) { try fileManager.copyItem(at: url, to: backup) }
        }
        try source.data(using: .utf8)?.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func dictionaryAtPath(_ root: [String: Any], keys: [String]) -> [String: Any] {
        var current: Any = root
        for key in keys {
            guard let dictionary = current as? [String: Any] else { return [:] }
            current = dictionary[key] ?? [:]
        }
        return current as? [String: Any] ?? [:]
    }

    private func setDictionaryAtPath(_ root: inout [String: Any], keys: [String], value: [String: Any]) {
        guard let first = keys.first else { return }
        guard keys.count > 1 else {
            root[first] = value
            return
        }
        var child = root[first] as? [String: Any] ?? [:]
        setDictionaryAtPath(&child, keys: Array(keys.dropFirst()), value: value)
        root[first] = child
    }

    private func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs), JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else {
            return false
        }
        return left == right
    }

    private func containsClawdeskMarker(_ value: Any) -> Bool {
        if let string = value as? String { return string.contains(HookInstaller.marker) }
        if let dictionary = value as? [String: Any] {
            for child in dictionary.values where containsClawdeskMarker(child) {
                return true
            }
        }
        if let array = value as? [Any] {
            for child in array where containsClawdeskMarker(child) {
                return true
            }
        }
        return false
    }

    private func removeClawdeskEntries(from value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if dictionary.contains(where: { key, value in
                ["command", "url", "bash", "powershell", "args"].contains(key)
                    && containsClawdeskMarker(value)
            }) {
                return nil
            }
            var copy = dictionary
            for (key, child) in dictionary {
                if let array = child as? [Any] {
                    let filtered = array.compactMap { removeClawdeskEntries(from: $0) }
                    if filtered.isEmpty && containsClawdeskMarker(child) { copy.removeValue(forKey: key) }
                    else if filtered.count != array.count { copy[key] = filtered }
                }
            }
            if copy.isEmpty && containsClawdeskMarker(value) { return nil }
            return copy
        }
        if let array = value as? [Any] {
            let filtered = array.compactMap { removeClawdeskEntries(from: $0) }
            return filtered
        }
        return value
    }

    private func tomlRegion(agentID: String, events: [String], style: String, permissionMode: String? = nil) -> String {
        let begin = "# BEGIN CLAWDESK agent=\(agentID) marker=\(HookInstaller.marker)"
        let end = "# END CLAWDESK agent=\(agentID)"
        var lines = [begin]
        for event in events {
            lines.append(style == "hooks.hooks" ? "[[hooks.hooks]]" : "[[hooks]]")
            lines.append("# \(HookInstaller.marker)")
            lines.append("event = \(event.tomlQuoted)")
            let argument = permissionMode.map { "--permission-mode=\($0)" }
            lines.append("command = \(shellCommand(event: event, agentID: agentID, extraArgument: argument).tomlQuoted)")
            if style == "hooks.hooks" {
                lines.append(event == "session_end" ? "timeout_secs = 30" : "timeout_secs = 5")
                lines.append(event == "session_end" ? "continue_on_error = true" : "background = true")
            } else {
                lines.append(event.lowercased().contains("permission") ? "timeout = 540" : "timeout = 30")
            }
            lines.append("")
        }
        lines.append(end)
        return lines.joined(separator: "\n")
    }

    private func kimiPermissionMode(source: String, configURL: URL) -> String? {
        // The modern .kimi-code CLI emits native PermissionRequest events and
        // does not need the legacy heuristic. Legacy .kimi defaults to the
        // deferred suspect cue, while an existing flag or explicit env value
        // is preserved across every re-sync.
        guard configURL.deletingLastPathComponent().lastPathComponent == ".kimi" else { return nil }
        let environment = ProcessInfo.processInfo.environment["CLAWD_KIMI_PERMISSION_MODE"]?.lowercased()
        if environment == "explicit" || environment == "suspect" { return environment }
        if let match = source.range(of: #"--permission-mode=(explicit|suspect)"#, options: .regularExpression) {
            let value = String(source[match])
            return value.components(separatedBy: "=").last
        }
        return "suspect"
    }

    private func replaceTomlRegion(in source: String, agentID: String, region: String) -> String {
        let begin = "# BEGIN CLAWDESK agent=\(agentID) marker=\(HookInstaller.marker)"
        let end = "# END CLAWDESK agent=\(agentID)"
        if let start = source.range(of: begin), let finish = source.range(of: end, range: start.upperBound..<source.endIndex) {
            return source.replacingCharacters(in: start.lowerBound..<finish.upperBound, with: region)
        }
        let prefix = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? region + "\n" : prefix + "\n\n" + region + "\n"
    }

    private func removeTomlRegion(from source: String, agentID: String) -> String {
        let begin = "# BEGIN CLAWDESK agent=\(agentID) marker=\(HookInstaller.marker)"
        let end = "# END CLAWDESK agent=\(agentID)"
        guard let start = source.range(of: begin), let finish = source.range(of: end, range: start.upperBound..<source.endIndex) else { return source }
        let result = source.replacingCharacters(in: start.lowerBound..<finish.upperBound, with: "")
        return result.replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

private enum AgentHookShape: Sendable {
    case nested
    case direct
    case copilot
    case zcode
}

private struct AgentHookSpec: Sendable {
    let agentID: String
    let displayName: String
    let relativeConfigPath: String
    let hookPath: [String]
    let events: [String]
    let shape: AgentHookShape

    init?(agentID: String) {
        self.agentID = agentID
        switch agentID {
        case "copilot-cli":
            displayName = "Copilot CLI"; relativeConfigPath = ".copilot/hooks/hooks.json"; hookPath = ["hooks"]; shape = .copilot
            events = ["sessionStart", "userPromptSubmitted", "preToolUse", "postToolUse", "sessionEnd", "errorOccurred", "agentStop", "subagentStart", "subagentStop", "preCompact", "permissionRequest"]
        case "gemini-cli":
            displayName = "Gemini CLI"; relativeConfigPath = ".gemini/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool", "Notification", "PreCompress"]
        case "antigravity-cli":
            displayName = "Antigravity CLI"; relativeConfigPath = ".gemini/config/hooks.json"; hookPath = ["hooks"]; shape = .nested
            events = ["PreInvocation", "PostToolUse", "PostInvocation", "Stop"]
        case "cursor-agent":
            displayName = "Cursor Agent"; relativeConfigPath = ".cursor/hooks.json"; hookPath = ["hooks"]; shape = .direct
            events = ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop", "preCompact", "afterAgentThought", "stop"]
        case "codebuddy":
            displayName = "CodeBuddy"; relativeConfigPath = ".codebuddy/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "PreCompact"]
        case "workbuddy":
            displayName = "WorkBuddy"; relativeConfigPath = ".workbuddy-ai/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "PreCompact"]
        case "qwen-code":
            displayName = "Qwen Code"; relativeConfigPath = ".qwen/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "PermissionRequest"]
        case "qoder":
            displayName = "Qoder"; relativeConfigPath = ".qoder/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "Notification", "PermissionRequest", "PermissionDenied", "SessionEnd"]
        case "qoderwork":
            displayName = "QoderWork"; relativeConfigPath = ".qoderwork/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "Notification", "PermissionRequest", "PermissionDenied", "SessionEnd"]
        case "qwenwork":
            displayName = "QwenWork"; relativeConfigPath = ".QwenWorkCN/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "Notification", "PermissionRequest", "PermissionDenied", "SessionEnd"]
        case "reasonix":
            displayName = "Reasonix CLI"; relativeConfigPath = ".reasonix/settings.json"; hookPath = ["hooks"]; shape = .nested
            events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStop", "Notification", "PreCompact"]
        case "zcode":
            displayName = "ZCode"; relativeConfigPath = ".zcode/cli/config.json"; hookPath = ["hooks", "events"]; shape = .zcode
            events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"]
        default:
            return nil
        }
    }

    func entry(for event: String, hookScript: URL, port: UInt16) -> [String: Any] {
        let command = "\(hookScript.path.shellQuoted) \(event.shellQuoted) \(agentID.shellQuoted)"
        switch shape {
        case .direct:
            return ["command": command]
        case .copilot:
            let timeout = event.lowercased().contains("permission") ? 600 : 5
            return [
                "type": "command",
                "bash": command,
                "powershell": "& \(command)",
                "timeoutSec": timeout
            ]
        case .zcode:
            return [
                "hooks": [[
                    "type": "process",
                    "command": "/bin/sh",
                    "args": [hookScript.path, event, agentID],
                    "timeoutMs": event.lowercased().contains("permission") ? 540_000 : 5_000
                ]]
            ]
        case .nested:
            var entry: [String: Any] = [
                "hooks": [[
                    "name": "clawdesk",
                    "type": "command",
                    "command": command,
                    "timeout": event.lowercased().contains("permission") ? 600 : 30
                ]]
            ]
            if event != "UserPromptSubmit" && event != "Stop" { entry["matcher"] = "*" }
            return entry
        }
    }
}

private extension URL {
    var shellQuoted: String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var tomlQuoted: String {
        "\"" + replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
