import XCTest
@testable import Clawdesk

final class EventStateReducerTests: XCTestCase {
    func testLifecycleEventsProduceSharedStates() {
        XCTAssertEqual(
            EventStateMapper.state(for: AgentEvent(sessionID: "s", agentID: "claude-code", eventName: "UserPromptSubmit"), liveSessionCount: 1),
            .thinking
        )
        XCTAssertEqual(
            EventStateMapper.state(for: AgentEvent(sessionID: "s", eventName: "PreToolUse"), liveSessionCount: 1),
            .typing
        )
        XCTAssertEqual(
            EventStateMapper.state(for: AgentEvent(sessionID: "s", eventName: "PostToolUseFailure"), liveSessionCount: 1),
            .error
        )
        XCTAssertEqual(
            EventStateMapper.state(for: AgentEvent(sessionID: "s", eventName: "Stop"), liveSessionCount: 1),
            .attention
        )
    }

    func testUpstreamEventAliasesProduceTheSameSharedStates() {
        let expected: [(String, PetState)] = [
            ("BeforeAgent", .thinking),
            ("AfterAgent", .idle),
            ("agentSpawn", .idle),
            ("BeforeTool", .typing),
            ("AfterTool", .typing),
            ("PreInvocation", .thinking),
            ("PostInvocation", .typing),
            ("ApiError", .error),
            ("errorOccurred", .error),
            ("Elicitation", .notification),
            ("PermissionDenied", .notification),
            ("codexUserInputRequest", .notification),
            ("PermissionResult", .typing),
            ("event_msg:task_complete", .attention),
            ("session_shutdown", .idle),
            ("Interrupt", .idle)
        ]

        for (eventName, state) in expected {
            XCTAssertEqual(
                EventStateMapper.state(
                    for: AgentEvent(sessionID: "s", eventName: eventName),
                    liveSessionCount: 1
                ),
                state,
                eventName
            )
        }
    }

    func testDizzyIsAVisualReactionStateWhenExplicitlyRequested() {
        XCTAssertEqual(
            EventStateMapper.state(
                for: AgentEvent(sessionID: "dizzy", eventName: "Dizzy"),
                liveSessionCount: 1
            ),
            .idle,
            "dizzy is triggered by the cursor reaction, not an agent lifecycle event"
        )
    }

    func testPermissionRequestIsTransientAndNeverCreatesASession() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "thinking", eventName: "UserPromptSubmit"))
        // Upstream: a PermissionRequest must not create a session row for an
        // unknown session, nor overwrite the live session's lifecycle state.
        // It only surfaces through the transition's permission lane.
        let active = store.apply(AgentEvent(
            sessionID: "unknown-permission",
            eventName: "PermissionRequest",
            permission: PermissionRequest(sessionID: "unknown-permission", agentID: "claude-code", title: "Allow Bash?")
        ))
        XCTAssertEqual(active.state, .thinking)
        XCTAssertEqual(active.sessions.count, 1)
        XCTAssertEqual(active.permission?.title, "Allow Bash?")

        // A request scoped to a live session leaves that session's state and
        // recent-event history untouched as well.
        let scoped = store.apply(AgentEvent(sessionID: "thinking", eventName: "PermissionRequest"))
        XCTAssertEqual(scoped.state, .thinking)
        let session = store.sessions.first { $0.id == "thinking" }
        XCTAssertEqual(session?.lastEvent, "UserPromptSubmit")

        // A plain Notification hook is NOT transient: it creates a real row.
        let notification = store.apply(AgentEvent(sessionID: "notify", eventName: "Notification"))
        XCTAssertEqual(notification.state, .notification)
        XCTAssertEqual(notification.sessions.count, 2)

        let afterEnd = store.apply(AgentEvent(sessionID: "notify", eventName: "SessionEnd"))
        XCTAssertEqual(afterEnd.completedSessionID, "notify")
        XCTAssertEqual(afterEnd.state, .thinking)
        XCTAssertEqual(afterEnd.sessions.count, 1)
    }

    func testDuplicateClaudeStopDoesNotMarkCompletionTwice() {
        let store = SessionStore()
        let first = store.apply(AgentEvent(sessionID: "cc", agentID: "claude-code", eventName: "Stop"))
        XCTAssertFalse(first.isDuplicateCompletion)
        let duplicate = store.apply(AgentEvent(sessionID: "cc", agentID: "claude-code", eventName: "Stop"))
        XCTAssertTrue(duplicate.isDuplicateCompletion, "a repeated Stop with no activity in between is a duplicate delivery")
        // Forward progress re-arms the celebration.
        _ = store.apply(AgentEvent(sessionID: "cc", agentID: "claude-code", eventName: "UserPromptSubmit"))
        let rearmed = store.apply(AgentEvent(sessionID: "cc", agentID: "claude-code", eventName: "Stop"))
        XCTAssertFalse(rearmed.isDuplicateCompletion)
    }

    func testHeadlessSessionsAreExcludedFromTheDominantState() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "cc", agentID: "claude-code", eventName: "Stop"))
        XCTAssertEqual(store.currentAggregateState(), .attention)
        let headless = store.apply(AgentEvent(
            sessionID: "headless",
            agentID: "claude-code",
            eventName: "UserPromptSubmit",
            headless: true
        ))
        XCTAssertEqual(headless.state, .attention, "headless work never raises the aggregate")
        XCTAssertEqual(store.currentAggregateState(), .attention)
    }

    func testSessionMenuSortsByStatePriorityThenRecency() {
        let store = SessionStore()
        let early = Date(timeIntervalSince1970: 1_000)
        _ = store.apply(AgentEvent(sessionID: "attention", agentID: "claude-code", eventName: "Stop", timestamp: early))
        _ = store.apply(AgentEvent(sessionID: "error", agentID: "claude-code", eventName: "ApiError", timestamp: early))
        // An older error outranks a newer completion.
        XCTAssertEqual(store.sessions.first?.id, "error")
    }

    // MARK: - Codex official-hook turn machine

    private func codexEvent(
        _ eventName: String,
        sessionID: String = "cx",
        turnID: String? = "t1",
        role: String? = nil,
        stopHookActive: Bool = false,
        assistantOutput: String? = nil
    ) -> AgentEvent {
        var payload = ["hook_source": "codex-official"]
        if let turnID { payload["turn_id"] = turnID }
        if let role { payload["codex_session_role"] = role }
        return AgentEvent(
            sessionID: sessionID,
            agentID: "codex",
            eventName: eventName,
            stopHookActive: stopHookActive,
            assistantLastOutput: assistantOutput,
            payload: payload
        )
    }

    func testCodexQuietTurnEndsIdleWithoutCelebration() {
        let store = SessionStore()
        _ = store.apply(codexEvent("UserPromptSubmit"))
        _ = store.apply(codexEvent("PreToolUse", turnID: nil))
        // No tool use inside the turn and no assistant output: the Stop is a
        // quiet turn end, not a completion.
        let stopped = store.apply(codexEvent("Stop"))
        XCTAssertEqual(stopped.sessions.first { $0.id == "cx" }?.state, .idle)
    }

    func testCodexToolBearingTurnCelebratesOnStop() {
        let store = SessionStore()
        _ = store.apply(codexEvent("UserPromptSubmit"))
        _ = store.apply(codexEvent("PreToolUse"))
        let stopped = store.apply(codexEvent("Stop"))
        XCTAssertEqual(stopped.sessions.first { $0.id == "cx" }?.state, .attention)
        XCTAssertFalse(stopped.isDuplicateCompletion)
        // The turn is consumed; a second Stop for the same turn is quiet.
        let replay = store.apply(codexEvent("Stop"))
        XCTAssertEqual(replay.sessions.first { $0.id == "cx" }?.state, .idle)
    }

    func testCodexStopHookActiveContinuesWithoutCelebrating() {
        let store = SessionStore()
        _ = store.apply(codexEvent("UserPromptSubmit"))
        _ = store.apply(codexEvent("PreToolUse"))
        let held = store.apply(codexEvent("Stop", stopHookActive: true))
        XCTAssertTrue(held.isDuplicateCompletion, "stop_hook_active drops the completion side effects")
        // Upstream consumes the turn on stop_hook_active: the follow-up Stop
        // is quiet unless it carries the final assistant output.
        let quiet = store.apply(codexEvent("Stop"))
        XCTAssertEqual(quiet.sessions.first { $0.id == "cx" }?.state, .idle)
        let finished = store.apply(codexEvent("Stop", assistantOutput: "Continued and done."))
        XCTAssertEqual(finished.sessions.first { $0.id == "cx" }?.state, .attention)
    }

    func testCodexSubagentStopIsHeadlessIdle() {
        let store = SessionStore()
        _ = store.apply(codexEvent("UserPromptSubmit"))
        _ = store.apply(codexEvent("PreToolUse"))
        let stopped = store.apply(codexEvent("Stop", role: "subagent"))
        let session = stopped.sessions.first { $0.id == "cx" }
        XCTAssertEqual(session?.state, .idle)
        XCTAssertEqual(session?.headless, true)
    }

    func testCodexAssistantOutputAloneCountsAsCompletion() {
        let store = SessionStore()
        _ = store.apply(codexEvent("UserPromptSubmit"))
        let stopped = store.apply(codexEvent("Stop", assistantOutput: "All done."))
        XCTAssertEqual(stopped.sessions.first { $0.id == "cx" }?.state, .attention)
    }

    // MARK: - dashboard session actions

    func testSessionRenameKeepsLifecycleFields() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "s", agentID: "claude-code", eventName: "UserPromptSubmit", title: "Original"))
        let before = store.sessions.first { $0.id == "s" }

        let renamed = store.setSessionTitle("My build", for: "s")
        XCTAssertNotNil(renamed)
        let session = renamed?.sessions.first { $0.id == "s" }
        XCTAssertEqual(session?.title, "My build")
        XCTAssertEqual(session?.lastActivity, before?.lastActivity, "a rename never bumps the lifecycle timestamp")
        XCTAssertEqual(renamed?.sessions.first { $0.id == "s" }?.state, before?.state)
    }

    func testDismissRemovesRowAndRecomputesAggregate() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "a", agentID: "claude-code", eventName: "UserPromptSubmit"))
        _ = store.apply(AgentEvent(sessionID: "b", agentID: "claude-code", eventName: "Stop"))
        XCTAssertEqual(store.currentAggregateState(), .attention)

        let dismissed = store.dismiss(sessionID: "b")
        XCTAssertEqual(dismissed?.sessions.map(\.id), ["a"])
        XCTAssertEqual(dismissed?.state, .thinking)
        XCTAssertNil(store.dismiss(sessionID: "b"), "dismissing an unknown session is a no-op")
    }

    func testMultiAgentWorkUsesBuildingAndSubagentTier() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "one", eventName: "PreToolUse"))
        _ = store.apply(AgentEvent(sessionID: "two", eventName: "PreToolUse"))
        let third = store.apply(AgentEvent(sessionID: "three", eventName: "PreToolUse"))
        XCTAssertEqual(third.state, .building)

        let subagent = store.apply(AgentEvent(sessionID: "one", eventName: "SubagentStart", subagentCount: 1))
        XCTAssertEqual(subagent.state, .juggling)
    }

    func testWorkingStateHintStillUsesSessionAndSubagentTiers() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(
            sessionID: "one",
            eventName: "working",
            stateHint: .typing
        ))
        XCTAssertEqual(store.sessions.first?.state, .typing)

        _ = store.apply(AgentEvent(
            sessionID: "two",
            eventName: "working",
            stateHint: .typing
        ))
        XCTAssertEqual(store.sessions.first(where: { $0.id == "two" })?.state, .juggling)

        let third = store.apply(AgentEvent(
            sessionID: "three",
            eventName: "working",
            stateHint: .typing
        ))
        XCTAssertEqual(third.state, .building)

        let subagentStop = EventStateMapper.state(
            for: AgentEvent(
                sessionID: "subagent",
                eventName: "SubagentStop",
                stateHint: .typing,
                subagentCount: 2
            ),
            liveSessionCount: 1
        )
        XCTAssertEqual(subagentStop, .juggling)
    }

    func testSessionShutdownAliasRemovesTheSession() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "shutdown", eventName: "SessionStart"))

        let transition = store.apply(AgentEvent(
            sessionID: "shutdown",
            eventName: "session_shutdown"
        ))

        XCTAssertEqual(transition.completedSessionID, "shutdown")
        XCTAssertTrue(transition.sessions.isEmpty)
        XCTAssertEqual(transition.state, .idle)
    }

    func testAggregatePriorityMatchesTheUpstreamOrder() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "permission", eventName: "PermissionRequest"))
        let error = store.apply(AgentEvent(sessionID: "error", eventName: "PostToolUseFailure"))
        XCTAssertEqual(error.state, .error)

        let sweeping = store.apply(AgentEvent(sessionID: "sweeping", eventName: "PreCompact"))
        XCTAssertEqual(sweeping.state, .error)

        let completed = store.apply(AgentEvent(sessionID: "complete", eventName: "Stop"))
        XCTAssertEqual(completed.state, .error)
    }

    func testGeminiPreCompressRecordsHistoryWithoutChangingVisibleState() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "gemini-session", agentID: "gemini-cli", eventName: "PreToolUse"))
        let transition = store.apply(AgentEvent(sessionID: "gemini-session", agentID: "gemini-cli", eventName: "PreCompress"))
        XCTAssertEqual(transition.sessions.first?.state, .typing)
        XCTAssertEqual(transition.sessions.first?.lastEvent, "PreCompress")
    }

    func testAutomaticPostCompactKeepsTheTurnWorking() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "PreToolUse"
        ))

        let automatic = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "PostCompact",
            payload: ["trigger": "auto"]
        ))
        XCTAssertEqual(automatic.state, .thinking)

        let manual = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "PostCompact",
            payload: ["trigger": "manual"]
        ))
        XCTAssertEqual(manual.state, .idle)
    }

    func testClaudeStopWaitsForBackgroundSubagentsBeforeCompletion() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "PreToolUse"
        ))

        let held = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "Stop",
            backgroundTasksCount: 1,
            backgroundSubagentCount: 1
        ))
        XCTAssertEqual(held.state, .juggling)
        XCTAssertEqual(held.sessions.first?.subagentCount, 1)

        let completed = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "Stop",
            backgroundTasksCount: 0,
            backgroundSubagentCount: 0
        ))
        XCTAssertEqual(completed.state, .attention)
        XCTAssertEqual(completed.sessions.first?.subagentCount, 0)
    }

    func testClaudeStopWaitsForCronOrBackgroundShellWithoutInventingSubagent() {
        let store = SessionStore()
        let held = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "Stop",
            backgroundTasksCount: 1,
            sessionCronsCount: 1
        ))
        XCTAssertEqual(held.state, .typing)
        XCTAssertEqual(held.sessions.first?.subagentCount, 0)
    }

    func testSubagentIDsAreDeduplicatedAndLastStopRestoresParentState() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "UserPromptSubmit"
        ))
        let first = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "SubagentStart",
            subagentID: "child-a"
        ))
        XCTAssertEqual(first.sessions.first?.subagentCount, 1)
        XCTAssertEqual(first.sessions.first?.state, .juggling)

        let duplicate = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "SubagentStart",
            subagentID: "child-a"
        ))
        XCTAssertEqual(duplicate.sessions.first?.subagentCount, 1)

        _ = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "SubagentStart",
            subagentID: "child-b"
        ))
        let oneLeft = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "SubagentStop",
            subagentID: "child-a"
        ))
        XCTAssertEqual(oneLeft.sessions.first?.subagentCount, 1)
        XCTAssertEqual(oneLeft.sessions.first?.state, .juggling)

        let restored = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "SubagentStop",
            subagentID: "child-b"
        ))
        XCTAssertEqual(restored.sessions.first?.subagentCount, 0)
        XCTAssertEqual(restored.sessions.first?.state, .thinking)
    }

    func testUnknownSubagentStopDoesNotReduceTheTrackedPopulation() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "parent", eventName: "PreToolUse"))
        _ = store.apply(AgentEvent(sessionID: "parent", eventName: "SubagentStart", subagentID: "known"))

        let transition = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "SubagentStop",
            subagentID: "unknown"
        ))
        XCTAssertEqual(transition.sessions.first?.subagentCount, 1)
        XCTAssertEqual(transition.sessions.first?.state, .juggling)
    }

    func testScopedSessionEndStopsOnlyTheNamedSubagent() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "parent", eventName: "PreToolUse"))
        _ = store.apply(AgentEvent(sessionID: "parent", eventName: "SubagentStart", subagentID: "child-a"))
        _ = store.apply(AgentEvent(sessionID: "parent", eventName: "SubagentStart", subagentID: "child-b"))

        let transition = store.apply(AgentEvent(
            sessionID: "parent",
            eventName: "SessionEnd",
            subagentID: "child-a"
        ))
        XCTAssertNil(transition.completedSessionID)
        XCTAssertEqual(transition.sessions.count, 1)
        XCTAssertEqual(transition.sessions.first?.subagentCount, 1)
        XCTAssertEqual(transition.sessions.first?.state, .juggling)
    }

    func testClaudeStopWithFinalOutputAndBackgroundWorkIsHeldForDebounceCandidate() {
        let store = SessionStore()
        let transition = store.apply(AgentEvent(
            sessionID: "claude-session",
            agentID: "claude-code",
            eventName: "Stop",
            backgroundTasksCount: 1,
            assistantLastOutput: "final answer"
        ))
        XCTAssertEqual(transition.state, .typing)
        XCTAssertEqual(transition.sessions.first?.state, .typing)
    }

    func testTraeCodeKeepsFirstDerivedSessionTitle() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "traecode:s", agentID: "traecode", eventName: "UserPromptSubmit", title: "First task"))
        let followup = store.apply(AgentEvent(sessionID: "traecode:s", agentID: "traecode", eventName: "UserPromptSubmit", title: "Follow-up"))
        XCTAssertEqual(followup.sessions.first?.title, "First task")
    }
}
