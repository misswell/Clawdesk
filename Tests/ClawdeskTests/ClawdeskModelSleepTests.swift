import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class ClawdeskModelSleepTests: XCTestCase {
    private func makeModel() -> ClawdeskModel {
        let suite = "clawdesk-sleep-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = AppPreferences(defaults: defaults, homeDirectory: FileManager.default.temporaryDirectory)
        return ClawdeskModel(preferences: prefs)
    }

    func testDozesThenSleepsAfterMouseIdle() {
        let model = makeModel()
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)

        XCTAssertTrue(model.tickForSleep(now: now))
        XCTAssertEqual(model.petState, .dozing)

        XCTAssertTrue(model.tickForSleep(now: now.addingTimeInterval(30)))
        XCTAssertEqual(model.petState, .sleeping)
    }

    func testMouseActivityWakesWithWakingTransition() {
        let model = makeModel()
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)
        _ = model.tickForSleep(now: now)
        _ = model.tickForSleep(now: now.addingTimeInterval(30))
        XCTAssertEqual(model.petState, .sleeping)

        model.noteMouseActivity(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(model.petState, .waking)
    }

    func testMouseActivityWakesFromDozingToo() {
        let model = makeModel()
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)
        _ = model.tickForSleep(now: now)
        XCTAssertEqual(model.petState, .dozing)
        XCTAssertNotNil(model.dozingSince)

        model.noteMouseActivity(at: CGPoint(x: 20, y: 20))
        XCTAssertEqual(model.petState, .waking)
        XCTAssertNil(model.dozingSince)
    }
}
