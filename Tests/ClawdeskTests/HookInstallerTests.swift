import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class HookInstallerTests: XCTestCase {
    func testClaudeInstallPreservesExistingHooksAndWritesRuntimeTransport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-hook-test-\(UUID().uuidString)")
        let claudeDirectory = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [["matcher": "", "hooks": [["type": "command", "command": "echo keep-me"]]]]
            ]
        ]
        let settingsData = try JSONSerialization.data(withJSONObject: settings)
        try settingsData.write(to: claudeDirectory.appendingPathComponent("settings.json"))

        let installer = HookInstaller(homeDirectory: root)
        try installer.writeRuntimeFile(port: 37801)
        let result = try installer.installClaudeHooks(port: 37801)

        XCTAssertTrue(result.changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.hookScript.path))
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeDirectory.appendingPathComponent("settings.json"))) as! [String: Any]
        let hooks = installed["hooks"] as! [String: Any]
        let sessionStart = hooks["SessionStart"] as! [[String: Any]]
        let commands = sessionStart.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("echo keep-me"))
        XCTAssertTrue(commands.contains { $0.contains(HookInstaller.marker) })
        XCTAssertTrue(String(data: try Data(contentsOf: installer.runtimeFile), encoding: .utf8)?.contains("37801") == true)
    }

    func testClaudeStatuslineIsOptInAndOwnedOnlyWhenSlotIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-statusline-test-\(UUID().uuidString)")
        let settingsURL = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "echo user-status"]])
            .write(to: settingsURL)

        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.installClaudeHooks(port: 37809)
        let preserved = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        XCTAssertEqual((preserved["statusLine"] as? [String: Any])?["command"] as? String, "echo user-status")

        // Plain hook install must NOT add a status line; collection is opt-in.
        try JSONSerialization.data(withJSONObject: [:]).write(to: settingsURL)
        _ = try installer.installClaudeHooks(port: 37809)
        let withoutOptIn = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        XCTAssertNil(withoutOptIn["statusLine"])

        // Explicit opt-in takes an empty slot and never replaces a custom one.
        _ = try installer.ensureClaudeStatusLine()
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        XCTAssertTrue(((installed["statusLine"] as? [String: Any])?["command"] as? String)?.contains("ClawdeskStatusline") == true)

        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "echo user-status"]]).write(to: settingsURL)
        _ = try installer.ensureClaudeStatusLine()
        let notReplaced = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        XCTAssertEqual(((notReplaced["statusLine"] as? [String: Any])?["command"] as? String), "echo user-status")

        _ = try installer.removeClaudeStatusLine()
        let kept = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        XCTAssertEqual(((kept["statusLine"] as? [String: Any])?["command"] as? String), "echo user-status")

        try JSONSerialization.data(withJSONObject: [:]).write(to: settingsURL)
        _ = try installer.ensureClaudeStatusLine()
        _ = try installer.uninstall(agentID: "claude-code")
        let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        XCTAssertNil(removed["statusLine"])
    }

    func testCodexInstallEnablesFeatureWithoutOverwritingExplicitFalse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-test-\(UUID().uuidString)")
        let codexDirectory = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try "[features]\nhooks = false\n".data(using: .utf8)?.write(to: codexDirectory.appendingPathComponent("config.toml"))

        let installer = HookInstaller(homeDirectory: root)
        let result = try installer.installCodexHooks(port: 37802)
        XCTAssertTrue(result.changed)
        let config = try String(contentsOf: codexDirectory.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("hooks = false"))
        let hooksData = try Data(contentsOf: codexDirectory.appendingPathComponent("hooks.json"))
        let hooks = try JSONSerialization.jsonObject(with: hooksData) as! [String: Any]
        XCTAssertNotNil(hooks["hooks"])
    }

    func testCodexInstallMergesIntoExistingFeaturesTableWithoutDuplicatingHeader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-codex-merge-test-\(UUID().uuidString)")
        let codexDirectory = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try "[features]\nmodel = \"gpt-5.3\"\n".data(using: .utf8)?.write(to: codexDirectory.appendingPathComponent("config.toml"))

        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.installCodexHooks(port: 37802)
        let config = try String(contentsOf: codexDirectory.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(config.components(separatedBy: "[features]").count - 1, 1)
        XCTAssertTrue(config.contains("hooks = true"))
        XCTAssertTrue(config.contains("model = \"gpt-5.3\""))
    }

    func testLegacyKimiHooksPersistAndPreservePermissionMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-kimi-hook-test-\(UUID().uuidString)")
        let configURL = root.appendingPathComponent(".kimi/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# user config\n".utf8).write(to: configURL)

        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.install(agentID: "kimi-cli", port: 37810)
        let first = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(first.contains("--permission-mode=suspect"))

        let explicit = first.replacingOccurrences(of: "--permission-mode=suspect", with: "--permission-mode=explicit")
        try Data(explicit.utf8).write(to: configURL)
        _ = try installer.install(agentID: "kimi-cli", port: 37810)
        let second = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(second.contains("--permission-mode=explicit"))
        XCTAssertTrue(second.contains("# user config"))
    }

    func testAdditionalJSONAdaptersAreIdempotentAndPreserveUserEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-extra-hook-test-\(UUID().uuidString)")
        let cursorDirectory = root.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursorDirectory, withIntermediateDirectories: true)
        let initial: [String: Any] = [
            "hooks": [
                "sessionStart": [["command": "echo keep-me"]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: initial).write(to: cursorDirectory.appendingPathComponent("hooks.json"))

        let installer = HookInstaller(homeDirectory: root)
        let first = try installer.install(agentID: "cursor-agent", port: 37803)
        let second = try installer.install(agentID: "cursor-agent", port: 37803)

        XCTAssertTrue(first.changed)
        XCTAssertFalse(second.changed)
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: cursorDirectory.appendingPathComponent("hooks.json"))) as! [String: Any]
        let hooks = installed["hooks"] as! [String: Any]
        let sessionStart = hooks["sessionStart"] as! [[String: Any]]
        XCTAssertTrue(sessionStart.contains { ($0["command"] as? String) == "echo keep-me" })
        XCTAssertTrue(sessionStart.contains { ($0["command"] as? String)?.contains(HookInstaller.marker) == true })
    }

    func testZCodeAdapterUsesNestedProcessHookAndUninstallKeepsUserHook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-zcode-hook-test-\(UUID().uuidString)")
        let configURL = root.appendingPathComponent(".zcode/cli/config.json")
        let initial: [String: Any] = [
            "hooks": [
                "events": [
                    "Stop": [["hooks": [["type": "process", "command": "echo keep-me", "args": []]]]]
                ]
            ]
        ]
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: initial).write(to: configURL)

        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.install(agentID: "zcode", port: 37804)
        let removed = try installer.uninstall(agentID: "zcode")

        XCTAssertTrue(removed.changed)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        let events = ((restored["hooks"] as! [String: Any])["events"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(((events[0]["hooks"] as! [[String: Any]])[0]["command"] as? String), "echo keep-me")
    }

    func testAllConfigAgentAdaptersHaveAnInstallPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-agent-adapter-test-\(UUID().uuidString)")
        let installer = HookInstaller(homeDirectory: root)
        for agentID in HookInstaller.supportedAgentIDs where agentID != "claude-code" && agentID != "codex" {
            XCTAssertNoThrow(try installer.install(agentID: agentID, port: 37805), "adapter: \(agentID)")
        }
    }

    func testPluginAdaptersPreserveJSONCAndOwnOnlyTheirOpenClawEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-plugin-adapter-test-\(UUID().uuidString)")
        let opencodeDirectory = root.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: opencodeDirectory, withIntermediateDirectories: true)
        let opencodeConfig = """
        {
          // Keep this comment while Clawdesk edits only plugin.
          "plugin": ["user-plugin"],
        }
        """
        try Data(opencodeConfig.utf8).write(to: opencodeDirectory.appendingPathComponent("opencode.jsonc"))

        let openclawDirectory = root.appendingPathComponent(".openclaw", isDirectory: true)
        try FileManager.default.createDirectory(at: openclawDirectory, withIntermediateDirectories: true)
        let openclawConfig: [String: Any] = [
            "plugins": [
                "load": ["paths": ["/user/plugin"]],
                "entries": ["user": ["enabled": true]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: openclawConfig).write(to: openclawDirectory.appendingPathComponent("openclaw.json"))

        let installer = HookInstaller(homeDirectory: root)
        let first = try installer.install(agentID: "opencode", port: 37806)
        XCTAssertTrue(first.changed)
        XCTAssertTrue(String(data: try Data(contentsOf: first.configPath), encoding: .utf8)?.contains("Keep this comment") == true)
        XCTAssertTrue(String(data: try Data(contentsOf: first.configPath), encoding: .utf8)?.contains("opencode-plugin") == true)
        XCTAssertFalse(try installer.install(agentID: "opencode", port: 37806).changed)
        XCTAssertTrue(try installer.uninstall(agentID: "opencode").changed)
        let restored = try String(contentsOf: first.configPath, encoding: .utf8)
        XCTAssertTrue(restored.contains("user-plugin"))
        XCTAssertTrue(restored.contains("Keep this comment"))

        let openclawInstall = try installer.install(agentID: "openclaw", port: 37806)
        XCTAssertTrue(openclawInstall.changed)
        let openclawInstalled = try JSONSerialization.jsonObject(with: Data(contentsOf: openclawInstall.configPath)) as! [String: Any]
        let plugins = openclawInstalled["plugins"] as! [String: Any]
        XCTAssertNotNil((plugins["entries"] as! [String: Any])["user"])
        XCTAssertNotNil((plugins["entries"] as! [String: Any])["clawdesk"])
        XCTAssertTrue(try installer.uninstall(agentID: "openclaw").changed)
        let openclawRestored = try JSONSerialization.jsonObject(with: Data(contentsOf: openclawInstall.configPath)) as! [String: Any]
        XCTAssertNotNil((((openclawRestored["plugins"] as! [String: Any])["entries"] as! [String: Any])["user"]))
    }

    func testPluginAdaptersReadTheCurrentRuntimePort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-plugin-port-test-\(UUID().uuidString)")
        let installer = HookInstaller(homeDirectory: root)
        try installer.writeRuntimeFile(port: 37807)

        _ = try installer.install(agentID: "opencode", port: 37807)
        _ = try installer.install(agentID: "openclaw", port: 37807)
        _ = try installer.install(agentID: "hermes", port: 37807)
        _ = try installer.install(agentID: "pi", port: 37807)
        _ = try installer.install(agentID: "deepseek-harness", port: 37807)

        let files: [(String, String)] = [
            (".clawdesk-opencode", "Library/Application Support/Clawdesk/plugins/opencode-plugin/index.mjs"),
            (".clawdesk-openclaw", "Library/Application Support/Clawdesk/plugins/openclaw-plugin/index.js"),
            (".clawdesk-hermes", ".hermes/plugins/clawdesk/__init__.py"),
            (".clawdesk-pi", ".pi/agent/extensions/clawdesk/index.ts"),
            (".clawdesk-deepseek", ".dsh/profiles/web/node_modules/@dsh-external/dsh-clawd-bridge/lib/index.js")
        ]

        for (label, relativePath) in files {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(source.contains("runtime.json"), "\(label) must read the runtime port")
        }

        let familySource = try String(contentsOf: root.appendingPathComponent("Library/Application Support/Clawdesk/plugins/opencode-plugin/index.mjs"), encoding: .utf8)
        XCTAssertTrue(familySource.contains("readFileSync"))
        XCTAssertFalse(familySource.contains("require(\"fs\")"))
        let hermesSource = try String(contentsOf: root.appendingPathComponent(".hermes/plugins/clawdesk/__init__.py"), encoding: .utf8)
        XCTAssertTrue(hermesSource.contains("_port()"))
    }

    func testPluginRemovalPreservesUserEntriesWhenManagedPathIsFirstInJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-plugin-json-remove-test-\(UUID().uuidString)")
        let configDirectory = root.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let pluginPath = root.appendingPathComponent("Library/Application Support/Clawdesk/plugins/opencode-plugin").path
        let initial: [String: Any] = ["plugin": [pluginPath, "user-plugin"]]
        let configURL = configDirectory.appendingPathComponent("opencode.json")
        try JSONSerialization.data(withJSONObject: initial).write(to: configURL)

        let installer = HookInstaller(homeDirectory: root)
        _ = try installer.install(agentID: "opencode", port: 37808)
        XCTAssertTrue(try installer.uninstall(agentID: "opencode").changed)

        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        XCTAssertEqual((restored["plugin"] as? [String]), ["user-plugin"])
    }
}
