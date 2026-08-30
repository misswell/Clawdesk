import Foundation
import XCTest
@testable import Clawdesk

final class BloubMotionTests: XCTestCase {
    func testPointerTargetUsesAbsoluteBloubAngles() {
        // The desktop cone centers on forward, eyes upright, and sweeps wide
        // enough that the capsules slide to the limb in all four directions.
        // A power curve (< 1) keeps small cursor moves responsive.
        let center = BloubMotion.targetGaze(normalizedX: 0, normalizedY: 0)
        XCTAssertEqual(center.yaw, 0, accuracy: 0.0001)
        XCTAssertEqual(center.pitch, 8, accuracy: 0.0001)
        XCTAssertEqual(center.roll, 0, accuracy: 0.0001)

        // Full deflection reaches the amplitudes exactly (curve(±1) = ±1).
        let topRight = BloubMotion.targetGaze(normalizedX: 1, normalizedY: -1)
        XCTAssertEqual(topRight.yaw, 45, accuracy: 0.0001)
        XCTAssertEqual(topRight.pitch, 46, accuracy: 0.0001)

        let bottomLeft = BloubMotion.targetGaze(normalizedX: -1, normalizedY: 1)
        XCTAssertEqual(bottomLeft.yaw, -45, accuracy: 0.0001)
        XCTAssertEqual(bottomLeft.pitch, -30, accuracy: 0.0001)

        // Small offsets are amplified, not ignored: a 10 % move yields a
        // clearly visible quarter of the full sweep.
        let small = BloubMotion.targetGaze(normalizedX: 0.1, normalizedY: 0)
        XCTAssertEqual(small.yaw, 45 * pow(0.1, 0.65), accuracy: 0.01)
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
    }}
