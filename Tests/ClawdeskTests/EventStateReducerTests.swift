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

    func testSessionsAggregateByPriorityAndDisappearOnSessionEnd() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "thinking", eventName: "UserPromptSubmit"))
        let active = store.apply(AgentEvent(sessionID: "permission", eventName: "PermissionRequest"))
        XCTAssertEqual(active.state, .notification)
        XCTAssertEqual(active.sessions.count, 2)

        let afterEnd = store.apply(AgentEvent(sessionID: "permission", eventName: "SessionEnd"))
        XCTAssertEqual(afterEnd.completedSessionID, "permission")
        XCTAssertEqual(afterEnd.state, .thinking)
        XCTAssertEqual(afterEnd.sessions.count, 1)
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
