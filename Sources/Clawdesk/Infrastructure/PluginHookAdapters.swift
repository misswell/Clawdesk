import Foundation

private let pluginMarker = "clawdesk-plugin-v1"

/// Native, dependency-free plugin adapters for agents that do not expose a
/// Claude/Codex-style hook file. The adapters install small bridge modules
/// into the agent's own extension directory and keep configuration ownership
/// explicit so uninstall never removes a user's unrelated plugin.
@MainActor
extension HookInstaller {
    func installOpenCodeFamilyPlugin(agentID: String, port: UInt16) throws -> HookInstallResult {
        let pluginDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/Clawdesk/plugins", isDirectory: true)
            .appendingPathComponent(agentID == "opencode" ? "opencode-plugin" : "mimocode-plugin", isDirectory: true)
        var changed = try installManagedPluginDirectory(
            pluginDirectory,
            agentID: agentID,
            files: [
                "index.mjs": familyPluginSource(agentID: agentID, port: port),
                "package.json": familyPackageSource(agentID: agentID)
            ]
        )

        let configURL = preferredFamilyConfigURL(agentID: agentID)
        let source = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = try installPluginReference(
            in: source,
            pluginPath: pluginDirectory.path,
            agentID: agentID,
            jsonc: configURL.pathExtension.lowercased() == "jsonc",
            schema: agentID == "opencode" ? "https://opencode.ai/config.json" : "https://mimo.xiaomi.com/mimocode/config.json"
        )
        if updated.changed {
            try writeManagedText(updated.text, to: configURL, backupExisting: !source.isEmpty)
            changed = true
        }

        return HookInstallResult(
            agentID: agentID,
            configPath: configURL,
            changed: changed,
            message: changed ? "\(agentID) plugin installed." : "\(agentID) plugin already installed."
        )
    }

    func uninstallOpenCodeFamilyPlugin(agentID: String) throws -> HookInstallResult {
        let pluginDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/Clawdesk/plugins", isDirectory: true)
            .appendingPathComponent(agentID == "opencode" ? "opencode-plugin" : "mimocode-plugin", isDirectory: true)
        var changed = false

        for configURL in familyConfigCandidates(agentID: agentID) where fileManager.fileExists(atPath: configURL.path) {
            let source = try String(contentsOf: configURL, encoding: .utf8)
            let updated = removePluginReference(
                from: source,
                pluginPath: pluginDirectory.path,
                agentID: agentID
            )
            if updated.changed {
                try writeManagedText(updated.text, to: configURL, backupExisting: true)
                changed = true
            }
        }

        if isManagedPluginDirectory(pluginDirectory, agentID: agentID) {
            try fileManager.removeItem(at: pluginDirectory)
            changed = true
        }
        let configURL = preferredFamilyConfigURL(agentID: agentID)
        return HookInstallResult(
            agentID: agentID,
            configPath: configURL,
            changed: changed,
            message: changed ? "Managed \(agentID) plugin removed." : "No managed \(agentID) plugin found."
        )
    }

    func installOpenClawPlugin(port: UInt16) throws -> HookInstallResult {
        let pluginDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/Clawdesk/plugins/openclaw-plugin", isDirectory: true)
        var changed = try installManagedPluginDirectory(
            pluginDirectory,
            agentID: "openclaw",
            files: [
                "index.js": openClawPluginSource(port: port),
                "package.json": #"{"name":"clawdesk","version":"0.1.0","private":true,"type":"module","main":"./index.js"}"#,
                "openclaw.plugin.json": #"{"id":"clawdesk","name":"Clawdesk","activation":{"onStartup":true}}"#
            ]
        )
        let configURL = homeDirectory.appendingPathComponent(".openclaw/openclaw.json")
        var settings = try readPluginJSON(at: configURL)
        var plugins = settings["plugins"] as? [String: Any] ?? [:]
        var load = plugins["load"] as? [String: Any] ?? [:]
        var paths = load["paths"] as? [Any] ?? []
        if !paths.contains(where: { ($0 as? String) == pluginDirectory.path }) {
            paths.append(pluginDirectory.path)
            changed = true
        }
        load["paths"] = paths
        plugins["load"] = load
        var entries = plugins["entries"] as? [String: Any] ?? [:]
        if let existing = entries["clawdesk"] as? [String: Any], !isManagedOpenClawEntry(existing, pluginPath: pluginDirectory.path) {
            throw HookInstallerError.invalidConfiguration(configURL)
        }
        let entry: [String: Any] = [
            "enabled": true,
            "path": pluginDirectory.path,
            "clawdesk": pluginMarker
        ]
        if !jsonObjectEqual(entries["clawdesk"], entry) {
            entries["clawdesk"] = entry
            changed = true
        }
        plugins["entries"] = entries
        settings["plugins"] = plugins
        if changed { try writePluginJSON(settings, to: configURL, backupExisting: fileManager.fileExists(atPath: configURL.path)) }

        return HookInstallResult(
            agentID: "openclaw",
            configPath: configURL,
            changed: changed,
            message: changed ? "OpenClaw plugin installed." : "OpenClaw plugin already installed."
        )
    }

    func uninstallOpenClawPlugin() throws -> HookInstallResult {
        let pluginDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/Clawdesk/plugins/openclaw-plugin", isDirectory: true)
        let configURL = homeDirectory.appendingPathComponent(".openclaw/openclaw.json")
        var changed = false
        if fileManager.fileExists(atPath: configURL.path) {
            var settings = try readPluginJSON(at: configURL)
            var plugins = settings["plugins"] as? [String: Any] ?? [:]
            var load = plugins["load"] as? [String: Any] ?? [:]
            if let paths = load["paths"] as? [Any] {
                let filtered = paths.filter { ($0 as? String) != pluginDirectory.path }
                if filtered.count != paths.count { load["paths"] = filtered; changed = true }
                plugins["load"] = load
            }
            if var entries = plugins["entries"] as? [String: Any],
               let existing = entries["clawdesk"] as? [String: Any],
               isManagedOpenClawEntry(existing, pluginPath: pluginDirectory.path) {
                entries.removeValue(forKey: "clawdesk")
                plugins["entries"] = entries
                changed = true
            }
            settings["plugins"] = plugins
            if changed { try writePluginJSON(settings, to: configURL, backupExisting: true) }
        }
        if isManagedPluginDirectory(pluginDirectory, agentID: "openclaw") {
            try fileManager.removeItem(at: pluginDirectory)
            changed = true
        }
        return HookInstallResult(
            agentID: "openclaw",
            configPath: configURL,
            changed: changed,
            message: changed ? "Managed OpenClaw plugin removed." : "No managed OpenClaw plugin found."
        )
    }

    func installHermesPlugin(port: UInt16) throws -> HookInstallResult {
        let hermesHome = hermesHomeDirectory
        let pluginDirectory = hermesHome.appendingPathComponent("plugins/clawdesk", isDirectory: true)
        let changed = try installManagedPluginDirectory(
            pluginDirectory,
            agentID: "hermes",
            files: [
                "plugin.yaml": hermesPluginManifest,
                "__init__.py": hermesPluginSource(port: port)
            ]
        )
        return HookInstallResult(
            agentID: "hermes",
            configPath: pluginDirectory,
            changed: changed,
            message: changed ? "Hermes plugin installed." : "Hermes plugin already installed."
        )
    }

    func uninstallHermesPlugin() throws -> HookInstallResult {
        let pluginDirectory = hermesHomeDirectory.appendingPathComponent("plugins/clawdesk", isDirectory: true)
        guard isManagedPluginDirectory(pluginDirectory, agentID: "hermes") else {
            return HookInstallResult(agentID: "hermes", configPath: pluginDirectory, changed: false, message: "No managed Hermes plugin found; unmanaged files were preserved.")
        }
        try fileManager.removeItem(at: pluginDirectory)
        return HookInstallResult(agentID: "hermes", configPath: pluginDirectory, changed: true, message: "Managed Hermes plugin removed.")
    }

    func installPiExtension(port: UInt16) throws -> HookInstallResult {
        let extensionDirectory = homeDirectory.appendingPathComponent(".pi/agent/extensions/clawdesk", isDirectory: true)
        let changed = try installManagedPluginDirectory(
            extensionDirectory,
            agentID: "pi",
            files: [
                "index.ts": piExtensionSource(port: port)
            ]
        )
        return HookInstallResult(agentID: "pi", configPath: extensionDirectory, changed: changed, message: changed ? "Pi extension installed." : "Pi extension already installed.")
    }

    func uninstallPiExtension() throws -> HookInstallResult {
        let extensionDirectory = homeDirectory.appendingPathComponent(".pi/agent/extensions/clawdesk", isDirectory: true)
        guard isManagedPluginDirectory(extensionDirectory, agentID: "pi") else {
            return HookInstallResult(agentID: "pi", configPath: extensionDirectory, changed: false, message: "No managed Pi extension found; unmanaged files were preserved.")
        }
        try fileManager.removeItem(at: extensionDirectory)
        return HookInstallResult(agentID: "pi", configPath: extensionDirectory, changed: true, message: "Managed Pi extension removed.")
    }

    func installDeepSeekHarnessPlugin(port: UInt16) throws -> HookInstallResult {
        let dshHome = deepSeekHarnessHomeDirectory
        let pluginDirectory = dshHome.appendingPathComponent("profiles/web/node_modules/@dsh-external/dsh-clawd-bridge", isDirectory: true)
        let changed = try installManagedPluginDirectory(
            pluginDirectory,
            agentID: "deepseek-harness",
            files: [
                "package.json": #"{"name":"@dsh-external/dsh-clawd-bridge","version":"0.1.0","type":"module","main":"lib/index.js"}"#,
                "lib/index.js": deepSeekHarnessPluginSource(port: port)
            ]
        )
        let manifest = pluginDirectory.appendingPathComponent("clawd-manifest.json")
        if !fileManager.fileExists(atPath: manifest.path) {
            let object: [String: Any] = ["owner": "Clawdesk", "version": 1, "protocol": 1]
            try writePluginJSON(object, to: manifest, backupExisting: false)
        }
        return HookInstallResult(agentID: "deepseek-harness", configPath: pluginDirectory, changed: changed, message: changed ? "DeepSeek Harness bridge staged; restart dsh web to load it." : "DeepSeek Harness bridge already staged.")
    }

    func uninstallDeepSeekHarnessPlugin() throws -> HookInstallResult {
        let pluginDirectory = deepSeekHarnessHomeDirectory.appendingPathComponent("profiles/web/node_modules/@dsh-external/dsh-clawd-bridge", isDirectory: true)
        guard isManagedPluginDirectory(pluginDirectory, agentID: "deepseek-harness") else {
            return HookInstallResult(agentID: "deepseek-harness", configPath: pluginDirectory, changed: false, message: "No managed DeepSeek Harness bridge found; unmanaged files were preserved.")
        }
        try fileManager.removeItem(at: pluginDirectory)
        return HookInstallResult(agentID: "deepseek-harness", configPath: pluginDirectory, changed: true, message: "Managed DeepSeek Harness bridge removed.")
    }

    private var hermesHomeDirectory: URL {
        if let value = ProcessInfo.processInfo.environment["HERMES_HOME"], !value.isEmpty { return URL(fileURLWithPath: value) }
        return homeDirectory.appendingPathComponent(".hermes", isDirectory: true)
    }

    private var deepSeekHarnessHomeDirectory: URL {
        if let value = ProcessInfo.processInfo.environment["DSH_HOME"], !value.isEmpty { return URL(fileURLWithPath: value) }
        return homeDirectory.appendingPathComponent(".dsh", isDirectory: true)
    }

    private func installManagedPluginDirectory(_ directory: URL, agentID: String, files: [String: String]) throws -> Bool {
        if fileManager.fileExists(atPath: directory.path), !isManagedPluginDirectory(directory, agentID: agentID) {
            throw HookInstallerError.invalidConfiguration(directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var changed = false
        for (name, content) in files {
            let file = directory.appendingPathComponent(name)
            let previous = try? String(contentsOf: file, encoding: .utf8)
            if previous != content {
                try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: file, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                changed = true
            }
        }
        let marker = directory.appendingPathComponent(".clawdesk-managed.json")
        let markerObject: [String: Any] = ["app": "Clawdesk", "agent": agentID, "marker": pluginMarker, "version": 1]
        let markerData = try JSONSerialization.data(withJSONObject: markerObject, options: [.prettyPrinted, .sortedKeys])
        if (try? Data(contentsOf: marker)) != markerData {
            try markerData.write(to: marker, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            changed = true
        }
        return changed
    }

    private func isManagedPluginDirectory(_ directory: URL, agentID: String) -> Bool {
        let marker = directory.appendingPathComponent(".clawdesk-managed.json")
        guard let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["app"] as? String == "Clawdesk"
            && object["agent"] as? String == agentID
            && object["marker"] as? String == pluginMarker
    }

    private func writeManagedText(_ source: String, to url: URL, backupExisting: Bool) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backupExisting, fileManager.fileExists(atPath: url.path) {
            let backup = url.deletingPathExtension().appendingPathExtension("clawdesk-backup\(url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")")
            if !fileManager.fileExists(atPath: backup.path) { try fileManager.copyItem(at: url, to: backup) }
        }
        try Data(source.utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readPluginJSON(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.invalidConfiguration(url)
        }
        return object
    }

    private func writePluginJSON(_ object: [String: Any], to url: URL, backupExisting: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try writeManagedText(String(decoding: data, as: UTF8.self) + "\n", to: url, backupExisting: backupExisting)
    }

    private func jsonObjectEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs,
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return left == right
    }

    private func isManagedOpenClawEntry(_ entry: [String: Any], pluginPath: String) -> Bool {
        entry["clawdesk"] as? String == pluginMarker || entry["path"] as? String == pluginPath
    }

    private func familyConfigCandidates(agentID: String) -> [URL] {
        let directory = homeDirectory.appendingPathComponent(agentID == "opencode" ? ".config/opencode" : ".config/mimocode", isDirectory: true)
        let names = agentID == "opencode"
            ? ["opencode.jsonc", "opencode.json", "config.json"]
            : ["mimocode.jsonc", "mimocode.json", "config.json"]
        return names.map { directory.appendingPathComponent($0) }
    }

    private func preferredFamilyConfigURL(agentID: String) -> URL {
        let candidates = familyConfigCandidates(agentID: agentID)
        if let declaring = candidates.first(where: { url in
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return source.range(of: #""plugin"\s*:"#, options: .regularExpression) != nil
        }) { return declaring }
        if let existing = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) { return existing }
        return candidates[agentID == "opencode" ? 1 : 0]
    }

    private func installPluginReference(in source: String, pluginPath: String, agentID: String, jsonc: Bool, schema: String) throws -> (text: String, changed: Bool) {
        let escapedPath = jsonString(pluginPath)
        let slashEscapedPath = escapedPath.replacingOccurrences(of: "/", with: "\\/")
        if source.contains("\"\(escapedPath)\"") || source.contains("\"\(slashEscapedPath)\"") { return (source, false) }
        if let markerLine = source.split(separator: "\n", omittingEmptySubsequences: false).firstIndex(where: { $0.contains(pluginMarker) }) {
            var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines[markerLine] = "    \"\(escapedPath)\"\(jsonc ? " // \(pluginMarker) agent=\(agentID)" : "")"
            return (lines.joined(separator: "\n"), true)
        }

        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let suffix = jsonc ? " // \(pluginMarker) agent=\(agentID)" : ""
            return (#"{"# + "\n  \"$schema\": \"\(schema)\",\n  \"plugin\": [\n    \"\(escapedPath)\"\(suffix)\n  ]\n}\n", true)
        }
        if let (open, close) = pluginArrayBounds(in: source) {
            let ns = source as NSString
            let body = ns.substring(with: NSRange(location: open + 1, length: close - open - 1))
            let hasValue = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let suffix = jsonc ? " // \(pluginMarker) agent=\(agentID)" : ""
            let insertion = (hasValue ? ",\n" : "\n") + "    \"\(escapedPath)\"\(suffix)\n"
            let updated = ns.substring(with: NSRange(location: 0, length: close)) + insertion + ns.substring(from: close)
            return (updated, true)
        }

        guard let close = source.lastIndex(of: "}") else { throw HookInstallerError.invalidConfiguration(preferredFamilyConfigURL(agentID: agentID)) }
        let prefix = String(source[..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        let needsComma = prefix.last != "{" && prefix.last != ","
        let suffix = jsonc ? " // \(pluginMarker) agent=\(agentID)" : ""
        let property = (needsComma ? "," : "") + "\n  \"plugin\": [\n    \"\(escapedPath)\"\(suffix)\n  ]\n"
        return (String(source[..<close]) + property + String(source[close...]), true)
    }

    private func removePluginReference(from source: String, pluginPath: String, agentID: String) -> (text: String, changed: Bool) {
        let escapedPath = jsonString(pluginPath)
        let pathVariants = [escapedPath, escapedPath.replacingOccurrences(of: "/", with: "\\/")]
        let quotedPaths = pathVariants.map { "\"\($0)\"" }
        let ownedMarker = "\(pluginMarker) agent=\(agentID)"
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var changed = false
        lines = lines.compactMap { line in
            if line.contains(ownedMarker) {
                changed = true
                return nil
            }
            if let quotedPath = quotedPaths.first(where: { line.contains($0) }) {
                changed = true
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix(quotedPath) { return nil }
                return line.replacingOccurrences(of: quotedPath, with: "")
            }
            return line
        }
        var text = lines.joined(separator: "\n")
        let noLeadingComma = text.replacingOccurrences(of: #"\[\s*,\s*"#, with: "[", options: .regularExpression)
        if noLeadingComma != text { changed = true; text = noLeadingComma }
        let noDoubleComma = text.replacingOccurrences(of: #",\s*,\s*"#, with: ",", options: .regularExpression)
        if noDoubleComma != text { changed = true; text = noDoubleComma }
        let collapsed = text.replacingOccurrences(of: #",\s*\]"#, with: "]", options: .regularExpression)
        if collapsed != text { changed = true; text = collapsed }
        return (text, changed)
    }

    private func pluginArrayBounds(in source: String) -> (open: Int, close: Int)? {
        guard let match = try? NSRegularExpression(pattern: #""plugin"\s*:\s*\["#, options: []),
              let result = match.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) else { return nil }
        let open = NSMaxRange(result.range) - 1
        let units = Array(source.utf16)
        var depth = 0
        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        var index = open
        while index < units.count {
            let value = units[index]
            if inLineComment { if value == 10 { inLineComment = false }; index += 1; continue }
            if inBlockComment { if value == 42, index + 1 < units.count, units[index + 1] == 47 { inBlockComment = false; index += 2 } else { index += 1 }; continue }
            if inString {
                if escaped { escaped = false }
                else if value == 92 { escaped = true }
                else if value == 34 { inString = false }
                index += 1; continue
            }
            if value == 34 { inString = true; index += 1; continue }
            if value == 47, index + 1 < units.count, units[index + 1] == 47 { inLineComment = true; index += 2; continue }
            if value == 47, index + 1 < units.count, units[index + 1] == 42 { inBlockComment = true; index += 2; continue }
            if value == 91 { depth += 1 }
            if value == 93 { depth -= 1; if depth == 0 { return (open, index) } }
            index += 1
        }
        return nil
    }

    private func jsonString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func familyPluginSource(agentID: String, port: UInt16) -> String {
        #"""
        import { readFileSync } from "node:fs";
        import { homedir } from "node:os";
        import { join } from "node:path";
        const AGENT_ID = "\#(agentID)";
        const DEFAULT_PORT = \#(port);
        const MARKER = "\#(pluginMarker)";
        function readPort() {
          try { const raw = JSON.parse(readFileSync(join(homedir(), "Library/Application Support/Clawdesk/runtime.json"), "utf8")); const value = Number(raw.port); return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_PORT; } catch { return DEFAULT_PORT; }
        }
        async function send(path, body) {
          try { const response = await fetch(`http://127.0.0.1:${readPort()}${path}?agent=${AGENT_ID}&clawdesk-hook-v1=1`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }); return response.ok ? await response.json() : null; } catch { return null; }
        }
        function sessionID(event, ctx) { return String(event?.properties?.sessionID || event?.properties?.info?.id || event?.sessionID || ctx?.sessionID || `${AGENT_ID}:default`); }
        function mapEvent(event) {
          const type = String(event?.type || ""); const p = event?.properties || {};
          if (type === "session.created") return ["SessionStart", "idle"];
          if (type === "session.deleted") return ["SessionEnd", "idle"];
          if (type === "session.idle") return ["Stop", "attention"];
          if (type === "session.compacted") return ["PostCompact", "attention"];
          if (type === "session.error") return ["StopFailure", "error"];
          if (type === "message.created" && p.message?.role === "user") return ["UserPromptSubmit", "thinking"];
          if (type === "message.part.updated") { const part = p.part || {}; if (part.type === "tool") { const status = part.state?.status; if (status === "running") return ["PreToolUse", "typing"]; if (status === "error") return ["PostToolUseFailure", "error"]; if (status === "completed") return ["PostToolUse", "typing"]; } }
          if (type === "permission.asked") return ["PermissionRequest", "notification"];
          return null;
        }
        export default async function ClawdeskPlugin(ctx = {}) {
          return { event: async ({ event } = {}) => { const mapped = mapEvent(event); if (!mapped) return; const sid = sessionID(event, ctx); const info = event?.properties?.info || {}; const body = { agent_id: AGENT_ID, hook_source: AGENT_ID + "-plugin", event: mapped[0], state: mapped[1], session_id: sid, session_title: info.title || undefined, cwd: info.directory || ctx.directory || undefined, permission_id: event?.properties?.permission?.id, title: event?.properties?.permission?.title || event?.properties?.permission?.message, action: event?.properties?.permission?.action, command: event?.properties?.permission?.command }; const reply = await send(mapped[0] === "PermissionRequest" ? "/permission" : "/state", body); if (mapped[0] === "PermissionRequest" && reply) return { status: reply.behavior === "allow" ? "once" : reply.behavior === "deny" ? "reject" : "ask" }; } };
        }
        """#
    }

    private func familyPackageSource(agentID: String) -> String {
        let name = agentID == "opencode" ? "clawd-opencode-plugin" : "clawd-mimocode-plugin"
        return #"{"name":"\#(name)","version":"0.1.0","private":true,"type":"module","main":"index.mjs"}"#
    }

    private func openClawPluginSource(port: UInt16) -> String {
        #"""
        import { readFileSync } from "node:fs";
        import { homedir } from "node:os";
        import { join } from "node:path";
        const AGENT_ID = "openclaw";
        const DEFAULT_PORT = \#(port);
        function readPort() { try { const raw = JSON.parse(readFileSync(join(homedir(), "Library/Application Support/Clawdesk/runtime.json"), "utf8")); const value = Number(raw.port); return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_PORT; } catch { return DEFAULT_PORT; } }
        async function post(event, state, native = {}, ctx = {}) { try { const body = { agent_id: AGENT_ID, hook_source: "openclaw-plugin", event, state, session_id: native.sessionId || ctx.sessionId || native.sessionKey || "openclaw:default", session_title: native.title || native.sessionTitle, cwd: native.cwd || ctx.workspaceDir, tool_name: native.toolName }; await fetch(`http://127.0.0.1:${readPort()}/state?clawdesk-hook-v1=1`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }); } catch {} }
        export default { id: "clawdesk", name: "Clawdesk", register(api) { if (!api?.on) return; const hooks = { session_start: ["SessionStart", "idle"], model_call_started: ["UserPromptSubmit", "thinking"], before_tool_call: ["PreToolUse", "typing"], after_tool_call: ["PostToolUse", "typing"], before_compaction: ["PreCompact", "sweeping"], after_compaction: ["PostCompact", "attention"], session_end: ["SessionEnd", "idle"] }; for (const [name, [event, state]] of Object.entries(hooks)) api.on(name, (native, ctx) => post(event, state, native, ctx), { priority: -100, timeoutMs: 1000 }); } };
        """#
    }

    private var hermesPluginManifest: String {
        #"""
name: clawdesk
version: "0.2.0"
description: "Forward Hermes lifecycle events to Clawdesk."
hooks:
  - on_session_start
  - pre_llm_call
  - post_llm_call
  - pre_tool_call
  - post_tool_call
  - on_session_end
  - on_session_finalize
"""#
    }

    private func hermesPluginSource(port: UInt16) -> String {
        #"""
        """Dependency-free Hermes Agent plugin for Clawdesk."""
        import json
        from pathlib import Path
        from urllib.request import Request, urlopen

        DEFAULT_PORT = \#(port)
        def _port():
            try:
                runtime = Path.home() / "Library" / "Application Support" / "Clawdesk" / "runtime.json"
                value = int(json.loads(runtime.read_text(encoding="utf-8")).get("port", DEFAULT_PORT))
                return value if 1 <= value <= 65535 else DEFAULT_PORT
            except Exception:
                return DEFAULT_PORT
        def _post(state, event, payload=None):
            body = {"agent_id": "hermes", "hook_source": "hermes-plugin", "state": state, "event": event, "session_id": str((payload or {}).get("session_id", "hermes:default"))}
            if isinstance(payload, dict):
                for key in ("title", "cwd", "tool_name", "command"):
                    if payload.get(key): body[key] = str(payload[key])[:500]
            try:
                req = Request(f"http://127.0.0.1:{_port()}/state?clawdesk-hook-v1=1", data=json.dumps(body).encode(), headers={"Content-Type":"application/json"}, method="POST")
                with urlopen(req, timeout=0.5): pass
            except Exception: pass
        def on_session_start(event=None, context=None, **kwargs): _post("idle", "SessionStart", event or context or kwargs)
        def pre_llm_call(event=None, context=None, **kwargs): _post("thinking", "UserPromptSubmit", event or context or kwargs)
        def post_llm_call(event=None, context=None, **kwargs): _post("attention", "Stop", event or context or kwargs)
        def pre_tool_call(event=None, context=None, **kwargs): _post("typing", "PreToolUse", event or context or kwargs)
        def post_tool_call(event=None, context=None, **kwargs): _post("typing", "PostToolUse", event or context or kwargs)
        def on_session_end(event=None, context=None, **kwargs): _post("attention", "Stop", event or context or kwargs)
        def on_session_finalize(event=None, context=None, **kwargs): _post("idle", "SessionEnd", event or context or kwargs)
        """#
    }

    private func piExtensionSource(port: UInt16) -> String {
        #"""
        import { readFileSync } from "node:fs";
        import { homedir } from "node:os";
        import { join } from "node:path";
        const DEFAULT_PORT = \#(port);
        function readPort() { try { const raw = JSON.parse(readFileSync(join(homedir(), "Library/Application Support/Clawdesk/runtime.json"), "utf8")); const value = Number(raw.port); return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_PORT; } catch { return DEFAULT_PORT; } }
        const post = async (event, state, native = {}, ctx = {}) => { try { await fetch(`http://127.0.0.1:${readPort()}/state?clawdesk-hook-v1=1`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ agent_id: "pi", hook_source: "pi-extension", event, state, session_id: `pi:${ctx?.sessionManager?.getSessionId?.() || "default"}`, cwd: ctx?.cwd, tool_name: native?.toolName }) }); } catch {} };
        export default function (pi) { if (!pi?.on) return; const bindings = { session_start: ["SessionStart", "idle"], before_agent_start: ["UserPromptSubmit", "thinking"], tool_call: ["PreToolUse", "typing"], tool_result: ["PostToolUse", "typing"], agent_end: ["Stop", "attention"], session_before_compact: ["PreCompact", "sweeping"], session_compact: ["PostCompact", "attention"], session_shutdown: ["SessionEnd", "idle"] }; for (const [name, [event, state]] of Object.entries(bindings)) pi.on(name, (native, ctx) => post(event, state, native, ctx)); pi.on("tool_result", (native, ctx) => native?.isError ? post("PostToolUseFailure", "error", native, ctx) : undefined); }
        """#
    }

    private func deepSeekHarnessPluginSource(port: UInt16) -> String {
        #"""
        import { readFileSync } from "node:fs";
        import { homedir } from "node:os";
        import { join } from "node:path";
        const DEFAULT_PORT = \#(port);
        function readPort() { try { const raw = JSON.parse(readFileSync(join(homedir(), "Library/Application Support/Clawdesk/runtime.json"), "utf8")); const value = Number(raw.port); return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_PORT; } catch { return DEFAULT_PORT; } }
        async function post(event, state, payload = {}) { try { await fetch(`http://127.0.0.1:${readPort()}/state?clawdesk-hook-v1=1`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ agent_id: "deepseek-harness", hook_source: "dsh-plugin", event, state, session_id: payload.sessionId || payload.session_id || "deepseek-harness:default", session_title: payload.title, tool_name: payload.toolName }) }); } catch {} }
        export default function createClawdeskBridge(api = {}) { const on = api.on || api.hook || api.addListener; if (!on) return {}; const hooks = { session_start: ["SessionStart", "idle"], turn_start: ["UserPromptSubmit", "thinking"], tool_start: ["PreToolUse", "typing"], tool_end: ["PostToolUse", "typing"], turn_end: ["Stop", "attention"], session_end: ["SessionEnd", "idle"] }; for (const [name, [event, state]] of Object.entries(hooks)) { try { on.call(api, name, payload => post(event, state, payload)); } catch {} } return {}; }
        """#
    }
}
