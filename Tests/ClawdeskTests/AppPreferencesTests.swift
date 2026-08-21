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
}
