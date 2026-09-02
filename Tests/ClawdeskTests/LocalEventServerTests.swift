import Foundation
import XCTest
@testable import Clawdesk

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var event: AgentEvent?

    func record(_ event: AgentEvent) {
        lock.lock()
        self.event = event
        lock.unlock()
    }

    func value() -> AgentEvent? {
        lock.lock()
        defer { lock.unlock() }
        return event
    }
}

private struct TestQuotaAdapter: AgentQuotaAdapter {
    func quotaReport(agentID: String, rateLimits: [String: Any], capturedAt: Date, now: Date) -> QuotaReport? {
        QuotaReport(
            providerID: "test-\(agentID)",
            displayName: "Injected",
            buckets: [QuotaBucket(id: "test", usedPercent: rateLimits.isEmpty ? 0 : 42)],
            capturedAt: capturedAt
        )
    }
}

@MainActor
final class LocalEventServerTests: XCTestCase {
    func testTraeCodeNamespacesSessionAndUsesFirstSafePromptLineAsTitle() async throws {
        let server = LocalEventServer(preferredPort: 37_869)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)

        let response = try curl(
            port: server.port,
            path: "/state?event=UserPromptSubmit&agent=traecode&session_id=shared-id",
            body: #"{"prompt":"\nImplement the searchable settings panel\nsecond line"}"#
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.value()?.sessionID, "traecode:shared-id")
        XCTAssertEqual(recorder.value()?.title, "Implement the searchable settings panel")
        XCTAssertEqual(recorder.value()?.agentID, "traecode")
    }

    func testClaudeBackgroundTaskSnapshotPreservesTypedSubagentZeroVersusPresence() async throws {
        let server = LocalEventServer(preferredPort: 37_868)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)

        _ = try curl(
            port: server.port,
            path: "/state?event=Stop&agent=claude-code&session_id=background",
            body: #"{"background_tasks":[{"type":"subagent","id":"private"},{"type":"shell","command":"private"}],"session_crons":[]}"#
        )

        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.value()?.backgroundTasksCount, 2)
        XCTAssertEqual(recorder.value()?.backgroundSubagentCount, 1)
        XCTAssertEqual(recorder.value()?.sessionCronsCount, 0)
        XCTAssertFalse(recorder.value()?.payload.values.contains("private") == true)
    }

    func testQueryEventWinsOverBodyStateHint() async throws {
        let server = LocalEventServer(preferredPort: 37_880)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)

        let response = try curl(
            port: server.port,
            path: "/state?event=Stop&agent=claude-code&session_id=stop-hint",
            body: #"{"state":"working","subagent_id":"child-1","subagent_type":"agent","preserve_state":true}"#
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        let event = try XCTUnwrap(recorder.value())
        XCTAssertEqual(event.eventName, "Stop")
        XCTAssertEqual(event.stateHint, .typing)
        XCTAssertEqual(event.subagentID, "child-1")
        XCTAssertEqual(event.subagentType, "agent")
        XCTAssertTrue(event.preserveState)
    }

    func testClaudeStopParsesCompletionGateFields() async throws {
        let server = LocalEventServer(preferredPort: 37_881)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)

        let response = try curl(
            port: server.port,
            path: "/state?event=Stop&agent=claude-code&session_id=stop-fields",
            body: #"{"background_tasks_count":1,"session_crons_count":0,"stop_hook_active":false,"assistant_last_output":"done","assistant_last_output_truncated":true,"headless":true}"#
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        let event = try XCTUnwrap(recorder.value())
        XCTAssertEqual(event.backgroundTasksCount, 1)
        XCTAssertEqual(event.assistantLastOutput, "done")
        XCTAssertTrue(event.assistantLastOutputTruncated)
        XCTAssertTrue(event.headless)
    }

    func testRemoteIngressIsProfileBoundAndRejectsOtherRoutes() async throws {
        let server = LocalEventServer(preferredPort: 37_870)
        let nonce = String(repeating: "a", count: 32)
        let recorder = EventRecorder()
        let eventReceived = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            eventReceived.signal()
        }
        server.start()
        defer { server.stop() }

        let mainPort = try await waitForServer(server)
        server.registerRemoteNonce(nonce)
        let ingressPort = try await startRemoteIngress(server, nonce: nonce)

        let missingNonce = try curl(
            port: ingressPort,
            path: "/state?event=UserPromptSubmit&agent=claude-code",
            body: "{}"
        )
        XCTAssertEqual(missingNonce.status, 404)

        let health = try curl(port: ingressPort, path: "/health")
        XCTAssertEqual(health.status, 404)

        let accepted = try curl(
            port: ingressPort,
            path: "/state?event=UserPromptSubmit&agent=claude-code&session_id=raw-session&remote_prefix=remote-a&clawdesk-remote-v1=1&clawdesk-remote-nonce=\(nonce)",
            body: "{\"title\":\"Remote task\"}"
        )
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(eventReceived.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.value()?.sessionID, "remote-a:raw-session")
        XCTAssertEqual(recorder.value()?.title, "Remote task")

        let localHealth = try curl(port: mainPort, path: "/health")
        XCTAssertEqual(localHealth.status, 200)
    }

    func testQuotaDecodingIsDelegatedToInjectedAgentAdapter() async throws {
        let server = LocalEventServer(preferredPort: 37_871, quotaAdapter: TestQuotaAdapter())
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)
        let response = try curl(
            port: server.port,
            path: "/state?event=QuotaUpdate&agent=unknown-agent&session_id=quota",
            body: "{\"rate_limits\":{\"custom\":true}}"
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.value()?.quota?.providerID, "test-unknown-agent")
    }

    func testContextUsageParsesClaudeWindowTelemetryAsMetadataOnly() async throws {
        let server = LocalEventServer(preferredPort: 37_879)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)

        let response = try curl(
            port: server.port,
            path: "/state?event=ContextUpdate&agent=claude-code&session_id=context-1",
            body: #"{"metadata_only":true,"context_window":{"current_usage":{"input_tokens":1200,"cache_read_input_tokens":100,"cache_creation_input_tokens":50},"context_window_size":200000,"used_percentage":13}}"#
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(recorder.value()?.metadataOnly == true)
        let usage = try XCTUnwrap(recorder.value()?.contextUsage)
        XCTAssertEqual(usage.used, 1_350, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(usage.limit), 200_000, accuracy: 0.001)
        XCTAssertEqual(usage.percent, 13)
        XCTAssertEqual(usage.source, "claude")
    }

    func testKimiSuspectAndGateCloseStayNonBlocking() async throws {
        let server = LocalEventServer(preferredPort: 37_872)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)

        let suspect = try curl(
            port: server.port,
            path: "/state?event=PreToolUse&agent=kimi-cli&session_id=kimi&clawdesk-kimi-permission-mode=suspect",
            body: "{\"tool_name\":\"shell\",\"tool_call_id\":\"gate-1\"}"
        )
        XCTAssertEqual(suspect.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(recorder.value()?.permissionSuspect == true)
        XCTAssertNil(recorder.value()?.permission)

        let close = try curl(
            port: server.port,
            path: "/state?event=PostToolUse&agent=kimi-cli&session_id=kimi",
            body: "{\"tool_name\":\"shell\",\"tool_call_id\":\"gate-1\"}"
        )
        XCTAssertEqual(close.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(recorder.value()?.permissionGated == true)
    }

    func testCodexRequestUserInputThroughHTTPIsReadOnlyQuestion() async throws {
        let server = LocalEventServer(preferredPort: 37_873)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .event(event) = message else { return }
            recorder.record(event)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        _ = try await waitForServer(server)

        let response = try curl(
            port: server.port,
            path: "/state?event=RequestUserInput&agent=codex&session_id=codex-q",
            body: #"{"questions":[{"question":"Continue?","options":[{"label":"Yes"}]}],"call_id":"q-9"}"#
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertNil(recorder.value()?.permission)
        XCTAssertEqual(recorder.value()?.question?.id, "q-9")
        XCTAssertEqual(recorder.value()?.question?.questions.first?.question, "Continue?")
    }

    func testPermissionSuggestionsAreParsed() async throws {
        let server = LocalEventServer(preferredPort: 37_875)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .permission(event, reply) = message else { return }
            recorder.record(event)
            reply.resolve(.allow)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        let port = try await waitForServer(server)

        let response = try curl(
            port: port,
            path: "/permission?event=PermissionRequest&agent=claude-code&session_id=perm",
            body: #"{"tool_name":"Bash","command":"ls","permission_suggestions":[{"label":"Yes","decision":"allow"},{"label":"No","decision":"deny"},"always"]}"#
        )
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)

        let suggestions = recorder.value()?.permission?.suggestions
        XCTAssertEqual(suggestions?.count, 3)
        XCTAssertEqual(suggestions?[0].label, "Yes")
        XCTAssertEqual(suggestions?[0].decision, .allow)
        XCTAssertEqual(suggestions?[1].label, "No")
        XCTAssertEqual(suggestions?[1].decision, .deny)
        XCTAssertEqual(suggestions?[2].label, "always")
        XCTAssertEqual(suggestions?[2].decision, .allow)
    }

    func testZCodePermissionUsesStrictHookSpecificOutput() async throws {
        let server = LocalEventServer(preferredPort: 37_876)
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .permission(_, reply) = message else { return }
            reply.resolve(.allow)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        let port = try await waitForServer(server)

        let response = try curl(
            port: port,
            path: "/permission?event=PermissionRequest&agent=zcode&session_id=zcode:perm",
            body: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(json["approved"], "ZCode must not receive the generic Claude permission response")
    }

    func testHookQueryAgentIdentityCannotBeOverriddenByBody() async throws {
        let server = LocalEventServer(preferredPort: 37_878)
        let recorder = EventRecorder()
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case let .permission(event, reply) = message else { return }
            recorder.record(event)
            reply.resolve(.allow)
            received.signal()
        }
        server.start()
        defer { server.stop() }
        let port = try await waitForServer(server)

        let response = try curl(
            port: port,
            path: "/permission?event=PermissionRequest&agent=zcode&session_id=zcode:identity",
            body: #"{"agent_id":"claude-code","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(recorder.value()?.agentID, "zcode")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        XCTAssertNotNil(json["hookSpecificOutput"])
        XCTAssertNil(json["approved"])
    }

    func testZCodeUnknownToolFallsBackToNativePermissionUI() async throws {
        let server = LocalEventServer(preferredPort: 37_877)
        let received = DispatchSemaphore(value: 0)
        server.onMessage = { message in
            guard case .event = message else { return }
            received.signal()
        }
        server.start()
        defer { server.stop() }
        let port = try await waitForServer(server)

        let response = try curl(
            port: port,
            path: "/permission?event=PermissionRequest&agent=zcode&session_id=zcode:unknown",
            body: #"{"tool_input":{"command":"ls"}}"#
        )

        XCTAssertEqual(response.status, 204)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(received.wait(timeout: .now() + 2), .success)
    }

    func testOversizedRequestBodyIsRejectedInsteadOfBuffered() async throws {
        let server = LocalEventServer(preferredPort: 37_874)
        server.start()
        defer { server.stop() }
        let port = try await waitForServer(server)

        let body = String(repeating: "x", count: 700 * 1024)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-oversize-\(UUID().uuidString).json")
        try Data(body.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--silent", "--show-error", "--max-time", "3",
            "-X", "POST", "-H", "Content-Type: application/json",
            "--data-binary", "@\(file.path)",
            "http://127.0.0.1:\(port)/state?event=UserPromptSubmit&agent=claude-code"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0, "the server should close the connection instead of buffering 700 KiB")
    }

    private func waitForServer(_ server: LocalEventServer) async throws -> UInt16 {
        for _ in 0..<80 {
            if let response = try? curl(port: server.port, path: "/health"), response.status == 200 {
                return server.port
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("LocalEventServer did not become ready")
    }

    private func startRemoteIngress(_ server: LocalEventServer, nonce: String) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            server.startRemoteIngress(nonce: nonce) { result in
                switch result {
                case let .success(port): continuation.resume(returning: port)
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func curl(port: UInt16, path: String, body: String? = nil) throws -> (status: Int, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["--silent", "--show-error", "--max-time", "3", "-w", "\n%{http_code}"]
        if let body {
            arguments += ["-X", "POST", "-H", "Content-Type: application/json", "--data-binary", body]
        }
        arguments.append("http://127.0.0.1:\(port)\(path)")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ClawdeskTests", code: Int(process.terminationStatus))
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let split = text.lastIndex(of: "\n"), let status = Int(text[text.index(after: split)...]) else {
            throw NSError(domain: "ClawdeskTests", code: -1)
        }
        return (status, String(text[..<split]))
    }
}
