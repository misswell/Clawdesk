import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class AgentDoctorTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-doctor-\(UUID().uuidString)")
    }

    private func report(_ reports: [AgentDiagnostic], _ id: String) -> AgentDiagnostic? {
        reports.first { $0.agentID == id }
    }

    func testClaudeInstallReportsHealthy() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.installClaudeHooks(port: 37_830)

        let reports = AgentDoctor(installer: installer).diagnose()
        XCTAssertEqual(report(reports, "claude-code")?.state, .ok)
    }

    func testMissingConfigReportsNotInstalled() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        let reports = AgentDoctor(installer: installer).diagnose()
        XCTAssertEqual(report(reports, "claude-code")?.state, .notInstalled)
    }

    func testConfigWithoutManagedHooksIsFixable() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexDirectory = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hooks": [:]]).write(to: codexDirectory.appendingPathComponent("hooks.json"))

        let installer = HookInstaller(homeDirectory: root)
        let reports = AgentDoctor(installer: installer).diagnose()
        XCTAssertEqual(report(reports, "codex")?.state, .fixable)

        _ = try installer.installCodexHooks(port: 37_831)
        let after = AgentDoctor(installer: installer).diagnose()
        XCTAssertEqual(report(after, "codex")?.state, .ok)
    }

    func testPluginOnlyAgentIsNotChecked() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        let reports = AgentDoctor(installer: installer).diagnose()
        XCTAssertEqual(report(reports, "pi")?.state, .notChecked)
    }
}
