import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class ClaudeHookHealthTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-health-\(UUID().uuidString)")
    }

    private func readJSON(at url: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    func testReportsHealthyWhenScriptExists() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.installClaudeHooks(port: 37_820)

        let monitor = ClaudeHookHealthMonitor(installer: installer)
        monitor.check(port: 37_820)
        XCTAssertEqual(monitor.status, .healthy)
        XCTAssertEqual(monitor.consecutiveFailures, 0)
    }

    func testRepairsMissingScriptAndPreservesUserStatusLine() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.installClaudeHooks(port: 37_821)

        // A user-owned status line must survive the periodic repair.
        let settingsURL = root.appendingPathComponent(".claude/settings.json")
        var settings = readJSON(at: settingsURL)
        settings["statusLine"] = ["type": "command", "command": "echo user-status"]
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)

        try FileManager.default.removeItem(at: installer.hookScript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.hookScript.path))

        let monitor = ClaudeHookHealthMonitor(installer: installer)
        monitor.check(port: 37_821)

        XCTAssertEqual(monitor.status, .healthy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.hookScript.path))
        let restored = readJSON(at: settingsURL)
        XCTAssertEqual(((restored["statusLine"] as? [String: Any])?["command"] as? String), "echo user-status")
    }

    func testManualFixRequiredAfterThreeFailedRepairsAndRecovers() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.installClaudeHooks(port: 37_822)

        try FileManager.default.removeItem(at: installer.hookScript)
        let hooksDirectory = installer.hookScript.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hooksDirectory.path)

        let monitor = ClaudeHookHealthMonitor(installer: installer)
        monitor.check(port: 37_822)
        XCTAssertEqual(monitor.status, .repairing)
        monitor.check(port: 37_822)
        XCTAssertEqual(monitor.status, .repairing)
        monitor.check(port: 37_822)
        XCTAssertEqual(monitor.status, .manualFixRequired)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooksDirectory.path)
        monitor.check(port: 37_822)
        XCTAssertEqual(monitor.status, .healthy)
        XCTAssertEqual(monitor.consecutiveFailures, 0)
    }

    func testGuardedWithoutClaudeSettings() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        let monitor = ClaudeHookHealthMonitor(installer: installer)
        monitor.check(port: 37_823)
        XCTAssertEqual(monitor.status, .guarded)
    }
}
