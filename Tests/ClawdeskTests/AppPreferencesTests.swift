import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class AppPreferencesTests: XCTestCase {
    private func makePreferences(suite: String, language: String? = nil, petScale: Double? = nil) -> AppPreferences {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let language { defaults.set(language, forKey: "language") }
        if let petScale { defaults.set(petScale, forKey: "petScale") }
        return AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
    }

    func testLanguageSwitchReturnsTranslatedText() {
        let prefs = makePreferences(suite: "clawdesk-lang-test-\(UUID().uuidString)")
        prefs.language = "zh-Hans"
        XCTAssertEqual(prefs.text("Theme"), "主题")
        XCTAssertEqual(prefs.text("General"), "通用")
        XCTAssertEqual(prefs.text("Sessions"), "会话")
        XCTAssertEqual(prefs.text("Install"), "安装")
        XCTAssertEqual(prefs.text("Local bridge"), "本地桥接")
        XCTAssertEqual(prefs.text("Connect"), "连接")
        prefs.language = "ja"
        XCTAssertEqual(prefs.text("Settings…"), "設定…")
        prefs.language = "es"
        XCTAssertEqual(prefs.text("Open Dashboard"), "Abrir panel")
    }

    func testUnsupportedLanguageAndUnknownKeyFallBackToEnglish() {
        let prefs = makePreferences(suite: "clawdesk-lang-fallback-test-\(UUID().uuidString)")
        prefs.language = "fr"
        XCTAssertEqual(prefs.text("Theme"), "Theme")
        XCTAssertEqual(prefs.text("no-such-key"), "no-such-key")
    }

    func testPetScaleDefaultsToOneAndPersists() {
        let suite = "clawdesk-scale-test-\(UUID().uuidString)"
        let prefs = makePreferences(suite: suite)
        XCTAssertEqual(prefs.petScale, 1.0)
        prefs.petScale = 1.5

        let defaults = UserDefaults(suiteName: suite)!
        let reloaded = AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(reloaded.petScale, 1.5, accuracy: 0.001)
    }

    func testPetScaleIsClampedOnLoad() {
        let high = makePreferences(suite: "clawdesk-scale-high-\(UUID().uuidString)", petScale: 5.0)
        XCTAssertEqual(high.petScale, 2.0)
        let low = makePreferences(suite: "clawdesk-scale-low-\(UUID().uuidString)", petScale: 0.05)
        XCTAssertEqual(low.petScale, 0.4)
    }

    func testSessionHUDDefaultsAndPersists() {
        let suite = "clawdesk-session-hud-" + UUID().uuidString
        let prefs = makePreferences(suite: suite)
        XCTAssertTrue(prefs.sessionHUDEnabled)
        XCTAssertFalse(prefs.sessionHUDPinned)
        XCTAssertTrue(prefs.sessionHUDShowContextUsage)

        prefs.sessionHUDEnabled = false
        prefs.sessionHUDPinned = true
        prefs.sessionHUDShowContextUsage = false

        let defaults = UserDefaults(suiteName: suite)!
        let reloaded = AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
        XCTAssertFalse(reloaded.sessionHUDEnabled)
        XCTAssertTrue(reloaded.sessionHUDPinned)
        XCTAssertFalse(reloaded.sessionHUDShowContextUsage)
    }

    func testPermissionAutomationDefaultsOffAndPersists() {
        let suite = "clawdesk-automation-\(UUID().uuidString)"
        let prefs = makePreferences(suite: suite)
        XCTAssertEqual(prefs.permissionAutomation, .off)
        prefs.permissionAutomation = .autoTools

        let defaults = UserDefaults(suiteName: suite)!
        let reloaded = AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(reloaded.permissionAutomation, .autoTools)
    }

    func testEnabledAgentIDsPersistAsSortedUserDefaultsValues() {
        let suite = "clawdesk-enabled-agents-\(UUID().uuidString)"
        let prefs = makePreferences(suite: suite)
        prefs.enabledAgentIDs = ["codex", "claude-code"]

        let defaults = UserDefaults(suiteName: suite)!
        XCTAssertEqual(defaults.stringArray(forKey: "enabledAgentIDs"), ["claude-code", "codex"])

        let reloaded = AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(reloaded.enabledAgentIDs, ["claude-code", "codex"])
    }

    func testWindowOriginsPersistIncludingParkedPreMiniSpot() {
        let suite = "clawdesk-position-memory-\(UUID().uuidString)"
        let prefs = makePreferences(suite: suite)
        prefs.windowOrigin = CGPoint(x: 640, y: 220)
        prefs.preMiniWindowOrigin = CGPoint(x: 1280, y: 480)

        let defaults = UserDefaults(suiteName: suite)!
        let reloaded = AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(reloaded.windowOrigin, CGPoint(x: 640, y: 220))
        XCTAssertEqual(reloaded.preMiniWindowOrigin, CGPoint(x: 1280, y: 480))

        // Clearing the parked spot persists too (mini round-trip finished).
        reloaded.preMiniWindowOrigin = nil
        let cleared = AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
        XCTAssertNil(cleared.preMiniWindowOrigin)
    }
}
