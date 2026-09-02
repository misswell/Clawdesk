import Foundation

/// Low-frequency fallback for Codex builds that do not emit all official hook
/// events. It tails only recently modified rollout JSONL files and emits the
/// same normalized events as the hook transport; no transcript or tool input
/// is retained.
@MainActor
public final class CodexLogMonitor {
    public typealias EventHandler = (AgentEvent) -> Void

    public let sessionsDirectory: URL
    public var onEvent: EventHandler?
    public var onQuota: ((QuotaReport) -> Void)?

    private let fileManager: FileManager
    private var offsets: [URL: UInt64] = [:]
    private var partialLines: [URL: Data] = [:]
    /// Desktop response items do not repeat `session_id`; their `id` is an
    /// item/tool ID. Cache the session identity from the first session_meta
    /// record so every later rollout event stays in the same HUD session.
    private var sessionIDs: [URL: String] = [:]
    private var task: Task<Void, Never>?
    private static let maxTrackedFiles = 128
    private static let maxReadBytesPerScan = 256 * 1024
    private static let maxSessionMetaBytes = 256 * 1024
    private static let maxInitialBackfillBytes: UInt64 = 1024 * 1024
    private static let maxPartialLineBytes = 512 * 1024
    private static let activeRolloutAge: TimeInterval = 24 * 60 * 60

    var trackedFileCount: Int { offsets.count }
    var bufferedPartialByteCount: Int { partialLines.values.reduce(0) { $0 + $1.count } }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        codexHomeDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let codexHome = codexHomeDirectory
            ?? Self.resolveCodexHomeDirectory(homeDirectory: homeDirectory, environment: environment)
        sessionsDirectory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    public func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.scanOnce()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func scanOnce() {
        let candidates = rolloutCandidates()
        .sorted { $0.1 > $1.1 }
        .prefix(Self.maxTrackedFiles)
        let activeFiles = Set(candidates.map { $0.0 })
        for (file, _, size) in candidates {
            readNewLines(from: file, size: size)
        }
        offsets = offsets.filter { activeFiles.contains($0.key) }
        partialLines = partialLines.filter { activeFiles.contains($0.key) }
        sessionIDs = sessionIDs.filter { activeFiles.contains($0.key) }
    }

    /// Codex stores rollouts in `sessions/YYYY/MM/DD`, while older builds and
    /// test fixtures may place them directly under `sessions`. Enumerating the
    /// tree keeps both layouts working and, importantly, also finds a
    /// long-lived Desktop conversation that continues writing to its original
    /// date directory.
    private func rolloutCandidates() -> [(URL, Date, UInt64)] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let cutoff = Date.now.addingTimeInterval(-Self.activeRolloutAge)
        var candidates: [(URL, Date, UInt64)] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl", file.lastPathComponent.hasPrefix("rollout-") else { continue }
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            ), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff else { continue }
            candidates.append((file, modified, UInt64(values.fileSize ?? 0)))
        }
        return candidates
    }

    private func readNewLines(from file: URL, size: UInt64) {
        let previous = offsets[file]
        let start: UInt64
        if let previous {
            if previous > size {
                // The path was truncated or replaced. Its cached header may
                // belong to the previous rollout, so force a fresh read.
                sessionIDs.removeValue(forKey: file)
            }
            start = previous > size ? 0 : previous
        } else {
            start = size > Self.maxInitialBackfillBytes ? size - Self.maxInitialBackfillBytes : 0
        }
        if start == 0 {
            partialLines.removeValue(forKey: file)
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Self.maxReadBytesPerScan) ?? Data()
            offsets[file] = start + UInt64(data.count)
            var buffer = partialLines[file] ?? Data()
            buffer.append(data)
            guard !buffer.isEmpty else { return }

            let chunks = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
            let hasCompleteFinalChunk = buffer.last == 0x0A
            let completeChunks = hasCompleteFinalChunk ? chunks : chunks.dropLast()
            for chunk in completeChunks where !chunk.isEmpty && chunk.count <= Self.maxPartialLineBytes {
                guard let object = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any],
                      let event = makeEvent(from: object, file: file) else { continue }
                onEvent?(event)
            }

            if hasCompleteFinalChunk {
                partialLines.removeValue(forKey: file)
            } else if let last = chunks.last, !last.isEmpty, last.count <= Self.maxPartialLineBytes {
                partialLines[file] = Data(last)
            } else {
                partialLines.removeValue(forKey: file)
            }
        } catch {
            // Rollout files are append-only and may be mid-write. The next
            // scan retries from the last complete byte range. The partial
            // line buffer above prevents an in-progress final JSON object
            // from being skipped when the writer flushes it in two chunks.
        }
    }

    private func makeEvent(from object: [String: Any], file: URL) -> AgentEvent? {
        let payload = object["payload"] as? [String: Any] ?? object["data"] as? [String: Any] ?? [:]
        let type = string(from: object, payload: payload, keys: ["type", "event", "name"]) ?? ""
        let subtype = string(from: payload, payload: object, keys: ["type", "subtype", "event"]) ?? ""
        let key = subtype.isEmpty ? type.lowercased() : "\(type.lowercased()):\(subtype.lowercased())"
        if let rateLimits = rateLimits(from: object, payload: payload) {
            let capturedAt = date(from: object["timestamp"] ?? payload["timestamp"]) ?? .now
            let model = string(from: object, payload: payload, keys: ["model", "model_name"])
                ?? ((payload["turn_context"] as? [String: Any])?["model"] as? String)
            if let report = QuotaReportParser.codex(
                rateLimits: rateLimits,
                capturedAt: capturedAt,
                now: .now,
                providerHint: model?.lowercased() == "gpt-5.3-codex-spark" ? "codex-spark" : nil
            ) {
                onQuota?(report)
            }
        }
        let explicitSessionID = explicitSessionID(from: object, payload: payload)
        if let explicitSessionID, sessionIDs[file] == nil {
            // Fixtures and older rollout formats may omit session_meta but
            // carry the session ID on their first lifecycle record.
            sessionIDs[file] = explicitSessionID
        }
        let sessionID = explicitSessionID ?? sessionID(for: file)
        if let userInput = parseUserInputRecord(object: object, payload: payload) {
            switch userInput.phase {
            case .request:
                guard let questions = userInput.questions, !questions.isEmpty else { return nil }
                return AgentEvent(
                    sessionID: sessionID,
                    agentID: "codex",
                    eventName: "RequestUserInput",
                    title: "Codex question",
                    folder: string(from: object, payload: payload, keys: ["cwd", "working_directory", "directory"]),
                    question: QuestionPrompt(
                        id: userInput.callID,
                        sessionID: sessionID,
                        agentID: "codex",
                        title: "Codex question",
                        questions: questions
                    ),
                    toolCallID: userInput.callID
                )
            case .resolved:
                return AgentEvent(
                    sessionID: sessionID,
                    agentID: "codex",
                    eventName: "PostToolUse",
                    toolCallID: userInput.callID,
                    questionResolution: true,
                    payload: ["question_call_id": userInput.callID]
                )
            }
        }
        let eventName: String
        switch key {
        case "session_meta", "session_meta:session_meta", "session_start": eventName = "SessionStart"
        case "event_msg:task_started", "event_msg:user_message", "event_msg:guardian_assessment": eventName = "UserPromptSubmit"
        case "response_item:function_call", "response_item:custom_tool_call", "response_item:web_search_call",
             "event_msg:exec_command_end", "event_msg:patch_apply_end", "event_msg:custom_tool_call_output": eventName = "PreToolUse"
        case "event_msg:task_complete": eventName = "Stop"
        case "event_msg:context_compacted": eventName = "PreCompact"
        case "event_msg:turn_aborted": eventName = "Idle"
        default: return nil
        }

        let cwd = string(from: object, payload: payload, keys: ["cwd", "working_directory", "directory"])
        let title = string(from: object, payload: payload, keys: ["title", "task", "summary"])
        let count = int(from: object, payload: payload, keys: ["subagent_count", "subagentCount", "subagents"]) ?? 0
        return AgentEvent(
            sessionID: sessionID,
            agentID: "codex",
            eventName: eventName,
            title: title,
            folder: cwd,
            subagentCount: count
        )
    }

    private enum UserInputPhase {
        case request
        case resolved
    }

    private struct UserInputRecord {
        let phase: UserInputPhase
        let callID: String
        let questions: [QuestionItem]?
    }

    private func parseUserInputRecord(object: [String: Any], payload: [String: Any]) -> UserInputRecord? {
        let payloadType = string(from: payload, payload: object, keys: ["type", "subtype", "event"])?.lowercased() ?? ""
        if payloadType == "function_call_output" || payloadType == "custom_tool_call_output" {
            guard let callID = string(from: payload, payload: object, keys: ["call_id", "callId", "tool_call_id", "toolCallId"]) else { return nil }
            return UserInputRecord(phase: .resolved, callID: String(callID.prefix(120)), questions: nil)
        }
        guard payloadType == "function_call" || payloadType == "custom_tool_call" else { return nil }
        guard string(from: payload, payload: object, keys: ["name", "tool_name", "toolName"])?.lowercased() == "request_user_input" else { return nil }
        guard let callID = string(from: payload, payload: object, keys: ["call_id", "callId", "tool_call_id", "toolCallId"]) else { return nil }
        let rawArguments: Any? = payload["arguments"] ?? payload["input"] ?? payload["args"]
        var arguments: [String: Any] = [:]
        if let rawArguments = rawArguments as? [String: Any] {
            arguments = rawArguments
        } else if let rawArguments = rawArguments as? String,
                  let data = rawArguments.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = decoded
        }
        let rawQuestions = arguments["questions"] as? [[String: Any]] ?? []
        let questions: [QuestionItem] = rawQuestions.prefix(4).compactMap { raw in
            guard let question = string(from: raw, payload: [:], keys: ["question", "prompt", "text"]), !question.isEmpty else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).prefix(6).compactMap { option -> QuestionOption? in
                guard let label = string(from: option, payload: [:], keys: ["label", "title"]), !label.isEmpty else { return nil }
                return QuestionOption(
                    id: string(from: option, payload: [:], keys: ["id"]) ?? UUID().uuidString,
                    label: String(label.prefix(160)),
                    description: string(from: option, payload: [:], keys: ["description"]).map { String($0.prefix(240)) },
                    isOther: bool(from: option["isOther"] ?? option["is_other"]),
                    isSecret: bool(from: option["isSecret"] ?? option["is_secret"])
                )
            }
            return QuestionItem(
                id: string(from: raw, payload: [:], keys: ["id"]) ?? UUID().uuidString,
                header: string(from: raw, payload: [:], keys: ["header"]).map { String($0.prefix(80)) },
                question: String(question.prefix(500)),
                options: options
            )
        }
        return UserInputRecord(phase: .request, callID: String(callID.prefix(120)), questions: questions)
    }

    private func bool(from value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        return false
    }

    private func string(from object: [String: Any], payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func int(from object: [String: Any], payload: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = payload[key] as? Int { return value }
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = payload[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    private func rateLimits(from object: [String: Any], payload: [String: Any]) -> [String: Any]? {
        if let direct = object["rate_limits"] as? [String: Any] { return direct }
        if let direct = payload["rate_limits"] as? [String: Any] { return direct }
        if let info = payload["info"] as? [String: Any],
           let nested = info["rate_limits"] as? [String: Any] { return nested }
        return nil
    }

    private func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }

    private func explicitSessionID(from object: [String: Any], payload: [String: Any]) -> String? {
        if let value = string(
            from: object,
            payload: payload,
            keys: ["session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId"]
        ) {
            return value
        }

        // `id` is an item/tool ID on response_item records. It is only a
        // session identity on the session_meta record itself.
        let recordType = (object["type"] as? String)?.lowercased()
        guard recordType == "session_meta" else { return nil }
        return string(from: object, payload: payload, keys: ["id"])
    }

    private func sessionID(for file: URL) -> String {
        if let cached = sessionIDs[file] { return cached }
        if let headerID = sessionIDFromHeader(for: file) {
            sessionIDs[file] = headerID
            return headerID
        }
        return fallbackSessionID(for: file)
    }

    private func sessionIDFromHeader(for file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxSessionMetaBytes), !data.isEmpty else { return nil }
        let line = data.firstIndex(of: 0x0A).map { data.prefix(upTo: $0) } ?? data
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              (object["type"] as? String)?.lowercased() == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return explicitSessionID(from: object, payload: payload)
    }

    /// A large Codex Desktop rollout is initially tailed from its last MiB,
    /// so the `session_meta` record at the head may not be in that read. The
    /// UUID suffix in the rollout filename is the same session identity and
    /// keeps tail events attached to the official-hook session.
    private func fallbackSessionID(for file: URL) -> String {
        let base = file.deletingPathExtension().lastPathComponent
        // Forked Desktop rollouts can contain two UUIDs separated by `_`.
        // The final UUID is the rollout identity used by Codex's file naming.
        let suffix = base.split(separator: "_").last.map(String.init) ?? base
        let parts = suffix.split(separator: "-")
        guard parts.count >= 5 else { return base }
        let candidate = parts.suffix(5).joined(separator: "-")
        let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        return candidate.range(of: uuidPattern, options: .regularExpression) != nil ? candidate : base
    }

    private static func resolveCodexHomeDirectory(
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL {
        guard let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(expanded, isDirectory: true)
    }
}
