import AppKit
import Combine
import Foundation

public struct RemoteSSHProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var host: String
    public var port: Int
    public var identityFile: String?
    public var remoteForwardPort: Int
    public var hostPrefix: String?
    public var deployedAt: Date?
    public var routingNonce: String?
    public var transportMode: RemoteSSHTransportMode
    public var autoStartCodexFallback: Bool

    private enum CodingKeys: String, CodingKey {
        case id, label, host, port, identityFile, remoteForwardPort, hostPrefix, deployedAt, routingNonce
        case transportMode, autoStartCodexFallback
    }

    public init(
        id: String = UUID().uuidString,
        label: String = "Remote host",
        host: String,
        port: Int = 22,
        identityFile: String? = nil,
        remoteForwardPort: Int = 23333,
        hostPrefix: String? = nil,
        deployedAt: Date? = nil,
        routingNonce: String? = nil,
        transportMode: RemoteSSHTransportMode = .automatic,
        autoStartCodexFallback: Bool = false
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.identityFile = identityFile
        self.remoteForwardPort = remoteForwardPort
        self.hostPrefix = hostPrefix
        self.deployedAt = deployedAt
        self.routingNonce = routingNonce
        self.transportMode = transportMode
        self.autoStartCodexFallback = autoStartCodexFallback
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? "Remote host"
        host = try values.decode(String.self, forKey: .host)
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        identityFile = try values.decodeIfPresent(String.self, forKey: .identityFile)
        remoteForwardPort = try values.decodeIfPresent(Int.self, forKey: .remoteForwardPort) ?? 23333
        hostPrefix = try values.decodeIfPresent(String.self, forKey: .hostPrefix)
        deployedAt = try values.decodeIfPresent(Date.self, forKey: .deployedAt)
        routingNonce = try values.decodeIfPresent(String.self, forKey: .routingNonce)
        transportMode = try values.decodeIfPresent(RemoteSSHTransportMode.self, forKey: .transportMode) ?? .automatic
        autoStartCodexFallback = try values.decodeIfPresent(Bool.self, forKey: .autoStartCodexFallback) ?? false
    }
}

public enum RemoteSSHTransportMode: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case singleSession

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .singleSession: return "Force single SSH session"
        }
    }
}

public enum RemoteSSHStatus: String, Sendable {
    case idle
    case deploying
    case connecting
    case connected
    case failed

    public var displayName: String {
        switch self {
        case .idle: return "Disconnected"
        case .deploying: return "Deploying hooks…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed: return "Failed"
        }
    }
}

public enum RemoteSSHError: LocalizedError, Equatable {
    case invalidProfile
    case profileNotFound
    case deploymentRequired
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile: return "Remote SSH profile is incomplete or uses an invalid port."
        case .profileNotFound: return "Remote SSH profile was not found."
        case .deploymentRequired: return "Deploy or repair remote hooks before connecting."
        case let .commandFailed(message): return message
        }
    }
}

/// Small native Remote SSH adapter. It deploys a dependency-free shell hook,
/// installs it into Claude/Codex JSON configuration through remote Node.js,
/// and keeps an SSH reverse tunnel alive while the profile is connected.
@MainActor
public final class RemoteSSHManager: ObservableObject {
    public let configurationURL: URL
    public let eventServer: LocalEventServer

    @Published public private(set) var profiles: [RemoteSSHProfile]
    @Published public private(set) var statuses: [String: RemoteSSHStatus] = [:]
    @Published public private(set) var messages: [String: String] = [:]

    private let fileManager: FileManager
    private var tunnels: [String: Process] = [:]
    private var fallbackMonitors: [String: Process] = [:]
    private var pendingConnections = Set<String>()

    public init(
        eventServer: LocalEventServer,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.eventServer = eventServer
        self.fileManager = fileManager
        let directory = homeDirectory.appendingPathComponent("Library/Application Support/Clawdesk", isDirectory: true)
        configurationURL = directory.appendingPathComponent("remote-ssh.json")
        if let data = try? Data(contentsOf: configurationURL),
           let loaded = try? JSONDecoder().decode([RemoteSSHProfile].self, from: data) {
            profiles = loaded
        } else {
            profiles = []
        }
        for profile in profiles {
            if let nonce = profile.routingNonce, Self.isValidNonce(nonce) { eventServer.registerRemoteNonce(nonce) }
            statuses[profile.id] = .idle
        }
    }

    public func add(_ profile: RemoteSSHProfile) throws {
        try validate(profile)
        guard profiles.allSatisfy({ $0.id != profile.id }) else { return }
        profiles.append(profile)
        statuses[profile.id] = .idle
        try persist()
    }

    public func update(_ profile: RemoteSSHProfile) throws {
        try validate(profile)
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw RemoteSSHError.profileNotFound
        }
        let existing = profiles[index]
        let targetChanged = existing.label != profile.label
            || existing.host != profile.host
            || existing.port != profile.port
            || existing.identityFile != profile.identityFile
            || existing.remoteForwardPort != profile.remoteForwardPort
            || existing.hostPrefix != profile.hostPrefix
            || existing.transportMode != profile.transportMode
            || existing.autoStartCodexFallback != profile.autoStartCodexFallback
        var saved = profile
        if let oldNonce = existing.routingNonce, targetChanged || oldNonce != profile.routingNonce {
            eventServer.unregisterRemoteNonce(oldNonce)
            eventServer.stopRemoteIngress(nonce: oldNonce)
        }
        if targetChanged {
            saved.routingNonce = nil
            saved.deployedAt = nil
            statuses[profile.id] = .idle
            messages[profile.id] = "Profile changed; deploy hooks again before connecting."
        }
        profiles[index] = saved
        if let nonce = saved.routingNonce { eventServer.registerRemoteNonce(nonce) }
        try persist()
    }

    public func remove(id: String) throws {
        disconnect(id: id)
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let nonce = profiles[index].routingNonce { eventServer.unregisterRemoteNonce(nonce) }
        profiles.remove(at: index)
        statuses.removeValue(forKey: id)
        messages.removeValue(forKey: id)
        try persist()
    }

    public func deploy(id: String) {
        guard let profile = profile(id: id) else {
            messages[id] = RemoteSSHError.profileNotFound.localizedDescription
            return
        }
        statuses[id] = .deploying
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let updated = try self.profileWithNonce(profile)
                let command = try self.deploymentCommand(for: updated)
                _ = try await self.runSSH(profile: updated, remoteCommand: command)
                var saved = updated
                saved.deployedAt = .now
                try self.update(saved)
                self.statuses[id] = .idle
                self.messages[id] = "Remote Claude/Codex/Copilot hooks deployed."
            } catch {
                self.statuses[id] = .failed
                self.messages[id] = error.localizedDescription
            }
        }
    }

    public func connect(id: String) {
        guard let profile = profile(id: id) else {
            messages[id] = RemoteSSHError.profileNotFound.localizedDescription
            return
        }
        guard profile.deployedAt != nil, profile.routingNonce != nil else {
            statuses[id] = .failed
            messages[id] = RemoteSSHError.deploymentRequired.localizedDescription
            return
        }
        guard tunnels[id] == nil, !pendingConnections.contains(id) else { return }
        do {
            try validate(profile)
            guard let nonce = profile.routingNonce else { throw RemoteSSHError.deploymentRequired }
            eventServer.registerRemoteNonce(nonce)
            pendingConnections.insert(id)
            statuses[id] = .connecting
            messages[id] = "Preparing profile-bound SSH ingress."
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let ingressPort = try await self.remoteIngressPort(for: nonce)
                    guard self.pendingConnections.remove(id) != nil,
                          let current = self.profile(id: id),
                          current.routingNonce == nonce,
                          current.deployedAt != nil else {
                        self.eventServer.stopRemoteIngress(nonce: nonce)
                        return
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = self.sshArguments(for: current, tunnel: true, localIngressPort: ingressPort)
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.terminationHandler = { [weak self] process in
                        Task { @MainActor [weak self] in
                            guard let self, self.tunnels[id] === process else { return }
                            self.tunnels.removeValue(forKey: id)
                            self.fallbackMonitors.removeValue(forKey: id)?.terminate()
                            self.eventServer.stopRemoteIngress(nonce: nonce)
                            if self.statuses[id] == .connected || self.statuses[id] == .connecting {
                                self.statuses[id] = .failed
                                self.messages[id] = "SSH tunnel exited with status \(process.terminationStatus)."
                            }
                        }
                    }
                    try process.run()
                    self.tunnels[id] = process
                    if current.autoStartCodexFallback {
                        self.startFallbackMonitor(for: current)
                    }
                    self.statuses[id] = .connecting
                    self.messages[id] = "SSH reverse tunnel starting."
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.tunnels[id] === process, process.isRunning else { return }
                        self.statuses[id] = .connected
                        self.messages[id] = "Remote hooks can now reach Clawdesk."
                    }
                } catch {
                    self.pendingConnections.remove(id)
                    self.eventServer.stopRemoteIngress(nonce: nonce)
                    self.statuses[id] = .failed
                    self.messages[id] = error.localizedDescription
                }
            }
        } catch {
            statuses[id] = .failed
            messages[id] = error.localizedDescription
        }
    }

    public func disconnect(id: String) {
        pendingConnections.remove(id)
        fallbackMonitors.removeValue(forKey: id)?.terminate()
        if let nonce = profile(id: id)?.routingNonce {
            eventServer.stopRemoteIngress(nonce: nonce)
        }
        guard let process = tunnels.removeValue(forKey: id) else {
            if statuses[id] == .connected || statuses[id] == .connecting { statuses[id] = .idle }
            return
        }
        process.terminationHandler = nil
        process.terminate()
        statuses[id] = .idle
        messages[id] = "SSH tunnel disconnected."
    }

    public func stop() {
        for id in Set(tunnels.keys).union(pendingConnections) { disconnect(id: id) }
        for process in fallbackMonitors.values { process.terminate() }
        fallbackMonitors.removeAll()
        for profile in profiles {
            if let nonce = profile.routingNonce { eventServer.stopRemoteIngress(nonce: nonce) }
        }
    }

    public func authenticate(id: String) {
        guard let profile = profile(id: id) else { return }
        var arguments = sshArguments(for: profile, tunnel: false, batchMode: false)
        if let commandIndex = arguments.firstIndex(of: "--") { arguments.removeSubrange(commandIndex...) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", "--args", "ssh"] + arguments
        try? process.run()
        messages[id] = "Opened Terminal for SSH authentication."
    }

    public func profile(id: String) -> RemoteSSHProfile? {
        profiles.first(where: { $0.id == id })
    }

    private func remoteIngressPort(for nonce: String) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            eventServer.startRemoteIngress(nonce: nonce) { result in
                switch result {
                case let .success(port): continuation.resume(returning: port)
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func profileWithNonce(_ profile: RemoteSSHProfile) throws -> RemoteSSHProfile {
        if let nonce = profile.routingNonce, Self.isValidNonce(nonce) { return profile }
        var updated = profile
        updated.routingNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        eventServer.registerRemoteNonce(updated.routingNonce ?? "")
        try update(updated)
        return updated
    }

    private func deploymentCommand(for profile: RemoteSSHProfile) throws -> String {
        guard profile.routingNonce != nil else { throw RemoteSSHError.invalidProfile }
        let hookPath = "$HOME/.clawdesk/hooks/clawdesk-\(profile.id).sh"
        let installerPath = "$HOME/.clawdesk/hooks/clawdesk-\(profile.id).installer.js"
        let monitorPath = "$HOME/.clawdesk/hooks/codex-remote-monitor-\(profile.id).js"
        let hook = remoteHookScript(profile: profile, hookPath: hookPath)
        let installer = remoteJSONInstaller(profile: profile)
        let monitor = remoteCodexMonitor(profile: profile, hookPath: hookPath)
        let hook64 = Data(hook.utf8).base64EncodedString()
        let installer64 = Data(installer.utf8).base64EncodedString()
        let monitor64 = Data(monitor.utf8).base64EncodedString()
        let decodeNode = "node -e 'const fs=require(\"fs\");const chunks=[];process.stdin.on(\"data\",chunk=>chunks.push(chunk));process.stdin.on(\"end\",()=>fs.writeFileSync(process.argv[1],Buffer.from(Buffer.concat(chunks).toString(),\"base64\")));'"
        return "mkdir -p \"$HOME/.clawdesk/hooks\" \"$HOME/.claude\" \"$HOME/.codex\" && printf '%s' '\(hook64)' | \(decodeNode) \"\(hookPath)\" && chmod 700 \"\(hookPath)\" && printf '%s' '\(monitor64)' | \(decodeNode) \"\(monitorPath)\" && chmod 700 \"\(monitorPath)\" && printf '%s' '\(installer64)' | \(decodeNode) \"\(installerPath)\" && node \"\(installerPath)\"; status=$?; rm -f \"\(installerPath)\"; exit $status"
    }

    /// Keeps the generated remote command testable without making it part of
    /// the app's public deployment API.
    internal func deploymentCommandForTesting(_ profile: RemoteSSHProfile) throws -> String {
        try validate(profile)
        return try deploymentCommand(for: profile)
    }

    internal func remoteInstallerForTesting(_ profile: RemoteSSHProfile) throws -> String {
        try validate(profile)
        return remoteJSONInstaller(profile: profile)
    }

    internal func remoteMonitorForTesting(_ profile: RemoteSSHProfile) throws -> String {
        try validate(profile)
        return remoteCodexMonitor(profile: profile, hookPath: "$HOME/.clawdesk/hooks/clawdesk-\(profile.id).sh")
    }

    private func remoteHookScript(profile: RemoteSSHProfile, hookPath: String) -> String {
        let port = profile.remoteForwardPort
        let nonce = profile.routingNonce ?? ""
        let prefix = profile.hostPrefix ?? profile.label
        let escapedPrefix = String(prefix.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" ? Character(scalar) : Character("-")
        })
        return """
        #!/bin/sh
        # clawdesk-remote-v1 — installed by Clawdesk Remote SSH.
        EVENT="${1:-Notification}"
        ROUTE="state"
        case "$(printf '%s' "$EVENT" | tr '[:upper:]' '[:lower:]')" in
          *permission*) ROUTE="permission" ;;
        esac
        AGENT="${2:-custom}"
        URL="http://127.0.0.1:\(port)/${ROUTE}?event=${EVENT}&agent=${AGENT}&remote_prefix=\(escapedPrefix)&clawdesk-hook-v1=1&clawdesk-remote-v1=1&clawdesk-remote-nonce=\(nonce)"
        BODY=$(cat)
        [ -z "$BODY" ] && BODY='{}'
        if [ "$ROUTE" = "permission" ]; then
          printf '%s' "$BODY" | curl --silent --show-error --max-time 540 --connect-timeout 2 \
            -H 'Content-Type: application/json' --data-binary @- "$URL" 2>/dev/null || \
            printf '%s' '{"behavior":"ask","approved":false}'
        else
          printf '%s' "$BODY" | curl --silent --max-time 5 --connect-timeout 2 \
            -H 'Content-Type: application/json' --data-binary @- "$URL" >/dev/null 2>&1 || true
        fi
        """
    }

    private func remoteJSONInstaller(profile: RemoteSSHProfile) -> String {
        let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "Notification", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
        let eventJSON = (try? JSONSerialization.data(withJSONObject: events))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let permissionURL = "http://127.0.0.1:\(profile.remoteForwardPort)/permission?event=PermissionRequest&agent=claude-code&clawdesk-hook-v1=1&clawdesk-remote-v1=1&clawdesk-remote-nonce=\(profile.routingNonce ?? "")"
        return """
        const fs = require('fs');
        const path = require('path');
        const home = process.env.HOME || process.cwd();
        const command = path.join(home, '.clawdesk', 'hooks', 'clawdesk-\(profile.id).sh');
        const permissionURL = \(jsonString(permissionURL));
        const events = \(eventJSON);
        function read(file) {
          try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) {
            if (error.code === 'ENOENT') return {};
            throw new Error('Clawdesk could not parse ' + file);
          }
        }
        function write(file, object) {
          if (fs.existsSync(file)) {
            const backup = file + '.clawdesk-backup.json';
            if (!fs.existsSync(backup)) fs.copyFileSync(file, backup);
          }
          const temporary = file + '.clawdesk-tmp';
          fs.writeFileSync(temporary, JSON.stringify(object, null, 2) + '\\n', { mode: 0o600 });
          fs.renameSync(temporary, file);
        }
        function managed(value) {
          const text = JSON.stringify(value);
          return text.includes('clawdesk-remote-v1') || text.includes(command);
        }
        function desiredCommandEntry(name, agent) {
          return { matcher: '', hooks: [{ type: 'command', command: command + ' ' + name + ' ' + agent, timeout: 540 }] };
        }
        function merge(file, names, agent) {
          const object = read(file);
          object.hooks = object.hooks && typeof object.hooks === 'object' ? object.hooks : {};
          for (const name of names) {
            const current = Array.isArray(object.hooks[name]) ? object.hooks[name] : [];
            const indexes = current.map((entry, index) => managed(entry) ? index : -1).filter((index) => index >= 0);
            const desired = desiredCommandEntry(name, agent);
            if (indexes.length === 0) {
              object.hooks[name] = current.concat([desired]);
            } else {
              object.hooks[name] = current
                .map((entry, index) => index === indexes[0] ? desired : entry)
                .filter((entry, index) => !indexes.slice(1).includes(index));
            }
          }
          write(file, object);
        }
        function mergePermission(file) {
          const object = read(file);
          object.hooks = object.hooks && typeof object.hooks === 'object' ? object.hooks : {};
          const current = Array.isArray(object.hooks.PermissionRequest) ? object.hooks.PermissionRequest : [];
          const indexes = current.map((entry, index) => managed(entry) ? index : -1).filter((index) => index >= 0);
          const desired = { matcher: '', hooks: [{ type: 'http', url: permissionURL, timeout: 600 }] };
          if (indexes.length === 0) {
            object.hooks.PermissionRequest = current.concat([desired]);
          } else {
            object.hooks.PermissionRequest = current
              .map((entry, index) => index === indexes[0] ? desired : entry)
              .filter((entry, index) => !indexes.slice(1).includes(index));
          }
          write(file, object);
        }
        function mergeCopilot(file, names) {
          if (!fs.existsSync(path.dirname(path.dirname(file)))) return;
          const object = read(file);
          object.hooks = object.hooks && typeof object.hooks === 'object' ? object.hooks : {};
          for (const name of names) {
            const current = Array.isArray(object.hooks[name]) ? object.hooks[name] : [];
            const indexes = current.map((entry, index) => managed(entry) ? index : -1).filter((index) => index >= 0);
            const commandLine = command + ' ' + name + ' copilot-cli';
            const desired = { type: 'command', bash: commandLine, powershell: '& ' + commandLine, timeoutSec: name.toLowerCase().includes('permission') ? 600 : 5 };
            if (indexes.length === 0) object.hooks[name] = current.concat([desired]);
            else object.hooks[name] = current.map((entry, index) => index === indexes[0] ? desired : entry).filter((entry, index) => !indexes.slice(1).includes(index));
          }
          write(file, object);
        }
        merge(path.join(home, '.claude', 'settings.json'), events, 'claude-code');
        mergePermission(path.join(home, '.claude', 'settings.json'));
        merge(path.join(home, '.codex', 'hooks.json'), ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Stop'], 'codex');
        const copilotHome = process.env.COPILOT_HOME || path.join(home, '.copilot');
        if (fs.existsSync(copilotHome)) {
          mergeCopilot(path.join(copilotHome, 'hooks', 'hooks.json'), ['sessionStart', 'userPromptSubmitted', 'preToolUse', 'postToolUse', 'sessionEnd', 'errorOccurred', 'agentStop', 'subagentStart', 'subagentStop', 'preCompact', 'permissionRequest']);
        }
        """
    }

    private func remoteCodexMonitor(profile: RemoteSSHProfile, hookPath: String) -> String {
        let safeID = profile.id
        _ = hookPath
        return """
        const fs = require('fs');
        const path = require('path');
        const childProcess = require('child_process');
        const home = process.env.HOME || process.cwd();
        const sessions = path.join(home, '.codex', 'sessions');
        const hook = path.join(home, '.clawdesk', 'hooks', 'clawdesk-\(safeID).sh');
        const offsets = new Map();
        const cutoff = Date.now() - 24 * 60 * 60 * 1000;
        function value(object, payload, keys) {
          for (const key of keys) {
            if (typeof object[key] === 'string' && object[key]) return object[key];
            if (typeof payload[key] === 'string' && payload[key]) return payload[key];
          }
          return undefined;
        }
        function number(object, payload, keys) {
          for (const key of keys) {
            const candidate = object[key] ?? payload[key];
            if (Number.isFinite(Number(candidate))) return Number(candidate);
          }
          return undefined;
        }
        function emit(event, safe) {
          const request = childProcess.spawn(hook, [event, 'codex'], { stdio: ['pipe', 'ignore', 'ignore'] });
          request.stdin.end(JSON.stringify(safe));
        }
        function scan(file) {
          let text;
          try { text = fs.readFileSync(file, 'utf8'); } catch (_) { return; }
          const previous = offsets.get(file) || 0;
          const start = previous > text.length ? 0 : previous;
          offsets.set(file, text.length);
          for (const line of text.slice(start).split(/\\r?\\n/)) {
            if (!line.trim()) continue;
            let object;
            try { object = JSON.parse(line); } catch (_) { continue; }
            const payload = object.payload && typeof object.payload === 'object' ? object.payload : (object.data || {});
            const type = String(object.type || '').toLowerCase();
            const subtype = String(payload.type || payload.subtype || '').toLowerCase();
            const functionName = String(payload.name || payload.tool_name || '').toLowerCase();
            let event = null;
            if (type === 'session_meta' || subtype === 'session_meta' || subtype === 'session_start') event = 'SessionStart';
            else if (subtype === 'task_started' || subtype === 'user_message') event = 'UserPromptSubmit';
            else if (type === 'response_item' && subtype === 'function_call' && functionName === 'request_user_input') event = 'RequestUserInput';
            else if (type === 'response_item' && ['function_call', 'custom_tool_call', 'web_search_call'].includes(subtype)) event = 'PreToolUse';
            else if (type === 'response_item' && ['function_call_output', 'custom_tool_call_output'].includes(subtype)) event = 'PostToolUse';
            else if (subtype === 'task_complete') event = 'Stop';
            else if (subtype === 'context_compacted') event = 'PreCompact';
            if (!event) continue;
            const safe = {
              session_id: value(object, payload, ['session_id', 'sessionId', 'conversation_id', 'id']) || path.basename(file, '.jsonl'),
              cwd: value(object, payload, ['cwd', 'working_directory', 'directory']) || '',
              title: value(object, payload, ['title', 'task', 'summary']) || '',
              subagent_count: number(object, payload, ['subagent_count', 'subagentCount', 'subagents']) || 0,
              timestamp: object.timestamp || payload.timestamp || Date.now()
            };
            if (payload.call_id || payload.callId || payload.tool_call_id || payload.toolCallId) {
              safe.call_id = payload.call_id || payload.callId || payload.tool_call_id || payload.toolCallId;
            }
            if (event === 'RequestUserInput') {
              let argumentsObject = payload.arguments;
              if (typeof argumentsObject === 'string') {
                try { argumentsObject = JSON.parse(argumentsObject); } catch (_) { argumentsObject = null; }
              }
              if (argumentsObject && Array.isArray(argumentsObject.questions)) {
                safe.questions = argumentsObject.questions.slice(0, 4).map((question) => ({
                  id: question.id,
                  header: question.header,
                  question: question.question,
                  options: Array.isArray(question.options) ? question.options.slice(0, 6) : []
                }));
              }
            }
            const limits = object.rate_limits || payload.rate_limits || (payload.info && payload.info.rate_limits);
            if (limits && typeof limits === 'object') safe.rate_limits = limits;
            emit(event, safe);
          }
        }
        function tick() {
          let files;
          try { files = fs.readdirSync(sessions); } catch (_) { return; }
          for (const name of files) {
            if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;
            const file = path.join(sessions, name);
            try { if (fs.statSync(file).mtimeMs >= cutoff) scan(file); } catch (_) {}
          }
        }
        tick();
        setInterval(tick, 1500);
        """
    }

    private func startFallbackMonitor(for profile: RemoteSSHProfile) {
        guard fallbackMonitors[profile.id] == nil else { return }
        let command = "node \"$HOME/.clawdesk/hooks/codex-remote-monitor-\(profile.id).js\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(for: profile, tunnel: false) + [command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.fallbackMonitors[profile.id] === process else { return }
                self.fallbackMonitors.removeValue(forKey: profile.id)
            }
        }
        do {
            try process.run()
            fallbackMonitors[profile.id] = process
        } catch {
            messages[profile.id] = "Fallback monitor could not start: \(error.localizedDescription)"
        }
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }

    private func runSSH(profile: RemoteSSHProfile, remoteCommand: String) async throws -> String {
        let arguments = sshArguments(for: profile, tunnel: false) + [remoteCommand]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = arguments
                let output = Pipe()
                let error = Pipe()
                process.standardOutput = output
                process.standardError = error
                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    guard process.terminationStatus == 0 else {
                        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: RemoteSSHError.commandFailed(
                            detail.isEmpty ? "Remote SSH command failed with status \(process.terminationStatus)." : detail
                        ))
                        return
                    }
                    continuation.resume(returning: stdout)
                } catch {
                    continuation.resume(throwing: RemoteSSHError.commandFailed(error.localizedDescription))
                }
            }
        }
    }

    private func sshArguments(
        for profile: RemoteSSHProfile,
        tunnel: Bool,
        batchMode: Bool = true,
        localIngressPort: UInt16? = nil
    ) -> [String] {
        var arguments = ["-o", "BatchMode=\(batchMode ? "yes" : "no")", "-o", "ConnectTimeout=10", "-o", "ExitOnForwardFailure=yes", "-p", String(profile.port)]
        if resolvedTransportMode(for: profile) == .singleSession {
            // Some ProxyCommand transports (notably Codespaces-compatible
            // stdio bridges) reject overlapping SSH children. Disabling
            // multiplexing keeps this profile on one predictable transport
            // path; deployment and fallback maintenance remain explicit.
            arguments += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        }
        if let identity = profile.identityFile, !identity.isEmpty {
            arguments += ["-i", identity]
        }
        if tunnel {
            let targetPort = localIngressPort ?? eventServer.port
            arguments += ["-N", "-T", "-R", "127.0.0.1:\(profile.remoteForwardPort):127.0.0.1:\(targetPort)"]
        }
        arguments.append(profile.host)
        return arguments
    }

    private func validate(_ profile: RemoteSSHProfile) throws {
        guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isSafeIdentifier(profile.id),
              profile.routingNonce == nil || Self.isValidNonce(profile.routingNonce ?? ""),
              (1...65_535).contains(profile.port),
              (1_024...65_535).contains(profile.remoteForwardPort) else {
            throw RemoteSSHError.invalidProfile
        }
    }

    private func resolvedTransportMode(for profile: RemoteSSHProfile) -> RemoteSSHTransportMode {
        if profile.transportMode == .singleSession { return .singleSession }
        // `ssh -G` expands the effective ProxyCommand without opening a
        // socket. GitHub Codespaces' stdio transport cannot tolerate the
        // overlapping SSH children used by normal profiles, so Automatic
        // opts into the same conservative options as the explicit mode.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-G", "-o", "BatchMode=yes", "-p", String(profile.port)]
        if let identity = profile.identityFile, !identity.isEmpty { arguments += ["-i", identity] }
        arguments.append(profile.host)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .automatic }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
            if text.contains("proxycommand") && (text.contains("gh cs ssh") || text.contains("gh codespace ssh")) {
                return .singleSession
            }
        } catch {
            return .automatic
        }
        return .automatic
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func isValidNonce(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private func persist() throws {
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: configurationURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }

}
