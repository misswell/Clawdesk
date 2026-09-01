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

    func testSavedPetPositionSurvivesWindowControllerStartup() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = makePreferences(home: root)
        let savedOrigin = CGPoint(x: 640, y: 220)
        preferences.windowOrigin = savedOrigin
        XCTAssertEqual(preferences.windowOrigin, savedOrigin)
        let model = ClawdeskModel(preferences: preferences)
        let controller = PetWindowController(model: model)
        defer { controller.stop() }

        controller.start()

        XCTAssertEqual(controller.window?.frame.origin, savedOrigin)
        XCTAssertEqual(preferences.windowOrigin, savedOrigin)
    }

    func testSavedPetPositionSurvivesDelayedStartupWindowCallbacks() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = makePreferences(home: root)
        let savedOrigin = CGPoint(x: 640, y: 220)
        preferences.windowOrigin = savedOrigin
        let model = ClawdeskModel(preferences: preferences)
        let controller = PetWindowController(model: model)
        defer { controller.stop() }

        controller.start()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(controller.window?.frame.origin, savedOrigin)
        XCTAssertEqual(preferences.windowOrigin, savedOrigin)
    }

    func testSavedMiniPetPositionSurvivesWindowControllerStartup() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = makePreferences(home: root)
        let savedOrigin = CGPoint(x: 640, y: 220)
        preferences.isMiniMode = true
        preferences.windowOrigin = savedOrigin
        XCTAssertEqual(preferences.windowOrigin, savedOrigin)
        let model = ClawdeskModel(preferences: preferences)
        let controller = PetWindowController(model: model)
        defer { controller.stop() }

        controller.start()

        XCTAssertEqual(controller.window?.frame.origin, savedOrigin)
        XCTAssertEqual(preferences.windowOrigin, savedOrigin)
    }

    func testMiniWindowPositionIsPersistedWhenTheWindowMovesAndStops() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "clawdesk-mini-position-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        preferences.isMiniMode = true
        preferences.windowOrigin = CGPoint(x: 640, y: 220)

        let model = ClawdeskModel(preferences: preferences)
        let controller = PetWindowController(model: model)
        controller.start()

        let movedOrigin = CGPoint(x: 1_420, y: 560)
        controller.window?.setFrameOrigin(movedOrigin)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: controller.window))
        controller.stop()

        let reloaded = AppPreferences(defaults: defaults, homeDirectory: root)
        XCTAssertEqual(reloaded.windowOrigin, movedOrigin)
    }

    func testStaleStartupParkedOriginCannotResetPetToLowerLeft() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = makePreferences(home: root)
        let savedOrigin = CGPoint(x: 640, y: 220)
        preferences.isMiniMode = true
        preferences.windowOrigin = savedOrigin
        // Versions before the startup guard could write the initial panel
        // frame (0, 0) into the parked normal-mode position.
        preferences.preMiniWindowOrigin = .zero

        let model = ClawdeskModel(preferences: preferences)
        let controller = PetWindowController(model: model)
        defer { controller.stop() }
        controller.start()

        controller.setMiniMode(false, animate: false)

        XCTAssertEqual(controller.window?.frame.origin, savedOrigin)
    }

    func testGeneratedCodexHookCommandReachesTheModelThroughShell() async throws {
        let root = makeRoot().appendingPathComponent("runtime hook with spaces", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "clawdesk-hook-e2e-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(defaults: defaults, homeDirectory: root)
        // Keep the test isolated from a developer's running Clawdesk on the
        // default 37777 bridge port.
        preferences.serverPort = 39_421
        let installer = HookInstaller(homeDirectory: root)
        let model = ClawdeskModel(preferences: preferences, hookInstaller: installer)
        model.start()
        defer { model.stop() }

        let port = try await waitForServer(model.eventServer)
        try installer.writeRuntimeFile(port: port)
        _ = try installer.installCodexHooks(port: port)

        let hooksURL = root.appendingPathComponent(".codex/hooks.json")
        let hooks = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        let eventEntries = ((hooks["hooks"] as! [String: Any])["UserPromptSubmit"] as! [[String: Any]])
        let command = try XCTUnwrap(
            eventEntries
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["command"] as? String }
                .first { $0.contains(HookInstaller.marker) }
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": root.path]) { _, new in new }
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"shell-e2e"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        for _ in 0..<80 where model.petState != .thinking {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(model.petState, .thinking)
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

    private func curl(port: UInt16, path: String) throws -> (status: Int, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--max-time", "3", "-w", "\n%{http_code}", "http://127.0.0.1:\(port)\(path)"]
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
