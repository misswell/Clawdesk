import Foundation

public enum EventStateMapper {
    public static func preservesVisibleState(for event: AgentEvent) -> Bool {
        let agent = event.agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = event.eventName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        // Gemini calls this PreCompress, but its documented behavior is to
        // record the compaction in session history without changing the
        // current animation. Claude/Codex PreCompact still sweep normally.
        return agent.contains("gemini") && name == "precompress"
    }

    public static func state(for event: AgentEvent, liveSessionCount: Int) -> PetState {
        if let stateHint = event.stateHint {
            return stateHint
        }

        let name = event.eventName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        switch name {
        case "sessionstart", "sessionstarted", "startup", "idle", "ready":
            return .idle
        case "userpromptsubmit", "prompt", "promptsubmitted", "turnstart", "agentstart":
            return .thinking
        case "pretooluse", "posttooluse", "toolstart", "toolend", "working", "message":
            if event.subagentCount >= 1 { return .juggling }
            if liveSessionCount >= 3 { return .building }
            if liveSessionCount >= 2 { return .juggling }
            return .typing
        case "subagentstart", "subagentstarted", "juggling":
            return .juggling
        case "subagentstop", "subagentstopped":
            return event.subagentCount > 0 ? .juggling : .typing
        case "posttoolusefailure", "toolerror", "error", "stopfailure", "failed":
            return .error
        case "stop", "taskcomplete", "eventmsgtaskcomplete", "postcompact", "complete", "completed":
            return .attention
        case "permissionrequest", "permission", "notification", "needsattention", "requestuserinput":
            return .notification
        case "precompact", "precompress", "compacting", "sweeping":
            return .sweeping
        case "worktreecreate", "carrying", "preparing":
            return .carrying
        case "sessionend", "sessionended", "exit", "shutdown":
            return .idle
        default:
            return .idle
        }
    }
}

public final class SessionStore {
    private var sessionsByID: [String: SessionSnapshot] = [:]

    public init() {}

    public var sessions: [SessionSnapshot] {
        sessionsByID.values.sorted { lhs, rhs in
            if lhs.state == rhs.state { return lhs.lastActivity > rhs.lastActivity }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    public func apply(_ event: AgentEvent) -> StateTransition {
        let existing = sessionsByID[event.sessionID]
        let isEnd = isSessionEnd(event.eventName)
        let liveCountBefore = sessionsByID.count
        let liveCountAfter = liveCountBefore + (existing == nil ? 1 : 0)
        var mappingEvent = event
        let stoppingSubagent = isSubagentStop(event.eventName)
        mappingEvent.subagentCount = stoppingSubagent ? event.subagentCount : max(event.subagentCount, existing?.subagentCount ?? 0)
        let mapped = EventStateMapper.preservesVisibleState(for: mappingEvent)
            ? (existing?.state ?? .idle)
            : EventStateMapper.state(for: mappingEvent, liveSessionCount: max(1, liveCountAfter))

        if isEnd {
            sessionsByID.removeValue(forKey: event.sessionID)
            return StateTransition(
                state: aggregateState(),
                sessions: sessions,
                completedSessionID: event.sessionID,
                permission: nil
            )
        }

        var recent = existing?.recentEvents ?? []
        recent.append(event.eventName)
        if recent.count > 12 { recent.removeFirst(recent.count - 12) }

        let title = event.title ?? existing?.title ?? defaultTitle(for: event.agentID)
        let snapshot = SessionSnapshot(
            id: event.sessionID,
            agentID: event.agentID,
            title: title,
            folder: event.folder ?? existing?.folder,
            state: mapped,
            subagentCount: stoppingSubagent ? event.subagentCount : max(event.subagentCount, existing?.subagentCount ?? 0),
            lastEvent: event.eventName,
            lastActivity: event.timestamp,
            terminalPID: event.terminalPID ?? existing?.terminalPID,
            recentEvents: recent,
            contextUsage: event.contextUsage ?? existing?.contextUsage
        )
        sessionsByID[event.sessionID] = snapshot

        return StateTransition(
            state: aggregateState(),
            sessions: sessions,
            permission: event.permission
        )
    }

    public func updateSubagentCount(sessionID: String, count: Int) -> StateTransition? {
        guard var session = sessionsByID[sessionID] else { return nil }
        session.subagentCount = max(0, count)
        if count > 0 { session.state = .juggling }
        sessionsByID[sessionID] = session
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

    /// Remove sessions that stopped reporting. Hook-based agents normally send
    /// SessionEnd, but process crashes and force-quits do not. A long timeout
    /// keeps this cleanup conservative and lets the next event revive a live
    /// session without any process polling overhead.
    public func pruneStale(now: Date = .now, olderThan interval: TimeInterval = 15 * 60) -> StateTransition? {
        let staleIDs = sessionsByID.values
            .filter { now.timeIntervalSince($0.lastActivity) >= interval }
            .map(\.id)
        guard !staleIDs.isEmpty else { return nil }
        for id in staleIDs { sessionsByID.removeValue(forKey: id) }
        return StateTransition(state: aggregateState(), sessions: sessions)
    }

    public func removeAll() {
        sessionsByID.removeAll()
    }

    private func aggregateState() -> PetState {
        guard !sessionsByID.isEmpty else { return .idle }
        let priority: [PetState: Int] = [
            .notification: 100,
            .error: 90,
            .attention: 80,
            .sweeping: 70,
            .carrying: 65,
            .building: 60,
            .juggling: 55,
            .typing: 40,
            .thinking: 30,
            .dozing: 10,
            .idle: 0
        ]
        func score(_ session: SessionSnapshot) -> Int {
            // A live subagent is an explicit attention tier and outranks a
            // background multi-session building animation. Plain two-session
            // work remains below the 3+ session building tier.
            if session.state == .juggling, session.subagentCount > 0 { return 75 }
            return priority[session.state] ?? 0
        }
        return sessionsByID.values.max { lhs, rhs in
            let left = score(lhs)
            let right = score(rhs)
            if left == right { return lhs.lastActivity < rhs.lastActivity }
            return left < right
        }?.state ?? .idle
    }

    private func isSessionEnd(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "")
        return ["sessionend", "sessionended", "exit", "shutdown"].contains(normalized)
    }

    private func isSubagentStop(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return normalized == "subagentstop" || normalized == "subagentstopped"
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
