import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class ClawdeskModelSleepTests: XCTestCase {
    private func makeModel(
        timings: ThemeTimings? = nil,
        includeWakingAsset: Bool = true
    ) -> ClawdeskModel {
        let suite = "clawdesk-sleep-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdesk-sleep-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = AppPreferences(defaults: defaults, homeDirectory: root)
        if let timings {
            let source = root.appendingPathComponent("sleep-theme", isDirectory: true)
            try! FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let stateNames = timings.sleepMode == .direct
                ? ["idle", "sleeping"] + (includeWakingAsset ? ["waking"] : [])
                : ["idle", "yawning", "dozing", "collapsing", "sleeping"]
                    + (includeWakingAsset ? ["waking"] : [])
            let states = Dictionary(uniqueKeysWithValues: stateNames.map { ($0, "\($0).png") })
            var timingManifest: [String: Any] = [
                "mouseIdleTimeout": timings.mouseIdleTimeout * 1_000,
                "mouseSleepTimeout": timings.mouseSleepTimeout * 1_000,
                "yawnDuration": timings.yawnDuration * 1_000,
                "collapseDuration": timings.collapseDuration * 1_000,
                "wakeDuration": timings.wakeDuration * 1_000,
                "dizzyDuration": timings.dizzyDuration * 1_000,
                "deepSleepTimeout": timings.deepSleepTimeout * 1_000,
                "dndSkipYawn": timings.dndSkipYawn
            ]
            if let transitionFile = timings.dndSleepTransitionFile {
                timingManifest["dndSleepTransitionSvg"] = transitionFile
                timingManifest["dndSleepTransitionDuration"] = timings.dndSleepTransitionDuration * 1_000
            }
            let manifest: [String: Any] = [
                "id": "sleep-theme-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "name": "Sleep Theme",
                "sleepSequence": ["mode": timings.sleepMode.rawValue],
                "states": states,
                "timings": timingManifest
            ]
            let data = try! JSONSerialization.data(withJSONObject: manifest)
            try! data.write(to: source.appendingPathComponent("theme.json"))
            for state in stateNames {
                try! Data("placeholder".utf8).write(to: source.appendingPathComponent("\(state).png"))
            }
            if let transitionFile = timings.dndSleepTransitionFile {
                try! Data("placeholder".utf8).write(to: source.appendingPathComponent(transitionFile))
            }
            try! prefs.importTheme(from: source)
        }
        return ClawdeskModel(preferences: prefs)
    }

    func testDozesThenSleepsAfterMouseIdle() {
        let model = makeModel()
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)

        XCTAssertTrue(model.tickForSleep(now: now))
        XCTAssertEqual(model.petState.rawValue, "yawning")

        XCTAssertTrue(model.tickForSleep(now: now.addingTimeInterval(3)))
        XCTAssertEqual(model.petState, .dozing)

        XCTAssertFalse(model.tickForSleep(now: now.addingTimeInterval(538.9)))
        XCTAssertTrue(model.tickForSleep(now: now.addingTimeInterval(539)))
        XCTAssertEqual(model.petState.rawValue, "collapsing")

        XCTAssertTrue(model.tickForSleep(now: now.addingTimeInterval(540.1)))
        XCTAssertEqual(model.petState, .sleeping)
    }

    func testMouseActivityWakesWithWakingTransition() {
        let model = makeModel()
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)
        _ = model.tickForSleep(now: now)
        _ = model.tickForSleep(now: now.addingTimeInterval(3))
        _ = model.tickForSleep(now: now.addingTimeInterval(603))
        _ = model.tickForSleep(now: now.addingTimeInterval(604.1))
        XCTAssertEqual(model.petState, .sleeping)

        model.noteMouseActivity(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(model.petState, .waking)
    }

    func testMouseActivityWakesFromDozingWithShortEyeOpeningTransition() async {
        let model = makeModel()
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)
        _ = model.tickForSleep(now: now)
        _ = model.tickForSleep(now: now.addingTimeInterval(3))
        XCTAssertEqual(model.petState, .dozing)
        XCTAssertNotNil(model.dozingSince)

        model.noteMouseActivity(at: CGPoint(x: 20, y: 20))
        XCTAssertEqual(model.petState, .wakingFromDoze)
        XCTAssertNil(model.dozingSince)
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(model.petState, .idle)
    }

    func testDirectSleepThemeSkipsTheFullSequence() {
        let model = makeModel(timings: ThemeTimings(
            mouseSleepTimeout: 60,
            sleepMode: .direct
        ))
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)

        XCTAssertTrue(model.tickForSleep(now: now))
        XCTAssertEqual(model.petState, .sleeping)
    }

    func testDNDHonorsThemeSkipYawnAndWakesThroughConfiguredTransition() {
        let model = makeModel(timings: ThemeTimings(
            collapseDuration: 0.25,
            wakeDuration: 0.25,
            dndSkipYawn: true
        ))

        model.preferences.doNotDisturb = true
        XCTAssertEqual(model.petState, .collapsing)

        model.preferences.doNotDisturb = false
        XCTAssertEqual(model.petState, .waking)
    }

    func testDNDUsesDedicatedThemeTransitionDuration() async {
        let model = makeModel(timings: ThemeTimings(
            collapseDuration: 5,
            dndSleepTransitionFile: "dnd-transition.png",
            dndSleepTransitionDuration: 0.25,
            dndSkipYawn: true
        ))

        model.preferences.doNotDisturb = true
        XCTAssertEqual(model.petState, .collapsing)
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.petState, .sleeping)
    }

    func testDirectDNDReturnsStraightToIdle() {
        let model = makeModel(
            timings: ThemeTimings(sleepMode: .direct),
            includeWakingAsset: false
        )

        model.preferences.doNotDisturb = true
        XCTAssertEqual(model.petState, .sleeping)

        model.preferences.doNotDisturb = false
        XCTAssertEqual(model.petState, .idle)
    }

    func testDirectDNDUsesWakeAssetWhenTheThemeProvidesOne() {
        let model = makeModel(timings: ThemeTimings(sleepMode: .direct))

        model.preferences.doNotDisturb = true
        XCTAssertEqual(model.petState, .sleeping)

        model.preferences.doNotDisturb = false
        XCTAssertEqual(model.petState, .waking)
    }

    func testConfiguredWakeDurationReturnsToIdle() async {
        let model = makeModel(timings: ThemeTimings(
            mouseSleepTimeout: 1,
            wakeDuration: 0.25,
            sleepMode: .direct
        ))
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-2)
        _ = model.tickForSleep(now: now)
        XCTAssertEqual(model.petState, .sleeping)

        model.noteMouseActivity(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(model.petState, .waking)
        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.petState, .idle)
    }

    func testDirectThemeWithoutWakeAssetReturnsStraightToIdle() {
        let model = makeModel(
            timings: ThemeTimings(sleepMode: .direct),
            includeWakingAsset: false
        )
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-61)
        _ = model.tickForSleep(now: now)
        XCTAssertEqual(model.petState, .sleeping)

        model.noteMouseActivity(at: CGPoint(x: 12, y: 12))
        XCTAssertEqual(model.petState, .idle)
    }

    func testFullThemeKeepsWakingStateWhenCustomWakeAssetIsMissing() {
        let model = makeModel(
            timings: ThemeTimings(
                mouseSleepTimeout: 1,
                yawnDuration: 0.25,
                collapseDuration: 0.25,
                deepSleepTimeout: 1,
                sleepMode: .full
            ),
            includeWakingAsset: false
        )
        let now = Date()
        model.lastPointerActivity = now.addingTimeInterval(-1.1)
        _ = model.tickForSleep(now: now)
        _ = model.tickForSleep(now: now.addingTimeInterval(0.25))
        _ = model.tickForSleep(now: now.addingTimeInterval(0.5))
        XCTAssertEqual(model.petState, .sleeping)

        model.noteMouseActivity(at: CGPoint(x: 14, y: 14))
        XCTAssertEqual(model.petState, .waking)
    }

    func testThemeTimingsClampInvalidValuesToSafeBounds() {
        let timings = ThemeTimings(
            mouseIdleTimeout: .nan,
            mouseSleepTimeout: 0,
            yawnDuration: .infinity,
            collapseDuration: -10,
            wakeDuration: 0,
            deepSleepTimeout: 100_000
        )

        XCTAssertEqual(timings.mouseIdleTimeout, 20, accuracy: 0.001)
        XCTAssertEqual(timings.mouseSleepTimeout, 1, accuracy: 0.001)
        XCTAssertEqual(timings.yawnDuration, 3, accuracy: 0.001)
        XCTAssertEqual(timings.collapseDuration, 0, accuracy: 0.001)
        XCTAssertEqual(timings.wakeDuration, 0.25, accuracy: 0.001)
        XCTAssertEqual(timings.deepSleepTimeout, 86_400, accuracy: 0.001)
    }

    func testCursorDizzyReactionReturnsToIdleAfterThemeDuration() async {
        let model = makeModel(timings: ThemeTimings(dizzyDuration: 0.25))

        model.triggerDizzy()
        XCTAssertEqual(model.petState, .dizzy)

        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.petState, .idle)
    }

    func testAgentEventInterruptsCursorDizzyReaction() async {
        let model = makeModel(timings: ThemeTimings(dizzyDuration: 0.25))

        model.triggerDizzy()
        XCTAssertEqual(model.petState, .dizzy)
        model.accept(AgentEvent(sessionID: "working", eventName: "PreToolUse"))
        XCTAssertEqual(model.petState, .typing)

        try? await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.petState, .typing)
    }
}
