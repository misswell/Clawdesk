import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class CodexLogMonitorTests: XCTestCase {
    func testFallbackMapsCodexRolloutEventsWithoutRetainingTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-log-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-demo.jsonl")
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","session_id":"s-1","cwd":"/tmp/project"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","session_id":"s-1"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","session_id":"s-1"}}"#
        ].joined(separator: "\n") + "\n"
        try lines.data(using: .utf8)?.write(to: file)

        let monitor = CodexLogMonitor(homeDirectory: root)
        var events: [AgentEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.scanOnce()

        XCTAssertEqual(events.map(\.eventName), ["UserPromptSubmit", "PreToolUse", "Stop"])
        XCTAssertTrue(events.allSatisfy { $0.agentID == "codex" && $0.sessionID == "s-1" })
        XCTAssertNil(events.first?.payload["transcript"])
    }

    func testFallbackFindsDatePartitionedCodexDesktopRollouts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-desktop-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".codex/sessions/2026/09/02", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "rollout-2026-09-02T11-00-00-01a05734-2e4c-7163-ba6e-71e7940d01d2.jsonl"
        )
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","cwd":"/tmp/project"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        ].joined(separator: "\n") + "\n"
        try lines.data(using: .utf8)?.write(to: file)

        let monitor = CodexLogMonitor(homeDirectory: root)
        var events: [AgentEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.scanOnce()

        XCTAssertEqual(events.map(\.eventName), ["UserPromptSubmit", "PreToolUse", "Stop"])
        XCTAssertTrue(events.allSatisfy {
            $0.agentID == "codex" && $0.sessionID == "01a05734-2e4c-7163-ba6e-71e7940d01d2"
        })
    }

    func testDesktopRolloutHeaderKeepsResponseItemsInTheSessionInsteadOfUsingItemIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-session-header-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".codex/sessions/2026/09/02", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-desktop-session.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"session_id":"desktop-session","originator":"Codex Desktop","cwd":"/tmp/project"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_item_id","call_id":"call-1","name":"exec"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: file)

        let monitor = CodexLogMonitor(homeDirectory: root)
        var events: [AgentEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.scanOnce()

        XCTAssertEqual(events.map(\.eventName), ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop"])
        XCTAssertTrue(events.allSatisfy { $0.sessionID == "desktop-session" })
    }

    func testMonitorFollowsCODEXHOMEForDesktopData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-home-test-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("custom-codex", isDirectory: true)
        let directory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-custom.jsonl")
        try Data((#"{"type":"event_msg","payload":{"type":"task_started","session_id":"custom-session"}}"# + "\n").utf8)
            .write(to: file)

        let monitor = CodexLogMonitor(
            homeDirectory: root,
            environment: ["CODEX_HOME": codexHome.path]
        )
        var events: [AgentEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.scanOnce()

        XCTAssertEqual(monitor.sessionsDirectory, directory)
        XCTAssertEqual(events.map(\.sessionID), ["custom-session"])
    }

    func testFallbackRetriesAnIncompleteFinalJSONLineAfterTheWriterAppends() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-partial-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-partial.jsonl")
        let firstLine = #"{"type":"event_msg","payload":{"type":"task_started","session_id":"s-2"}}"# + "\n"
        let secondLine = #"{"type":"event_msg","payload":{"type":"task_complete","session_id":"s-2"}}"#
        let split = secondLine.index(secondLine.startIndex, offsetBy: 18)
        try (firstLine + secondLine[..<split]).data(using: .utf8)?.write(to: file)

        let monitor = CodexLogMonitor(homeDirectory: root)
        var events: [AgentEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.scanOnce()
        XCTAssertEqual(events.map(\.eventName), ["UserPromptSubmit"])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data(secondLine[split...].utf8) + Data("\n".utf8))
        try handle.close()

        monitor.scanOnce()
        XCTAssertEqual(events.map(\.eventName), ["UserPromptSubmit", "Stop"])
    }

    func testRequestUserInputIsAReadOnlyQuestionAndMatchingOutputClearsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-question-test-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-question.jsonl")
        let request = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_123","session_id":"question-session","arguments":"{\"questions\":[{\"id\":\"scope\",\"header\":\"Scope\",\"question\":\"Which scope should I use?\",\"options\":[{\"label\":\"Focused\",\"description\":\"Only this module\"},{\"label\":\"Broad\",\"description\":\"All integrations\"}]}]}"}}"#
        let resolved = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_123","session_id":"question-session","output":"{}"}}"#
        try (request + "\n" + resolved + "\n").data(using: .utf8)?.write(to: file)

        let monitor = CodexLogMonitor(homeDirectory: root)
        var events: [AgentEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.scanOnce()

        XCTAssertEqual(events.map(\.eventName), ["RequestUserInput", "PostToolUse"])
        let question = try XCTUnwrap(events.first?.question)
        XCTAssertEqual(question.id, "call_123")
        XCTAssertEqual(question.questions.first?.question, "Which scope should I use?")
        XCTAssertEqual(question.questions.first?.options.map(\.label), ["Focused", "Broad"])
        XCTAssertEqual(events.last?.toolCallID, "call_123")
    }

    func testTrackingIsBoundedToTheMostRecentRolloutFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-bounded-files-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<160 {
            let file = directory.appendingPathComponent("rollout-\(index).jsonl")
            try Data("{}\n".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: file.path
            )
        }

        let monitor = CodexLogMonitor(homeDirectory: root)
        monitor.scanOnce()

        XCTAssertEqual(monitor.trackedFileCount, 128)
    }

    func testOversizedIncompleteRecordIsDiscardedInsteadOfRetained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-bounded-partial-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-oversized.jsonl")
        try Data(repeating: 0x61, count: 600 * 1024).write(to: file)

        let monitor = CodexLogMonitor(homeDirectory: root)
        monitor.scanOnce()
        XCTAssertLessThanOrEqual(monitor.bufferedPartialByteCount, 512 * 1024)
        monitor.scanOnce()
        XCTAssertLessThanOrEqual(monitor.bufferedPartialByteCount, 512 * 1024)
        monitor.scanOnce()
        XCTAssertEqual(monitor.bufferedPartialByteCount, 0)
    }
}
