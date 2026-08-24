import Foundation
import XCTest
@testable import Clawdesk

final class AgentEventAdapterTests: XCTestCase {
    func testCodexRequestUserInputBecomesReadOnlyQuestionNotPermission() {
        let adapter = DefaultAgentEventAdapter(environment: [:])
        let object: [String: Any] = [
            "questions": [
                ["question": "Continue?", "header": "Choice", "options": [
                    ["label": "Yes"], ["label": "No", "isOther": true]
                ]]
            ],
            "call_id": "q-1"
        ]
        let result = adapter.adapt(agentID: "codex", eventName: "RequestUserInput", object: object, query: [:], sessionID: "s-1")
        XCTAssertTrue(result.isQuestionEvent)
        XCTAssertNotNil(result.question)
        XCTAssertEqual(result.question?.id, "q-1")
        XCTAssertEqual(result.question?.questions.first?.question, "Continue?")
        XCTAssertEqual(result.question?.questions.first?.options.first?.label, "Yes")
        XCTAssertFalse(result.permissionSuspect)
        XCTAssertFalse(result.questionResolution)
    }

    func testCodexPostToolUseMarksQuestionResolution() {
        let adapter = DefaultAgentEventAdapter(environment: [:])
        let object: [String: Any] = ["tool_call_id": "q-1"]
        let result = adapter.adapt(agentID: "codex", eventName: "PostToolUse", object: object, query: [:], sessionID: "s-1")
        XCTAssertTrue(result.questionResolution)
        XCTAssertEqual(result.questionResolutionID, "q-1")
        XCTAssertNil(result.question)
    }

    func testCodexQuestionResolvedByNameWithoutCallID() {
        let adapter = DefaultAgentEventAdapter(environment: [:])
        let result = adapter.adapt(agentID: "codex", eventName: "QuestionResolved", object: [:], query: [:], sessionID: "s-1")
        XCTAssertTrue(result.questionResolution)
    }

    func testKimiSuspectDefaultsTo800Milliseconds() {
        let adapter = DefaultAgentEventAdapter(environment: [:])
        let result = adapter.adapt(
            agentID: "kimi-cli",
            eventName: "PreToolUse",
            object: ["tool_name": "shell"],
            query: ["clawdesk-kimi-permission-mode": "suspect"],
            sessionID: "k"
        )
        XCTAssertTrue(result.permissionSuspect)
        XCTAssertEqual(result.permissionSuspectDelayMilliseconds, 800)
    }

    func testKimiSuspectDelayIsTunedByEnvironment() {
        let adapter = DefaultAgentEventAdapter(environment: ["CLAWD_KIMI_PERMISSION_SUSPECT_MS": "1500"])
        let result = adapter.adapt(
            agentID: "kimi-cli",
            eventName: "PreToolUse",
            object: ["tool_name": "shell"],
            query: ["clawdesk-kimi-permission-mode": "suspect"],
            sessionID: "k"
        )
        XCTAssertTrue(result.permissionSuspect)
        XCTAssertEqual(result.permissionSuspectDelayMilliseconds, 1500)
    }

    func testKimiRuntimeModeOverridesPersistedFlagAndDisableWins() {
        let adapter = DefaultAgentEventAdapter(environment: [
            "CLAWD_KIMI_PERMISSION_MODE": "explicit",
            "CLAWD_KIMI_DISABLE_PRETOOL_PERMISSION": "1"
        ])
        let result = adapter.adapt(
            agentID: "kimi-cli",
            eventName: "PreToolUse",
            object: ["tool_name": "shell"],
            query: ["clawdesk-kimi-permission-mode": "suspect"],
            sessionID: "k"
        )
        XCTAssertFalse(result.permissionSuspect)
        XCTAssertFalse(result.permissionGated)
    }

    func testKimiImmediateOverrideForcesNotification() {
        let adapter = DefaultAgentEventAdapter(environment: ["CLAWD_KIMI_PERMISSION_IMMEDIATE": "1"])
        let result = adapter.adapt(
            agentID: "kimi-cli",
            eventName: "PreToolUse",
            object: ["tool_name": "shell"],
            query: ["clawdesk-kimi-permission-mode": "suspect"],
            sessionID: "k"
        )
        XCTAssertTrue(result.immediateNotification)
        XCTAssertFalse(result.permissionSuspect)
    }

    func testZCodeRequiresCanonicalToolFieldsAndSuppressesSuggestions() {
        let adapter = DefaultAgentEventAdapter(environment: [:])
        let supported = adapter.adapt(
            agentID: "zcode",
            eventName: "PermissionRequest",
            object: [
                "tool_name": "Bash",
                "tool_input": ["command": "ls"],
                "permission_suggestions": [["label": "Allow"]]
            ],
            query: [:],
            sessionID: "z"
        )

        XCTAssertTrue(supported.permissionEligible)
        XCTAssertFalse(supported.forwardsPermissionSuggestions)
        XCTAssertTrue(supported.permissionInput?.contains("command") == true)

        let aliasOnly = adapter.adapt(
            agentID: "zcode",
            eventName: "PermissionRequest",
            object: ["toolName": "Bash", "toolInput": ["command": "ls"]],
            query: [:],
            sessionID: "z"
        )
        XCTAssertFalse(aliasOnly.permissionEligible)
    }

    func testZCodeNoDecisionUsesEmptyHTTPResponse() {
        let adapter = DefaultAgentEventAdapter(environment: [:])

        XCTAssertEqual(
            adapter.permissionResponse(for: .defer, agentID: "zcode", eventName: "PermissionRequest").statusCode,
            204
        )
        XCTAssertEqual(
            adapter.permissionFallbackResponse(agentID: "zcode", eventName: "PermissionRequest").statusCode,
            204
        )
    }
}
