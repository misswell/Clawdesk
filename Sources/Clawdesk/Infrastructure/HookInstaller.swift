import Foundation

public struct HookInstallResult: Sendable {
    public let agentID: String
    public let configPath: URL
    public let changed: Bool
    public let message: String
}

public enum HookInstallerError: LocalizedError {
    case invalidConfiguration(URL)
    case unsupportedAgent(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(url): return "Could not parse \(url.path). A backup was left untouched."
        case let .unsupportedAgent(agent): return "No native hook adapter is registered for \(agent)."
        }
    }
}

@MainActor
public final class HookInstaller {
    public static let marker = "clawdesk-hook-v1"
    private static let statuslineMarker = "ClawdeskStatusline"

    let fileManager: FileManager
    let homeDirectory: URL
    let appSupportDirectory: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        appSupportDirectory = homeDirectory.appendingPathComponent("Library/Application Support/Clawdesk", isDirectory: true)
    }

    public var runtimeFile: URL {
        appSupportDirectory.appendingPathComponent("runtime.json")
    }

    public var hookScript: URL {
        appSupportDirectory.appendingPathComponent("hooks/\(Self.marker)", isDirectory: false)
    }

    public func writeRuntimeFile(port: UInt16, autoStart: Bool = false) throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "name": "Clawdesk",
            "port": Int(port),
            "autoStart": autoStart,
            "updatedAt": ISO8601DateFormatter().string(from: .now)
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: runtimeFile, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeFile.path)
    }

    public func install(agentID: String, port: UInt16) throws -> HookInstallResult {
        switch agentID {
        case "claude-code": return try installClaudeHooks(port: port)
        case "codex": return try installCodexHooks(port: port)
        default: return try installAdditionalAgentHooks(agentID: agentID, port: port)
        }
    }

    /// Repairs an integration that is already owned by Clawdesk. Most
    /// adapters are naturally existing-only because their managed marker lives
    /// in the config they merge; Kimi needs a separate path to avoid creating
    /// its legacy profile while repairing the modern profile.
    public func repairExistingAgent(agentID: String, port: UInt16) throws -> HookInstallResult {
        if agentID == "kimi-cli" {
            return try repairKimiHooks()
        }
        return try install(agentID: agentID, port: port)
    }

    public func uninstall(agentID: String) throws -> HookInstallResult {
        switch agentID {
        case "claude-code": return try uninstallClaudeHooks()
        case "codex": return try uninstallCodexHooks()
        default: return try uninstallAdditionalAgentHooks(agentID: agentID)
        }
    }

    public func installClaudeHooks(port: UInt16) throws -> HookInstallResult {
        let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        let (settings, changed, hooks) = try installClaudeHookEntries(port: port)
        var updatedSettings = settings
        updatedSettings["hooks"] = hooks
        if changed { try writeJSON(updatedSettings, to: settingsURL) }
        return HookInstallResult(
            agentID: "claude-code",
            configPath: settingsURL,
            changed: changed,
            message: changed ? "Claude Code hooks installed. Existing hooks were preserved." : "Claude Code hooks already installed."
        )
    }

    /// Opt-in Claude usage status line. Called only when the user enables
    /// "Collect local Claude usage"; it takes the slot when it is empty or
    /// already owned by Clawdesk and never replaces a custom renderer.
    public func ensureClaudeStatusLine() throws -> Bool {
        guard let statusline = statuslineExecutable else { return false }
        let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        var settings = try readJSONObject(at: settingsURL)
        let desired: [String: Any] = [
            "type": "command",
            "command": statusline.path.shellQuoted,
            "padding": 0
        ]
        var changed = false
        if let existing = settings["statusLine"] as? [String: Any],
           let command = existing["command"] as? String,
           command.contains(Self.statuslineMarker) {
            if !jsonValuesEqual(existing, desired) {
                settings["statusLine"] = desired
                changed = true
            }
        } else if settings["statusLine"] == nil {
            settings["statusLine"] = desired
            changed = true
        }
        if changed { try writeJSON(settings, to: settingsURL) }
        return changed
    }

    /// Removes only a Clawdesk-owned statusLine, leaving a user's custom
    /// renderer untouched.
    public func removeClaudeStatusLine() throws -> Bool {
        let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        guard fileManager.fileExists(atPath: settingsURL.path) else { return false }
        var settings = try readJSONObject(at: settingsURL)
        guard let statusline = settings["statusLine"] as? [String: Any],
              let command = statusline["command"] as? String,
              command.contains(Self.statuslineMarker) else { return false }
        settings.removeValue(forKey: "statusLine")
        try writeJSON(settings, to: settingsURL)
        return true
    }

    /// Regenerates the hook script and merges the managed hook entries without
    /// touching the statusLine slot. Used by the periodic health monitor so an
    /// auto-repair can never opt a user into the usage status line.
    public func repairClaudeHooks(port: UInt16) throws -> HookInstallResult {
        let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        let (settings, changed, hooks) = try installClaudeHookEntries(port: port)
        var updated = settings
        updated["hooks"] = hooks
        if changed { try writeJSON(updated, to: settingsURL) }
        return HookInstallResult(
            agentID: "claude-code",
            configPath: settingsURL,
            changed: changed,
            message: changed ? "Claude Code hooks repaired. Existing hooks were preserved." : "Claude Code hooks are healthy."
        )
    }

    private func installClaudeHookEntries(port: UInt16) throws -> ([String: Any], Bool, [String: Any]) {
        try prepareHookScript()
        let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
        var settings = try readJSONObject(at: settingsURL)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        let stateEvents = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PostToolUseFailure", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "Notification",
            "Elicitation", "WorktreeCreate", "PreCompact", "PostCompact"
        ]
        var changed = false
        for event in stateEvents {
            let command = "\(hookScript.path) \(event)"
            let desired: [String: Any] = [
                "matcher": "",
                "hooks": [["type": "command", "command": command, "async": true, "timeout": 5]]
            ]
            var entries = normalizedEntries(hooks[event])
            if !containsManagedEntry(entries) {
                entries.append(desired)
                hooks[event] = entries
                changed = true
            }
        }

        let permissionURL = "http://127.0.0.1:\(port)/permission"
        var permissionEntries = normalizedEntries(hooks["PermissionRequest"])
        let permissionHook: [String: Any] = [
            "matcher": "",
            // Keep the ownership marker in the URL. A plain /permission URL
            // is not enough to prove that it belongs to Clawdesk and could be
            // a user's own HTTP integration.
            "hooks": [["type": "http", "url": permissionURL + "?event=PermissionRequest&agent=claude-code&clawdesk-hook-v1=1", "timeout": 600]]
        ]
        if !permissionEntries.contains(where: { entry in
            let values = flattenHookEntries(entry)
            return values.contains(where: {
                ($0["type"] as? String) == "http"
                    && ($0["url"] as? String)?.contains(Self.marker) == true
            })
        }) {
            permissionEntries.append(permissionHook)
            hooks["PermissionRequest"] = permissionEntries
            changed = true
        }
        settings["hooks"] = hooks
        return (settings, changed, hooks)
    }

    public func installCodexHooks(port: UInt16) throws -> HookInstallResult {
        try prepareHookScript()
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        var settings = try readJSONObject(at: hooksURL)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"] {
            let command = "\(hookScript.path) \(event)"
            var entries = normalizedEntries(hooks[event])
            if !containsManagedEntry(entries) {
                entries.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
                hooks[event] = entries
                changed = true
            }
        }
        settings["hooks"] = hooks
        if changed { try writeJSON(settings, to: hooksURL) }
        try enableCodexHooksFeature(at: codexDirectory.appendingPathComponent("config.toml"))
        _ = port
        return HookInstallResult(
            agentID: "codex",
            configPath: hooksURL,
            changed: changed,
            message: changed ? "Codex hooks installed. Review them with /hooks in Codex." : "Codex hooks already installed."
        )
    }

    private func uninstallClaudeHooks() throws -> HookInstallResult {
        let url = homeDirectory.appendingPathComponent(".claude/settings.json")
        var settings = try readJSONObject(at: url)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        for key in hooks.keys {
            let entries = normalizedEntries(hooks[key])
            let filtered = entries.filter { !containsManagedEntry([$0]) }
            if filtered.count != entries.count {
                changed = true
                if filtered.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = filtered }
            }
        }
        if let statusline = settings["statusLine"] as? [String: Any],
           let command = statusline["command"] as? String,
           command.contains(Self.statuslineMarker) {
            settings.removeValue(forKey: "statusLine")
            changed = true
        }
        settings["hooks"] = hooks
        if changed { try writeJSON(settings, to: url) }
        return HookInstallResult(agentID: "claude-code", configPath: url, changed: changed, message: "Clawdesk Claude hooks removed; user hooks were preserved.")
    }

    private func uninstallCodexHooks() throws -> HookInstallResult {
        let url = homeDirectory.appendingPathComponent(".codex/hooks.json")
        var settings = try readJSONObject(at: url)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var changed = false
        for key in hooks.keys {
            let entries = normalizedEntries(hooks[key])
            let filtered = entries.filter { !containsManagedEntry([$0]) }
            if filtered.count != entries.count {
                changed = true
                if filtered.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = filtered }
            }
        }
        settings["hooks"] = hooks
        if changed { try writeJSON(settings, to: url) }
        return HookInstallResult(agentID: "codex", configPath: url, changed: changed, message: "Clawdesk Codex hooks removed; user hooks were preserved.")
    }

    private func prepareHookScript() throws {
        let directory = hookScript.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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
        LOWER_EVENT=$(printf '%s' "$EVENT" | /usr/bin/tr '[:upper:]' '[:lower:]')
        ROUTE="state"
        case "$LOWER_EVENT" in
          *permission*|permissionrequest) ROUTE="permission" ;;
        esac
        URL="http://127.0.0.1:${PORT}/${ROUTE}?event=${EVENT}&agent=${AGENT}&clawdesk-hook-v1=1"
        BODY=$(/bin/cat)
        [ -z "$BODY" ] && BODY='{}'
        if [ "$ROUTE" = "permission" ]; then
          PERMISSION_TIMEOUT=540
          [ "$AGENT" = "zcode" ] && PERMISSION_TIMEOUT=590
          RESPONSE=$(printf '%s' "$BODY" | /usr/bin/curl --silent --show-error --max-time "$PERMISSION_TIMEOUT" --connect-timeout 1 \
            -H 'Content-Type: application/json' --data-binary @- "$URL" 2>/dev/null)
          if [ "$AGENT" = "zcode" ]; then
            [ -z "$RESPONSE" ] && RESPONSE='{}'
          elif [ -z "$RESPONSE" ]; then
            RESPONSE='{"behavior":"ask","approved":false}'
          fi
          printf '%s' "$RESPONSE"
        else
          printf '%s' "$BODY" | /usr/bin/curl --silent --max-time 5 --connect-timeout 1 \
            -H 'Content-Type: application/json' --data-binary @- "$URL" >/dev/null 2>&1 || true
        fi
        exit 0
        """
        try script.data(using: .utf8)?.write(to: hookScript, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookScript.path)
    }

    private var statuslineExecutable: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let candidate = executable.deletingLastPathComponent().appendingPathComponent("ClawdeskStatusline")
        return candidate
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
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
            if !fileManager.fileExists(atPath: backup.path) {
                try fileManager.copyItem(at: url, to: backup)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func normalizedEntries(_ value: Any?) -> [[String: Any]] {
        if let entries = value as? [[String: Any]] { return entries }
        if let entry = value as? [String: Any] { return [entry] }
        return []
    }

    private func flattenHookEntries(_ entry: [String: Any]) -> [[String: Any]] {
        if let nested = entry["hooks"] as? [[String: Any]] { return nested }
        return [entry]
    }

    private func containsManagedEntry(_ entries: [[String: Any]]) -> Bool {
        for entry in entries {
            for hook in flattenHookEntries(entry) {
                let command = hook["command"] as? String ?? ""
                let url = hook["url"] as? String ?? ""
                if command.contains(Self.marker) || url.contains("/permission") && url.contains("127.0.0.1") {
                    return true
                }
            }
        }
        return false
    }

    private func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs), JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else {
            return false
        }
        return left == right
    }

    private func enableCodexHooksFeature(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            try "[features]\nhooks = true\n".data(using: .utf8)?.write(to: url, options: .atomic)
            return
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        if source.range(of: #"(?m)^\s*hooks\s*=\s*false\s*$"#, options: .regularExpression) != nil { return }
        if source.range(of: #"(?m)^\s*hooks\s*="#, options: .regularExpression) != nil { return }
        // Merge into an existing [features] table instead of emitting a second
        // header, which would produce invalid TOML and break official hooks.
        if let features = source.range(of: #"(?m)^\s*\[features\]\s*$"#, options: .regularExpression) {
            let insertion = "\nhooks = true"
            let updated = String(source[..<features.upperBound]) + insertion + String(source[features.upperBound...])
            try updated.data(using: .utf8)?.write(to: url, options: .atomic)
            return
        }
        let updated = source.hasSuffix("\n") ? source + "[features]\nhooks = true\n" : source + "\n[features]\nhooks = true\n"
        try updated.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

private extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
