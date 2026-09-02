import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class SettingsViewTests: XCTestCase {
    func testGeneralSettingsObservesPreferencesForLivePetSizeLabel() {
        let suite = "clawdesk-settings-view-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = AppPreferences(
            defaults: defaults,
            homeDirectory: FileManager.default.temporaryDirectory
        )
        let model = ClawdeskModel(preferences: preferences)
        let view = GeneralSettingsView(model: model)

        let storedPropertyLabels = Mirror(reflecting: view).children.compactMap(\.label)
        XCTAssertTrue(
            storedPropertyLabels.contains("_prefs"),
            "The settings view must observe AppPreferences so the percentage label redraws when the slider changes."
        )
    }
}
