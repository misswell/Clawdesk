import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class RemoteSSHTests: XCTestCase {
    private nonisolated(unsafe) var root: URL!
    private nonisolated(unsafe) var manager: RemoteSSHManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdesk-ssh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let testManager = MainActor.assumeIsolated {
            RemoteSSHManager(
                eventServer: LocalEventServer(preferredPort: 37777),
                homeDirectory: testRoot
            )
        }
        root = testRoot
        manager = testManager
    }

    override func tearDown() {
        let testManager = manager
        let testRoot = root
        MainActor.assumeIsolated { testManager?.stop() }
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        manager = nil
        root = nil
        super.tearDown()
    }

    func testProfilePersistsWithoutStoringCredentials() throws {
        let profile = RemoteSSHProfile(
            label: "Codespace",
            host: "user@example.test",
            identityFile: "/tmp/id_ed25519",
            hostPrefix: "codespace",
            transportMode: .singleSession,
            autoStartCodexFallback: true
        )
        try manager.add(profile)

        let data = try Data(contentsOf: manager.configurationURL)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("user@example.test"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertEqual(manager.profiles.first?.id, profile.id)
        XCTAssertEqual(manager.statuses[profile.id], .idle)
        XCTAssertEqual(manager.profiles.first?.transportMode, .singleSession)
        XCTAssertTrue(manager.profiles.first?.autoStartCodexFallback == true)
    }

    func testRejectsInvalidRemoteForwardPort() {
        let profile = RemoteSSHProfile(host: "example.test", remoteForwardPort: 80)
        XCTAssertThrowsError(try manager.add(profile)) { error in
            XCTAssertEqual(error as? RemoteSSHError, .invalidProfile)
        }
    }

    func testRejectsUnsafeProfileIdentifier() {
        let profile = RemoteSSHProfile(id: "../../escape", host: "example.test")
        XCTAssertThrowsError(try manager.add(profile)) { error in
            XCTAssertEqual(error as? RemoteSSHError, .invalidProfile)
        }
    }

    func testRemoteInstallerPinsEventsAndRepairsManagedEntries() throws {
        let profile = RemoteSSHProfile(
            id: "profile-1",
            host: "example.test",
            remoteForwardPort: 23_333,
            routingNonce: String(repeating: "b", count: 32)
        )
        let installer = try manager.remoteInstallerForTesting(profile)
        let remoteHome = root.appendingPathComponent("remote-home", isDirectory: true)
        let claude = remoteHome.appendingPathComponent(".claude", isDirectory: true)
        let codex = remoteHome.appendingPathComponent(".codex", isDirectory: true)
        let copilot = remoteHome.appendingPathComponent(".copilot/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copilot, withIntermediateDirectories: true)
        try Data("{\"hooks\":{\"SessionStart\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"keep-me\"}]}]}}".utf8)
            .write(to: claude.appendingPathComponent("settings.json"), options: .atomic)
        try Data("{\"hooks\":{}}".utf8)
            .write(to: codex.appendingPathComponent("hooks.json"), options: .atomic)
        try Data("{\"hooks\":{}}".utf8)
            .write(to: copilot.appendingPathComponent("hooks.json"), options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = remoteHome.path
        process.environment = environment
        let input = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(installer.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))

        let settings = try jsonObject(at: claude.appendingPathComponent("settings.json"))
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let sessionCommands = sessionStart
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(sessionCommands.contains { $0.hasSuffix("profile-1.sh SessionStart claude-code") })
        let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let permissionURLs = permission
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["url"] as? String }
        XCTAssertTrue(permissionURLs.contains { $0.contains("127.0.0.1:23333") && $0.contains(String(repeating: "b", count: 32)) })

        let codexHooks = try jsonObject(at: codex.appendingPathComponent("hooks.json"))
        let codexEntries = try XCTUnwrap(codexHooks["hooks"] as? [String: Any])
        let permissionEntries = try XCTUnwrap(codexEntries["PermissionRequest"] as? [[String: Any]])
        let codexCommands = permissionEntries
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(codexCommands.contains { $0.hasSuffix("profile-1.sh PermissionRequest codex") })
        let copilotHooks = try jsonObject(at: copilot.appendingPathComponent("hooks.json"))
        let copilotEntries = try XCTUnwrap(copilotHooks["hooks"] as? [String: Any])
        let copilotStart = try XCTUnwrap(copilotEntries["sessionStart"] as? [[String: Any]])
        XCTAssertTrue(copilotStart.contains { ($0["bash"] as? String)?.hasSuffix("profile-1.sh sessionStart copilot-cli") == true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.appendingPathComponent("settings.json.clawdesk-backup.json").path))
    }

    func testDeploymentCommandUsesRemoteNodeForPortableBase64Decode() throws {
        let profile = RemoteSSHProfile(
            id: "profile-1",
            host: "example.test",
            routingNonce: String(repeating: "c", count: 32)
        )
        let command = try manager.deploymentCommandForTesting(profile)
        XCTAssertTrue(command.contains("node -e"))
        XCTAssertTrue(command.contains("$HOME/.clawdesk/hooks/clawdesk-profile-1.sh"))
        XCTAssertTrue(command.contains("installer.js"))
        XCTAssertTrue(command.contains("codex-remote-monitor-profile-1.js"))
        XCTAssertFalse(command.contains("base64 -d"))
    }

    func testRemoteFallbackMonitorIsValidNodeAndDoesNotForwardTranscript() throws {
        let profile = RemoteSSHProfile(
            id: "profile-1",
            host: "example.test",
            routingNonce: String(repeating: "d", count: 32)
        )
        let source = try manager.remoteMonitorForTesting(profile)
        XCTAssertTrue(source.contains("subagent_count"))
        XCTAssertFalse(source.contains("transcript"))
        let file = root.appendingPathComponent("monitor.js")
        try Data(source.utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--check", file.path]
        process.standardOutput = Pipe()
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testConnectRequiresDeploymentStamp() throws {
        let profile = RemoteSSHProfile(host: "example.test")
        try manager.add(profile)

        manager.connect(id: profile.id)

        XCTAssertEqual(manager.statuses[profile.id], .failed)
        XCTAssertEqual(manager.messages[profile.id], RemoteSSHError.deploymentRequired.localizedDescription)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
