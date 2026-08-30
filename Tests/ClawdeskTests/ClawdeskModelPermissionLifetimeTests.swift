import Foundation
import XCTest
@testable import Clawdesk

private final class PermissionDecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PermissionDecision] = [:]

    func record(_ decision: PermissionDecision, for id: String) {
        lock.lock()
        values[id] = decision
        lock.unlock()
    }

    func decision(for id: String) -> PermissionDecision? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }
}

@MainActor
final class ClawdeskModelPermissionLifetimeTests: XCTestCase {
    private func makeModel() -> ClawdeskModel {
        let suite = "clawdesk-permission-lifetime-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdesk-permission-lifetime-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        preferences.permissionMode = .askEveryTime
        preferences.permissionAutomation = .off
        preferences.showPermissionBubbles = true
        return ClawdeskModel(preferences: preferences)
    }

    private func submit(id: String, to model: ClawdeskModel, recorder: PermissionDecisionRecorder) {
        let request = PermissionRequest(
            id: id,
            sessionID: "session-\(id)",
            agentID: "codex",
            title: "Permission \(id)"
        )
        let event = AgentEvent(
            sessionID: request.sessionID,
            agentID: request.agentID,
            eventName: "PermissionRequest",
            permission: request
        )
        let reply = PermissionReply { decision in
            recorder.record(decision, for: id)
        }
        model.receive(.permission(event, reply))
    }

    func testPendingPermissionQueueDefersOldestBeyondLimit() {
        let model = makeModel()
        model.maximumPendingPermissionCount = 2
        let recorder = PermissionDecisionRecorder()

        submit(id: "one", to: model, recorder: recorder)
        submit(id: "two", to: model, recorder: recorder)
        submit(id: "three", to: model, recorder: recorder)

        XCTAssertEqual(recorder.decision(for: "one"), .defer)
        XCTAssertEqual(model.pendingPermissions.map(\.id), ["two", "three"])
        model.stop()
    }

    func testUnansweredPermissionExpiresAndReleasesReply() async throws {
        let model = makeModel()
        // Keep the timeout short while leaving enough scheduler slack for
        // loaded CI runners. A 20 ms wall-clock window can expire after the
        // test's assertion task even though the implementation is correct.
        model.permissionReplyTimeout = .milliseconds(100)
        let recorder = PermissionDecisionRecorder()

        submit(id: "expiring", to: model, recorder: recorder)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(recorder.decision(for: "expiring"), .defer)
        XCTAssertTrue(model.pendingPermissions.isEmpty)
        model.stop()
    }
}
