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

    func testGeminiPreCompressRecordsHistoryWithoutChangingVisibleState() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "gemini-session", agentID: "gemini-cli", eventName: "PreToolUse"))
        let transition = store.apply(AgentEvent(sessionID: "gemini-session", agentID: "gemini-cli", eventName: "PreCompress"))
        XCTAssertEqual(transition.sessions.first?.state, .typing)
        XCTAssertEqual(transition.sessions.first?.lastEvent, "PreCompress")
    }
}
