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

    func testManagedAgentIDsUseOwnershipMarkersAndIncludePluginDirectories() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = HookInstaller(homeDirectory: root)
        let doctor = AgentDoctor(installer: installer)

        let unrelatedDirectory = root.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        try Data(#"{"note":"clawdesk is mentioned but not installed"}"#.utf8)
            .write(to: unrelatedDirectory.appendingPathComponent("settings.json"))
        XCTAssertTrue(doctor.managedAgentIDs().isEmpty)

        _ = try installer.install(agentID: "claude-code", port: 37_832)
        _ = try installer.install(agentID: "pi", port: 37_832)

        XCTAssertEqual(doctor.managedAgentIDs(), ["claude-code", "pi"])
    }

    func testSystemChecksCoverUpstreamDoctorBreadth() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let doctor = AgentDoctor(installer: HookInstaller(homeDirectory: root))
        let healthy = SystemCheckInputs(
            serverResponding: true,
            serverPort: 37_777,
            preferencesReadable: true,
            themeID: "pinch",
            themeStateCount: 12,
            permissionBubblesEnabled: true,
            permissionAutomationOff: true,
            remoteChannels: nil,
            remoteSSHProfileCount: 0,
            remoteSSHIngressActive: false
        )
        let checks = doctor.diagnoseSystem(healthy)
        let ids = checks.map(\.id)
        // Upstream's doctor runs eight checks; these are the macOS ones.
        XCTAssertEqual(Set(ids), ["prefs", "local-server", "permission-bubble-policy",
                                  "feishu-approval", "theme-health", "remote-ssh-ingress",
                                  "remote-ssh-isolation"])
        XCTAssertTrue(checks.allSatisfy { $0.state == .ok || $0.state == .notApplicable })

        // A dead server fails loudly, bubbles-off without any remote channel
        // and without automation warns, and a broken theme warns.
        var broken = healthy
        broken.serverResponding = false
        broken.permissionBubblesEnabled = false
        broken.themeStateCount = 0
        let problems = doctor.diagnoseSystem(broken)
        XCTAssertEqual(problems.first { $0.id == "local-server" }?.state, .fail)
        XCTAssertEqual(problems.first { $0.id == "permission-bubble-policy" }?.state, .warn)
        XCTAssertEqual(problems.first { $0.id == "theme-health" }?.state, .warn)
    }

    func testDiagnosticReportRedactsHomePaths() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let doctor = AgentDoctor(installer: HookInstaller(homeDirectory: root))
        let report = doctor.diagnosticReport(
            agentDiagnostics: [
                AgentDiagnostic(agentID: "claude-code", displayName: "Claude Code", state: .ok, message: "Healthy.")
            ],
            systemDiagnostics: [
                SystemDiagnostic(id: "local-server", displayName: "Local event server", state: .ok, message: "Listening on 127.0.0.1:37777.")
            ],
            appVersion: "0.1.38"
        )
        XCTAssertTrue(report.contains("# Clawdesk diagnostic report"))
        XCTAssertTrue(report.contains("Claude Code"))
        XCTAssertFalse(report.contains("/Users/"), "absolute home paths must be redacted")
    }
}
