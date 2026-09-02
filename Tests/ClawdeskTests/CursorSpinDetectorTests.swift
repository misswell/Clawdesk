import CoreGraphics
import XCTest
@testable import Clawdesk

final class CursorSpinDetectorTests: XCTestCase {
    private let center = CGPoint.zero

    private func point(angle: CGFloat, radius: CGFloat = 100) -> CGPoint {
        CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    private func completeTwoTurns(
        detector: inout CursorSpinDetector,
        start: TimeInterval = 0,
        stepCount: Int = 32
    ) -> Bool {
        _ = detector.sample(cursor: point(angle: 0), center: center, at: start)
        var triggered = false
        for index in 1...stepCount {
            let angle = CGFloat(index) * (.pi * 4 / CGFloat(stepCount))
            triggered = detector.sample(
                cursor: point(angle: angle),
                center: center,
                at: start + Double(index) * 0.05
            ) || triggered
        }
        return triggered
    }

    func testTwoContinuousTurnsTriggerDizzy() {
        var detector = CursorSpinDetector()

        XCTAssertTrue(completeTwoTurns(detector: &detector))
    }

    func testPauseResetsAccumulatedTurns() {
        var detector = CursorSpinDetector()
        _ = detector.sample(cursor: point(angle: 0), center: center, at: 0)
        _ = detector.sample(cursor: point(angle: .pi * 1.5), center: center, at: 0.1)

        // The 600 ms gap is longer than the 500 ms gesture continuity window.
        XCTAssertFalse(detector.sample(cursor: point(angle: .pi * 1.75), center: center, at: 0.7))
        for index in 1...16 {
            let angle = .pi * 1.75 + CGFloat(index) * (.pi * 2 / 16)
            XCTAssertFalse(
                detector.sample(cursor: point(angle: angle), center: center, at: 0.7 + Double(index) * 0.05)
            )
        }
    }

    func testNearCenterMovementDoesNotCountAndResetsGesture() {
        var detector = CursorSpinDetector()
        _ = detector.sample(cursor: point(angle: 0), center: center, at: 0)
        _ = detector.sample(cursor: point(angle: .pi, radius: 100), center: center, at: 0.1)

        // A sample inside the 24 px dead zone breaks the gesture chain.
        XCTAssertFalse(detector.sample(cursor: point(angle: .pi / 2, radius: 10), center: center, at: 0.2))
        for index in 0...32 {
            let angle = CGFloat(index) * (.pi * 2 / 32)
            XCTAssertFalse(
                detector.sample(cursor: point(angle: angle), center: center, at: 0.25 + Double(index) * 0.05)
            )
        }
    }

    func testEligibilityResetAndCooldownRequireAFreshGesture() {
        var detector = CursorSpinDetector()
        XCTAssertTrue(completeTwoTurns(detector: &detector))
        XCTAssertTrue(detector.isCoolingDown(at: 2))
        XCTAssertFalse(detector.isCoolingDown(at: 14))

        // The detector is inert while a non-idle or mini state is active.
        for index in 0...32 {
            let angle = CGFloat(index) * (.pi * 4 / 32)
            XCTAssertFalse(
                detector.sample(
                    cursor: point(angle: angle),
                    center: center,
                    at: 1.7 + Double(index) * 0.05,
                    enabled: false
                )
            )
        }

        // The 12-second cooldown suppresses a complete gesture.
        XCTAssertFalse(completeTwoTurns(detector: &detector, start: 2))

        // After cooldown, the first gesture only arms the detector. It must
        // not inherit any angle or accumulated turn from the old gesture.
        XCTAssertFalse(completeTwoTurns(detector: &detector, start: 13))
        XCTAssertTrue(completeTwoTurns(detector: &detector, start: 17))
    }

    func testStationaryPollingDoesNotKeepAGestureAlive() {
        var detector = CursorSpinDetector()
        _ = detector.sample(cursor: point(angle: 0), center: center, at: 0)
        _ = detector.sample(cursor: point(angle: .pi), center: center, at: 0.1)

        // A polling heartbeat at the same coordinate must not move the
        // continuity window forward. The next moving sample is therefore the
        // first sample of a fresh gesture after the 500 ms pause.
        XCTAssertFalse(detector.sample(cursor: point(angle: .pi), center: center, at: 0.8))
        for index in 1...24 {
            let angle = .pi + CGFloat(index) * (.pi * 3 / 24)
            XCTAssertFalse(
                detector.sample(
                    cursor: point(angle: angle),
                    center: center,
                    at: 0.85 + Double(index) * 0.05
                )
            )
        }
    }
}
