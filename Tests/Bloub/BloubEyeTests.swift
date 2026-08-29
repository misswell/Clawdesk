import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Spherical eye model fixtures captured from the upstream TypeScript engine.
/// The eye positions, tangent frames and depth factors must match bloub bit
/// for bit (within capture rounding) or the face stops being the bloub face.
final class BloubEyeTests: XCTestCase {
    func testEyePosesAtRestGaze() {
        // Upstream: eyePoses(REST_GAZE, 100) — inner eye first.
        let poses = BloubFace.eyePoses(gaze: BloubGaze(yaw: 28.49, pitch: 28.62, roll: -13), scale: 100)
        XCTAssertEqual(poses.count, 2)

        let inner = poses[0]
        XCTAssertEqual(inner.x, 18.899315, accuracy: 1e-4)
        XCTAssertEqual(inner.y, -40.902908, accuracy: 1e-4)
        XCTAssertEqual(inner.a, 0.887467, accuracy: 1e-5)
        XCTAssertEqual(inner.b, -0.318005, accuracy: 1e-5)
        XCTAssertEqual(inner.c, 0.420338, accuracy: 1e-5)
        XCTAssertEqual(inner.d, 0.855317, accuracy: 1e-5)
        XCTAssertEqual(inner.depth, 0.892736, accuracy: 1e-5)

        let outer = poses[1]
        XCTAssertEqual(outer.x, 61.81511, accuracy: 1e-4)
        XCTAssertEqual(outer.y, -51.430413, accuracy: 1e-4)
        XCTAssertEqual(outer.a, 0.664233, accuracy: 1e-5)
        XCTAssertEqual(outer.depth, 0.594458, accuracy: 1e-5)
    }

    func testEyePosesAtWideGaze() {
        let poses = BloubFace.eyePoses(
            gaze: BloubGaze(yaw: 6.92, pitch: -21.96, roll: 11.6),
            scale: 100,
            split: 18.43
        )
        XCTAssertEqual(poses[0].x, -19.85579, accuracy: 1e-4)
        XCTAssertEqual(poses[0].y, 29.582143, accuracy: 1e-4)
        XCTAssertEqual(poses[0].depth, 0.934379, accuracy: 1e-5)
        XCTAssertEqual(poses[1].x, 41.0579, accuracy: 1e-4)
        XCTAssertEqual(poses[1].depth, 0.812556, accuracy: 1e-5)
    }

    func testBlinkScaleSquashesVertically() {
        XCTAssertEqual(BloubFace.blinkScale(1), 1, accuracy: 1e-12)
        XCTAssertEqual(BloubFace.blinkScale(0), 0.06, accuracy: 1e-12)
        XCTAssertEqual(BloubFace.blinkScale(0.5), 0.53, accuracy: 1e-12)
    }

    func testWinkKeepsOneEyeOpenAndOneWideDash() {
        let definition = BloubStates.catalog[.wink]
        XCTAssertNotNil(definition)
        let pose = definition!.pose(0.5)
        XCTAssertEqual(pose.eyes[0].width, 0.236, accuracy: 1e-9)
        XCTAssertEqual(pose.eyes[0].height, 0.464, accuracy: 1e-9)
        // The closed eye is a dash WIDER than the open eye, not a squash.
        XCTAssertEqual(pose.eyes[1].width, 0.447, accuracy: 1e-9)
        XCTAssertEqual(pose.eyes[1].height, 0.089, accuracy: 1e-9)
        XCTAssertEqual(pose.eyeOpacity, 1)
    }

    func testEyesVanishPastTheHorizon() {
        // A 120° yaw turns both eyes to the back hemisphere.
        let poses = BloubFace.eyePoses(gaze: BloubGaze(yaw: 120, pitch: 0, roll: 0), scale: 100)
        XCTAssertTrue(poses.allSatisfy { $0.depth <= 0.02 })
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setLook(BloubLook(yaw: 120, pitch: 0, mix: 1, spin: 0, wander: 0), at: 0)
        XCTAssertEqual(engine.sample(at: 5).eyes.count, 0)
    }

    func testEyeAlphaFollowsDepthAndEyeOpacity() {
        let engine = BloubEngine(radius: 100, initial: .egg)
        let frame = engine.sample(at: BloubPoseBook.time[.egg]!)
        XCTAssertEqual(frame.eyes.count, 2)
        // egg gaze keeps both eyes well inside the front hemisphere.
        for eye in frame.eyes {
            XCTAssertGreaterThan(eye.alpha, 0.8)
        }

        // burst regrows its eyes late: at t=0.45 they are not back yet.
        let burst = BloubEngine(radius: 100, initial: .burst)
        XCTAssertTrue(burst.sample(at: 0.45).eyes.isEmpty)
        // at t=2.4 the eyes are fully faded back in.
        XCTAssertEqual(burst.sample(at: 2.4).eyes.count, 2)
    }

    func testEyeFitReSeatsEyesOnNonCircularSilhouettes() {
        // On the egg the eye direction's body radius is ~0.84, so the rendered
        // eye centre is pulled proportionally towards the centre compared with
        // a unit circle.
        let egg = BloubEngine(radius: 100, initial: .egg)
        let eggFrame = egg.sample(at: BloubPoseBook.time[.egg]!)
        let circle = BloubEngine(radius: 100, initial: .idle)
        let circleFrame = circle.sample(at: BloubPoseBook.time[.idle]!)
        // Same gaze family: compare |position| ratios rather than raw values
        // because the gazes differ between the two states.
        func magnitude(_ eye: BloubRenderedEye) -> CGFloat {
            (eye.transform.tx * eye.transform.tx + eye.transform.ty * eye.transform.ty).squareRoot()
        }
        XCTAssertLessThan(magnitude(eggFrame.eyes[0]), magnitude(circleFrame.eyes[0]))
    }
}
