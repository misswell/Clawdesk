import Foundation

public enum EventStateMapper {
    /// Hook providers use a mixture of camelCase, snake_case, kebab-case and
    /// namespaced values such as `event_msg:task_complete`. Keep one
    /// normalization rule at the domain seam so every alias follows the same
    /// lifecycle path.
    static func normalizedEventName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func workingState(for event: AgentEvent, liveSessionCount: Int) -> PetState {
        if event.subagentCount >= 1 { return .juggling }
        if liveSessionCount >= 3 { return .building }
        if liveSessionCount >= 2 { return .juggling }
        return .typing
    }

    public static func preservesVisibleState(for event: AgentEvent) -> Bool {
        let agent = event.agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = normalizedEventName(event.eventName)
        // Gemini calls this PreCompress, but its documented behavior is to
        // record the compaction in session history without changing the
        // current animation. Claude/Codex PreCompact still sweep normally.
        return agent.contains("gemini") && name == "precompress"
    }

    public static func state(for event: AgentEvent, liveSessionCount: Int) -> PetState {
        let name = normalizedEventName(event.eventName)

        // The shared hook transport sends `state: "working"` as a typed
        // `.typing` hint. That hint must not short-circuit the same live
        // session/subagent tiering used by a plain PreToolUse event.
        if let stateHint = event.stateHint, stateHint != .typing {
            return stateHint
        }
        if event.stateHint == .typing {
            return workingState(for: event, liveSessionCount: liveSessionCount)
        }

        switch name {
        case "sessionstart", "sessionstarted", "startup", "agentspawn", "idle", "ready":
            return .idle
        case "userpromptsubmit", "prompt", "promptsubmitted", "turnstart", "agentstart",
             "beforeagent", "beforeagentstart", "preinvocation", "afteragentthought":
            return .thinking
        case "pretooluse", "posttooluse", "toolstart", "toolend", "working", "message",
             "beforetool", "aftertool", "postinvocation", "permissionresult":
            return workingState(for: event, liveSessionCount: liveSessionCount)
        case "subagentstart", "subagentstarted", "juggling":
            return .juggling
        case "subagentstop", "subagentstopped", "subagentend", "subagentended":
            return event.subagentCount > 0 ? .juggling : .typing
        case "posttoolusefailure", "toolerror", "error", "stopfailure", "failed", "apierror", "erroroccurred":
            return .error
        case "postcompact":
            // Automatic compaction is part of the current turn and work
            // resumes immediately afterwards. A manually requested compact is
            // the one case that may intentionally return to idle.
            return event.payload["trigger"]?.lowercased() == "manual" ? .idle : .thinking
        case "stop", "agentstop", "agentend", "taskcomplete", "eventmsgtaskcomplete", "complete", "completed":
            return .attention
        case "permissionrequest", "permission", "notification", "needsattention", "requestuserinput",
             "codexuserinputrequest", "userinputrequest", "elicitation", "permissiondenied":
            return .notification
        case "precompact", "precompress", "compacting", "sweeping":
            return .sweeping
        case "worktreecreate", "carrying", "preparing":
            return .carrying
        case "sessionend", "sessionended", "sessionshutdown", "sessionclosed", "exit", "shutdown", "processexit", "interrupt":
            return .idle
        default:
            // A few integrations add a suffix to the shared lifecycle names
            // (for example `approvalRequired` or `toolError`). Keep those
            // payloads visible without coupling the core mapper to every
            // vendor's spelling.
            if name.contains("permission") || name.contains("approval") || name.contains("elicitation") {
                return .notification
            }
            if name.contains("error") || name.contains("failure") {
                return .error
            }
            return .idle
        }
    }
}

private struct SubagentTracker {
    var confirmedIDs: Set<String> = []
    var anonymousCount = 0
    /// The parent state is captured before the first child starts. It lets a
    /// child stop return a thinking/building parent to its real state instead
    /// of guessing `.typing` from the stop event itself.
    var parentState: PetState?

    var count: Int {
        confirmedIDs.count + max(0, anonymousCount)
    }
}

public final class SessionStore {
    private var sessionsByID: [String: SessionSnapshot] = [:]
    private var subagentTrackersBySessionID: [String: SubagentTracker] = [:]
    /// Sessions whose accepted Claude Stop already played the completion
    /// celebration. A second Stop with no user activity in between is a
    /// duplicate hook delivery, not a new completion, and must not celebrate
    /// (or notify remotely) twice.
    private var celebratedStopSessionIDs: Set<String> = []

    public init() {}

    /// Dashboard/HUD ordering mirrors upstream's session menu comparator:
    /// dominant-state priority first, recency second.
    public var sessions: [SessionSnapshot] {
        sessionsByID.values.sorted { lhs, rhs in
            let left = Self.priority(of: lhs.state)
            let right = Self.priority(of: rhs.state)
            if left == right { return lhs.lastActivity > rhs.lastActivity }
            return left > right
        }
    }

    /// The aggregate visual state over every live session, identical to the
    /// one used for transitions.
    public func currentAggregateState() -> PetState {
        aggregateState()
    }

    public func apply(_ event: AgentEvent, isCompletionReplay: Bool = false) -> StateTransition {
        // Permission and question requests are transient: upstream never lets
        // them create a session row or overwrite a live session's lifecycle
        // state. They surface through the bubble/remote-approval lane and the
        // model's pending-permission overlay instead.
        if isTransientRequestEvent(event.eventName) {
            return StateTransition(
                state: aggregateState(),
                sessions: sessions,
                permission: event.permission
            )
        }

        let existing = sessionsByID[event.sessionID]
        let normalizedSubagentID = normalizeSubagentID(event.subagentID)
        let isSubagentStart = isSubagentStart(event.eventName)
        let isSubagentStop = isSubagentStop(event.eventName)
        let isSessionEnd = isSessionEnd(event.eventName)
        let isScopedSubagentEnd = isSessionEnd && normalizedSubagentID != nil
        let isParentEnd = isSessionEnd && !isScopedSubagentEnd
        let liveCountBefore = sessionsByID.count
        let liveCountAfter = liveCountBefore + (existing == nil ? 1 : 0)

        // Any accepted forward progress re-arms the completion celebration for
        // this session; only a Stop with nothing in between is a duplicate.
        // A Stop itself must not clear the marker it is about to be checked
        // against, which is why Claude Stops are excluded here.
        if !isCompletionReplay, !isClaudeMainStop(event) {
            celebratedStopSessionIDs.remove(event.sessionID)
        }

        var tracker = tracker(for: event.sessionID, existing: existing)
        let hadSubagent = tracker.count > 0

        if isSubagentStart {
            if tracker.count == 0 {
                tracker.parentState = resumableParentState(existing?.state)
                    ?? .typing
            }
            if let normalizedSubagentID {
                // Stable IDs are the authoritative lane. Duplicate start
                // hooks are harmless and cannot inflate the visual count.
                tracker.confirmedIDs.insert(normalizedSubagentID)
            } else if event.subagentCount > 0 {
                // Older adapters only expose a total count. Keep it as an
                // anonymous floor, while retaining one increment for a
                // start event that carries no count at all.
                tracker.anonymousCount = max(
                    tracker.anonymousCount,
                    max(0, event.subagentCount - tracker.confirmedIDs.count)
                )
            } else {
                tracker.anonymousCount += 1
            }
        } else if isSubagentStop || isScopedSubagentEnd {
            if let normalizedSubagentID {
                // An unknown child stop is deliberately a no-op. A delayed
                // or duplicated stop must not hide a still-running child.
                tracker.confirmedIDs.remove(normalizedSubagentID)
            } else if tracker.anonymousCount > 0 {
                tracker.anonymousCount -= 1
            }
        } else if let normalizedSubagentID {
            // Activity carrying a child ID is positive liveness evidence and
            // repairs a prior stop that may have been vetoed by another hook.
            tracker.confirmedIDs.insert(normalizedSubagentID)
        }

        // Claude's background task list is a count-only compatibility lane.
        // It can establish a child floor, but a zero report must not erase
        // confirmed IDs; only the matching child stop or accepted parent Stop
        // can do that.
        if !isSubagentStop && !isScopedSubagentEnd,
           let backgroundSubagents = event.backgroundSubagentCount,
           backgroundSubagents > 0 {
            tracker.anonymousCount = max(
                tracker.anonymousCount,
                max(0, backgroundSubagents - tracker.confirmedIDs.count)
            )
        }

        let hasFinalAssistantText = !(event.assistantLastOutput ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let holdingClaudeStop = isClaudeMainStop(event)
            && ((event.sessionCronsCount ?? 0) > 0
                || event.stopHookActive
                || (((event.backgroundTasksCount ?? 0) > 0
                     || (event.backgroundSubagentCount ?? 0) > 0) && !hasFinalAssistantText))
        let debouncingClaudeStop = isClaudeMainStop(event)
            && !holdingClaudeStop
            && (event.headless
                || (((event.backgroundTasksCount ?? 0) > 0
                     || (event.backgroundSubagentCount ?? 0) > 0) && hasFinalAssistantText))

        var mappingEvent = event
        mappingEvent.subagentCount = tracker.count
        if holdingClaudeStop || debouncingClaudeStop {
            mappingEvent.stateHint = tracker.count > 0 ? .juggling : .typing
        } else if isClaudeMainStop(event) {
            // Claude hook payloads often include `state: working`. The URL's
            // Stop event is authoritative; do not let that visual hint turn a
            // completed turn back into ordinary typing.
            mappingEvent.stateHint = nil
        }

        var mapped: PetState
        if isSubagentStop || isScopedSubagentEnd {
            mapped = tracker.count > 0
                ? .juggling
                : (tracker.parentState ?? resumableParentState(existing?.state) ?? .typing)
        } else if EventStateMapper.preservesVisibleState(for: mappingEvent) {
            mapped = existing?.state ?? .idle
        } else {
            mapped = EventStateMapper.state(for: mappingEvent, liveSessionCount: max(1, liveCountAfter))
        }

        if isParentEnd {
            sessionsByID.removeValue(forKey: event.sessionID)
            subagentTrackersBySessionID.removeValue(forKey: event.sessionID)
            return StateTransition(
                state: aggregateState(),
                sessions: sessions,
                completedSessionID: event.sessionID,
                permission: nil
            )
        }

        // A real parent Stop is the lifecycle boundary that clears all child
        // evidence. Held/debounced Stops stay in the tracker until a later
        // accepted Stop or a concrete child stop arrives.
        var duplicateCompletion = false
        if isClaudeMainStop(event) && !holdingClaudeStop && !debouncingClaudeStop {
            tracker = SubagentTracker()
            // Upstream inspects the completion tail so a duplicated Stop hook
            // delivery never replays the celebration. The first accepted Stop
            // arms the marker; forward progress (handled above) disarms it.
            if celebratedStopSessionIDs.contains(event.sessionID) {
                duplicateCompletion = true
            } else {
                celebratedStopSessionIDs.insert(event.sessionID)
            }
        }

        // While a child is alive, ordinary parent work events cannot downgrade
        // the session from juggling to thinking/typing. Completion, errors
        // and notifications retain their higher-priority visual semantics.
        if tracker.count > 0,
           [PetState.idle, .thinking, .typing, .building, .juggling].contains(mapped),
           !isSubagentStop && !isScopedSubagentEnd {
            mapped = .juggling
        }

        var recent = existing?.recentEvents ?? []
        recent.append(event.eventName)
        if recent.count > 12 { recent.removeFirst(recent.count - 12) }

        let normalizedAgent = event.agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = normalizedAgent == "traecode"
            ? (existing?.title ?? event.title ?? defaultTitle(for: event.agentID))
            : (event.title ?? existing?.title ?? defaultTitle(for: event.agentID))
        let snapshot = SessionSnapshot(
            id: event.sessionID,
            agentID: event.agentID,
            title: title,
            folder: event.folder ?? existing?.folder,
            state: mapped,
            subagentCount: tracker.count,
            lastEvent: event.eventName,
            lastActivity: event.timestamp,
            terminalPID: event.terminalPID ?? existing?.terminalPID,
            recentEvents: recent,
            contextUsage: event.contextUsage ?? existing?.contextUsage,
            headless: event.headless
        )
        sessionsByID[event.sessionID] = snapshot
        if tracker.count > 0 || hadSubagent || isSubagentStart || isSubagentStop || isScopedSubagentEnd {
            subagentTrackersBySessionID[event.sessionID] = tracker
        } else {
            subagentTrackersBySessionID.removeValue(forKey: event.sessionID)
        }

        if isSubagentStop || isScopedSubagentEnd,
           tracker.count == 0,
           tracker.parentState == nil,
           existing == nil {
            subagentTrackersBySessionID.removeValue(forKey: event.sessionID)
        }

        return StateTransition(
            state: aggregateState(),
            sessions: sessions,
            isDuplicateCompletion: duplicateCompletion,
            permission: event.permission
        )
    }

    public func updateSubagentCount(sessionID: String, count: Int) -> StateTransition? {
        guard var session = sessionsByID[sessionID] else { return nil }
        var tracker = tracker(for: sessionID, existing: session)
        let normalizedCount = max(0, count)
        if normalizedCount == 0 {
            tracker = SubagentTracker()
        } else {
            tracker.anonymousCount = max(0, normalizedCount - tracker.confirmedIDs.count)
            tracker.parentState = tracker.parentState ?? resumableParentState(session.state) ?? .typing
            session.state = .juggling
        }
        session.subagentCount = tracker.count
        sessionsByID[sessionID] = session
        subagentTrackersBySessionID[sessionID] = tracker
        return StateTransition(state: aggregateState(), sessions: sessions)
    }

    /// Applies statusline/context telemetry to an existing session without
    /// touching its lifecycle timestamp, recent-event history, or state.
    /// Unknown sessions are ignored so a late statusline cannot resurrect a
    /// completed session as a ghost HUD row.
    public func updateContextUsage(sessionID: String, usage: ContextUsage) -> StateTransition? {
        guard var session = sessionsByID[sessionID] else { return nil }
        guard session.contextUsage != usage else { return nil }
        session.contextUsage = usage
        sessionsByID[sessionID] = session
        return StateTransition(state: aggregateState(), sessions: sessions)
    }

    /// Remove or demote sessions that stopped reporting, mirroring upstream's
    /// stale-cleanup contract:
    /// - idle sessions are deleted after `interval` (upstream 10 minutes);
    /// - silent working-tier sessions are demoted to idle after
    ///   `workingTimeout` (upstream 5 minutes) so a dead CLI cannot leave the
    ///   pet "working" forever — Codex and OpenCode get the longer
    ///   `codexActiveTimeout` floor (upstream 20 minutes, 0 disables);
    /// - sessions pinned to a terminal process that no longer exists are
    ///   deleted immediately.
    public func pruneStale(
        now: Date = .now,
        olderThan interval: TimeInterval = 10 * 60,
        workingTimeout: TimeInterval = 5 * 60,
        codexActiveTimeout: TimeInterval = 20 * 60,
        isProcessAlive: ((Int32) -> Bool)? = nil
    ) -> StateTransition? {
        let activeStates: Set<PetState> = [
            .thinking, .typing, .building, .juggling, .sweeping, .carrying
        ]
        let demotableStates: Set<PetState> = [.thinking, .typing, .building, .juggling]
        var staleIDs: [String] = []
        var demotedIDs: [String] = []
        for (id, session) in sessionsByID {
            if let pid = session.terminalPID, let alive = isProcessAlive,
               pid > 0, !alive(Int32(clamping: pid)) {
                staleIDs.append(id)
                continue
            }
            if activeStates.contains(session.state) {
                guard demotableStates.contains(session.state) else { continue }
                // A model call or a long-running tool can legitimately be
                // silent for a while, so the demotion floor is deliberately
                // longer than any ordinary turn — and never applies to
                // Codex/OpenCode below their own floor (0 disables).
                let floor: TimeInterval
                let normalizedAgent = session.agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalizedAgent.contains("codex") || normalizedAgent.contains("opencode") {
                    guard codexActiveTimeout > 0 else { continue }
                    floor = codexActiveTimeout
                } else {
                    floor = workingTimeout
                }
                if now.timeIntervalSince(session.lastActivity) >= floor {
                    demotedIDs.append(id)
                }
                continue
            }
            let age = now.timeIntervalSince(session.lastActivity)
            if age >= interval { staleIDs.append(id) }
        }
        guard !staleIDs.isEmpty || !demotedIDs.isEmpty else { return nil }
        for id in staleIDs { sessionsByID.removeValue(forKey: id) }
        for id in demotedIDs {
            sessionsByID[id]?.state = .idle
            celebratedStopSessionIDs.remove(id)
        }
        return StateTransition(state: aggregateState(), sessions: sessions)
    }

    public func removeAll() {
        sessionsByID.removeAll()
        subagentTrackersBySessionID.removeAll()
    }

    private func tracker(for sessionID: String, existing: SessionSnapshot?) -> SubagentTracker {
        if let tracker = subagentTrackersBySessionID[sessionID] { return tracker }
        guard let existing, existing.subagentCount > 0 else { return SubagentTracker() }
        return SubagentTracker(anonymousCount: existing.subagentCount)
    }

    private func normalizeSubagentID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256,
              !trimmed.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" }) else {
            return nil
        }
        return trimmed
    }

    private func resumableParentState(_ state: PetState?) -> PetState? {
        guard let state, state != .juggling else { return nil }
        switch state {
        case .thinking, .typing, .building, .sweeping, .carrying:
            return state
        default:
            return nil
        }
    }

    private func aggregateState() -> PetState {
        // Upstream's dominant-state resolver skips headless sessions: their
        // quiet-window completions must not pin the pet's visible state.
        let visible = sessionsByID.values.filter { !$0.headless }
        guard !visible.isEmpty else { return .idle }
        return visible.max { lhs, rhs in
            let left = Self.priority(of: lhs.state)
            let right = Self.priority(of: rhs.state)
            if left == right { return lhs.lastActivity < rhs.lastActivity }
            return left < right
        }?.state ?? .idle
    }

    /// Upstream STATE_PRIORITY, on the native state vocabulary.
    static func priority(of state: PetState) -> Int {
        switch state {
        case .error: return 80
        case .notification: return 70
        case .sweeping: return 60
        case .attention: return 50
        case .carrying, .juggling, .building: return 40
        case .typing: return 30
        case .thinking: return 20
        case .roam, .idle: return 10
        default: return 0
        }
    }

    /// Permission/elicitation/question requests are transient: upstream never
    /// lets them create a session row or overwrite a live session's state.
    /// A plain `notification` (Claude's Notification hook) is a real state and
    /// is deliberately excluded.
    private func isTransientRequestEvent(_ name: String) -> Bool {
        let normalized = EventStateMapper.normalizedEventName(name)
        if ["permissionrequest", "permission", "codexuserinputrequest",
            "userinputrequest", "requestuserinput", "elicitation"].contains(normalized) {
            return true
        }
        // Suffixed vendor spellings (`approvalRequired`, `toolPermissionRequest`).
        return (normalized.contains("permission") || normalized.contains("approval")
                || normalized.contains("elicitation"))
            && EventStateMapper.state(
                for: AgentEvent(sessionID: "-", agentID: "-", eventName: name),
                liveSessionCount: 1
            ) == .notification
    }

    private func isSessionEnd(_ name: String) -> Bool {
        let normalized = EventStateMapper.normalizedEventName(name)
        return [
            "sessionend", "sessionended", "sessionshutdown", "sessionclosed",
            "exit", "shutdown", "processexit"
        ].contains(normalized)
    }

    private func isSubagentStop(_ name: String) -> Bool {
        let normalized = EventStateMapper.normalizedEventName(name)
        return ["subagentstop", "subagentstopped", "subagentend", "subagentended"].contains(normalized)
    }

    private func isSubagentStart(_ name: String) -> Bool {
        let normalized = EventStateMapper.normalizedEventName(name)
        return ["subagentstart", "subagentstarted"].contains(normalized)
    }

    private func isClaudeMainStop(_ event: AgentEvent) -> Bool {
        let agent = EventStateMapper.normalizedEventName(event.agentID)
        let name = EventStateMapper.normalizedEventName(event.eventName)
        return (agent == "claude" || agent == "claudecode") && name == "stop"
    }

    private func defaultTitle(for agentID: String) -> String {
        switch agentID.lowercased() {
        case "claude", "claude-code": return "Claude Code"
        case "codex", "codex-cli": return "Codex"
        case "gemini", "gemini-cli": return "Gemini CLI"
        case "copilot", "copilot-cli": return "Copilot CLI"
        case "opencode": return "opencode"
        default: return agentID.isEmpty ? "Agent session" : agentID
        }
    }
}
