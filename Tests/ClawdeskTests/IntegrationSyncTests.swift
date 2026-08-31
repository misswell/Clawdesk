import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class IntegrationSyncTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-sync-\(UUID().uuidString)")
    }

    private func makePreferences(home: URL) -> AppPreferences {
        let suite = "clawdesk-sync-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppPreferences(defaults: defaults, homeDirectory: home)
    }

    func testStartupRepairsExistingManagedIntegration() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.install(agentID: "claude-code", port: 37_833)
        try FileManager.default.removeItem(at: installer.hookScript)

        let model = ClawdeskModel(
            preferences: makePreferences(home: root),
            hookInstaller: installer
        )
        model.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        model.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.hookScript.path))
    }

    func testStartupCreatesOnlyAnExplicitlyEnabledIntegration() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        let preferences = makePreferences(home: root)
        preferences.enabledAgentIDs = ["pi"]
        let extensionDirectory = root.appendingPathComponent(".pi/agent/extensions/clawdesk", isDirectory: true)

        let model = ClawdeskModel(preferences: preferences, hookInstaller: installer)
        model.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        model.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionDirectory.appendingPathComponent(".clawdesk-managed.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
    }

    func testPublishedEventStateReachesPetCanvas() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ClawdeskModel(preferences: makePreferences(home: root))
        let controller = PetWindowController(model: model)
        defer { controller.stop() }

        model.accept(AgentEvent(
            sessionID: "pet-binding-session",
            agentID: "codex",
            eventName: "UserPromptSubmit"
        ))

        XCTAssertEqual(model.petState, .thinking)
        XCTAssertEqual((controller.window?.contentView as? PetCanvasView)?.petState, .thinking)
    }
}
