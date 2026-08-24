import Foundation
import XCTest
@testable import Clawdesk

final class BloubMotionTests: XCTestCase {
    func testPointerTargetUsesAbsoluteBloubAngles() {
        let center = BloubMotion.targetGaze(normalizedX: 0, normalizedY: 0)
        XCTAssertEqual(center.yaw, -26, accuracy: 0.0001)
        XCTAssertEqual(center.pitch, 10, accuracy: 0.0001)

        let topRight = BloubMotion.targetGaze(normalizedX: 1, normalizedY: -1)
        XCTAssertEqual(topRight.yaw, -10, accuracy: 0.0001)
        XCTAssertEqual(topRight.pitch, 23, accuracy: 0.0001)
    }

    func testLivelinessIsDeterministicAndCanBeDisabledForPointerTracking() {
        let first = BloubMotion.liveliness(at: 17.25)
        let second = BloubMotion.liveliness(at: 17.25)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first.dYaw, 0)
        XCTAssertNotEqual(first.dPitch, 0)

        let still = BloubMotion.liveliness(at: 17.25, wander: 0, blink: false, float: false)
        XCTAssertEqual(still.dYaw, 0, accuracy: 0.0001)
        XCTAssertEqual(still.dPitch, 0, accuracy: 0.0001)
        XCTAssertEqual(still.dRoll, 0, accuracy: 0.0001)
        XCTAssertEqual(still.lid, 1, accuracy: 0.0001)
        XCTAssertEqual(still.driftX, 0, accuracy: 0.0001)
        XCTAssertEqual(still.driftY, 0, accuracy: 0.0001)
        XCTAssertEqual(still.breath, 1, accuracy: 0.0001)
    }

    func testBlinkCalendarHasMeasuredCloseAndOpenShape() {
        let start = 1.4
        XCTAssertEqual(BloubMotion.blinkLid(at: start), 1, accuracy: 0.0001)
        XCTAssertEqual(BloubMotion.blinkLid(at: start + 0.18 * 0.45), 0, accuracy: 0.0001)
        XCTAssertEqual(BloubMotion.blinkLid(at: start + 0.18), 1, accuracy: 0.0001)
    }

    func testGazeMorphStartsFromCurrentRenderedValueWhenTargetChanges() {
        var morph = BloubGazeMorph(duration: 0.24)
        morph.setTarget(CGPoint(x: 5, y: -4))
        morph.advance(by: 0.12)
        let current = morph.value

        morph.setTarget(CGPoint(x: -5, y: 4))
        XCTAssertEqual(morph.value.x, current.x, accuracy: 0.0001)
        XCTAssertEqual(morph.value.y, current.y, accuracy: 0.0001)

        morph.advance(by: 0.24)
        XCTAssertEqual(morph.value.x, -5, accuracy: 0.0001)
        XCTAssertEqual(morph.value.y, 4, accuracy: 0.0001)
    }
}
