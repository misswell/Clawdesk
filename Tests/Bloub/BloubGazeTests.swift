import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Gaze contracts: the look target is an ABSOLUTE direction blended by the
/// engine (never by the caller), the catch-up starts from the currently
/// rendered value, and hostile input cannot poison the timeline.
final class BloubGazeTests: XCTestCase {
    func testLookReplacesThePoseGazeAbsolutely() {
        let engine = BloubEngine(radius: 100, initial: .wide)
        // wide poses its gaze at yaw 6.92 / pitch -21.96. mix=1 must replace
        // it, not offset it.
        engine.setLook(BloubLook(yaw: 40, pitch: 20, mix: 1, spin: 0, wander: 0), at: 0)
        let now = 3.0 // past the 0.24 s catch-up
        let frame = engine.sample(at: now)
        XCTAssertEqual(frame.eyes.count, 2)

        // The served gaze is exactly the target (wander off); roll never
        // follows the pointer. The float drift stays alive and is expected.
        let expected = BloubFace.eyePoses(
            gaze: BloubGaze(yaw: 40, pitch: 20, roll: 11.6),
            scale: 100,
            split: 18.43
        )
        let life = BloubMotion.liveliness(at: now, wander: 0, blink: true)
        XCTAssertEqual(frame.eyes[0].transform.tx, expected[0].x + CGFloat(life.driftX) * 100, accuracy: 1e-6)
        XCTAssertEqual(frame.eyes[0].transform.ty, expected[0].y + CGFloat(life.driftY) * 100, accuracy: 1e-6)
    }

    func testLookWithZeroMixKeepsTheStateGaze() {
        let engine = BloubEngine(radius: 100, initial: .wide)
        engine.setLook(BloubLook(yaw: 40, pitch: 20, mix: 0, spin: 0, wander: 0), at: 0)
        let frame = engine.sample(at: 3.0)
        let expected = BloubFace.eyePoses(
            gaze: BloubGaze(yaw: 6.92, pitch: -21.96, roll: 11.6),
            scale: 100,
            split: 18.43
        )
        let life = BloubMotion.liveliness(at: 3.0, wander: 0, blink: true)
        XCTAssertEqual(frame.eyes[0].transform.tx, expected[0].x + CGFloat(life.driftX) * 100, accuracy: 1e-6)
    }

    func testGazeCatchUpStartsFromTheRenderedValueNotThePreviousTarget() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setLook(BloubLook(yaw: 40, pitch: 0, mix: 1, spin: 0, wander: 0), at: 0.5)
        // A quick retarget mid catch-up. The blended value at the retarget is
        // (yaw 40·p, mix p); if the engine restarted from the old TARGET
        // instead of the rendered value, mix would already be 1 and the eyes
        // would jump.
        engine.setLook(BloubLook(yaw: -40, pitch: 0, mix: 1, spin: 0, wander: 0), at: 0.55)
        let frame = engine.sample(at: 0.55)

        // The retarget blends from the rendered value: carried look axes are
        // (yaw 40·p, mix p, wander 1-p), and the engine still adds the rest
        // life on top with that surviving wander.
        let progress = BloubMotion.easeOutQuint(0.05 / 0.24)
        let carriedYaw = BloubEase.lerp(0, 40, progress)
        let carriedMix = progress
        let carriedWander = BloubEase.lerp(1, 0, progress)
        let life = BloubMotion.liveliness(at: 0.55, wander: carriedWander, blink: true)
        let expectedGaze = BloubGaze(
            yaw: BloubEase.lerp(28.49, carriedYaw, carriedMix) + life.dYaw,
            pitch: BloubEase.lerp(28.62, 0, carriedMix) + life.dPitch,
            roll: -13 + life.dRoll
        )
        let expected = BloubFace.eyePoses(gaze: expectedGaze, scale: 100, split: BloubFace.eyeSplit)
        XCTAssertEqual(
            frame.eyes[0].transform.tx,
            expected[0].x + CGFloat(life.driftX) * 100,
            accuracy: 1e-4
        )
    }

    func testSpinMeltRedressesTheGazeOnArrival() {
        // A full turn melts to zero on arrival: -360° is the same angle as 0°,
        // so the settled gaze must land on the spin-free pose (within float
        // noise of the equivalent angle).
        let spinning = BloubEngine(radius: 100, initial: .idle)
        spinning.setLook(BloubLook(yaw: 10, pitch: 0, mix: 1, spin: -360, wander: 0), at: 0)
        let direct = BloubEngine(radius: 100, initial: .idle)
        direct.setLook(BloubLook(yaw: 10, pitch: 0, mix: 1, spin: 0, wander: 0), at: 0)
        let settled = spinning.sample(at: 3.0)
        let directFrame = direct.sample(at: 3.0)
        XCTAssertEqual(settled.eyes[0].transform.tx, directFrame.eyes[0].transform.tx, accuracy: 1e-6)
        XCTAssertEqual(settled.eyes[0].transform.ty, directFrame.eyes[0].transform.ty, accuracy: 1e-6)
        XCTAssertEqual(settled.eyes[1].transform.tx, directFrame.eyes[1].transform.tx, accuracy: 1e-6)
        // En route, though, the spin is very visible.
        XCTAssertNotEqual(spinning.sample(at: 0.02), direct.sample(at: 0.02))
    }

    func testNonFiniteLookIsRefusedAndKeepsTheLastTarget() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setLook(BloubLook(yaw: 20, pitch: 10, mix: 1, spin: 0, wander: 0), at: 0)
        engine.setLook(BloubLook(yaw: .nan, pitch: 10, mix: 1, spin: 0, wander: 0), at: 2.0)
        // A control engine that re-posed the healthy target must match: the
        // NaN never reached the timeline.
        let control = BloubEngine(radius: 100, initial: .idle)
        control.setLook(BloubLook(yaw: 20, pitch: 10, mix: 1, spin: 0, wander: 0), at: 0)
        control.setLook(BloubLook(yaw: 20, pitch: 10, mix: 1, spin: 0, wander: 0), at: 2.0)
        XCTAssertEqual(engine.sample(at: 3.0), control.sample(at: 3.0))
    }

    func testWanderSurvivesATurnedHeadWithoutPointer() {
        // With no pointer the drift modulates the pose gaze: the head keeps
        // living across time.
        let free = BloubEngine(radius: 100, initial: .idle)
        let freeValues: [CGFloat] = [2.0, 4.0, 6.0, 8.0, 10.0].map {
            free.sample(at: $0).eyes[0].transform.tx
        }
        XCTAssertGreaterThan((freeValues.max() ?? 0) - (freeValues.min() ?? 0), 2)

        // While a pointer is tracked the angular drift is silenced; only the
        // ±0.6-unit float remains.
        let tracking = BloubEngine(radius: 100, initial: .idle)
        tracking.setLook(BloubLook(yaw: 12, pitch: -6, mix: 1, spin: 0, wander: 0), at: 0)
        let trackedValues: [CGFloat] = [2.0, 4.0, 6.0, 8.0, 10.0].map {
            tracking.sample(at: $0).eyes[0].transform.tx
        }
        XCTAssertLessThan((trackedValues.max() ?? 0) - (trackedValues.min() ?? 0), 1.5)
    }

    func testPointerTargetMovesTheHead() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        let gaze = BloubMotion.targetGaze(forPointerOffset: CGPoint(x: 5, y: 0))
        engine.setLook(
            BloubLook(yaw: CGFloat(gaze.yaw), pitch: CGFloat(gaze.pitch), mix: 1, spin: 0, wander: 0),
            at: 0
        )
        let pointed = engine.sample(at: 3.0)
        let resting = BloubEngine(radius: 100, initial: .idle).sample(at: 3.0)
        XCTAssertGreaterThan(
            abs(pointed.eyes[1].transform.tx - resting.eyes[1].transform.tx),
            0.5
        )
    }
}
