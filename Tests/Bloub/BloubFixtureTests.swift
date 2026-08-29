import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Geometry fixtures (architecture rule: never judge bloub compatibility by
/// screenshots alone). Every number below was captured by running the upstream
/// TypeScript engine at a pinned commit — state, time and appearance fixed —
/// and locks the Swift port to the same output.
///
/// Captured from jeremy-prt/bloub @ b4bb3c1 with `sample(scale: 100)`.
final class BloubFixtureTests: XCTestCase {
    /// orbit @ 0.0 / 0.1 / 0.5 / 1.0 — first body point (SVG path head),
    /// inner-eye matrix, and arc population.
    func testOrbitTimelineFixtures() {
        let engine = BloubEngine(radius: 100, initial: .orbit)
        let fixtures: [(t: TimeInterval, head: (CGFloat, CGFloat), matrix: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat), arcs: Int, firstArcOpacity: CGFloat)] = [
            (0.0, (78.38, 21.63), (0.94, -0.21, 0.18, 0.97, 27.29, 9.1), 0, 0),
            (0.1, (79.73, 15.84), (0.57, -0.21, 0.04, 0.97, 71.73, 8.42), 1, 0.041667),
            (0.5, (-70.18, 40.72), (0.97, -0.21, 0.19, 0.97, 14.11, 9.0), 4, 0.625),
            (1.0, (21.4, -78.3), (0.86, -0.21, 0.14, 0.97, 34.95, 7.23), 6, 1)
        ]
        for fixture in fixtures {
            let frame = engine.sample(at: fixture.t)
            XCTAssertEqual(frame.bodyPoints.count, 64, "t=\(fixture.t)")
            XCTAssertEqual(
                frame.bodyPoints[0].x, fixture.head.0, accuracy: 0.02,
                "orbit @ \(fixture.t) head x"
            )
            XCTAssertEqual(
                frame.bodyPoints[0].y, fixture.head.1, accuracy: 0.02,
                "orbit @ \(fixture.t) head y"
            )
            XCTAssertEqual(frame.eyes.count, 2, "t=\(fixture.t)")
            let eye = frame.eyes[0].transform
            XCTAssertEqual(eye.a, fixture.matrix.0, accuracy: 0.011, "t=\(fixture.t) a")
            XCTAssertEqual(eye.b, fixture.matrix.1, accuracy: 0.011, "t=\(fixture.t) b")
            XCTAssertEqual(eye.c, fixture.matrix.2, accuracy: 0.011, "t=\(fixture.t) c")
            XCTAssertEqual(eye.d, fixture.matrix.3, accuracy: 0.011, "t=\(fixture.t) d")
            XCTAssertEqual(eye.tx, fixture.matrix.4, accuracy: 0.011, "t=\(fixture.t) tx")
            XCTAssertEqual(eye.ty, fixture.matrix.5, accuracy: 0.011, "t=\(fixture.t) ty")
            XCTAssertEqual(frame.arcs.count, fixture.arcs, "t=\(fixture.t) arc count")
            if fixture.arcs > 0 {
                XCTAssertEqual(frame.arcs[0].opacity, fixture.firstArcOpacity, accuracy: 1e-4, "t=\(fixture.t)")
                XCTAssertEqual(frame.arcs[0].width, 5.260622, accuracy: 1e-3, "t=\(fixture.t)")
                // Gradient across the major axis; stops from the hue wheel.
                XCTAssertEqual(frame.arcs[0].gradientStart.x, -136.58, accuracy: 0.01)
                XCTAssertEqual(frame.arcs[0].gradientStart.y, -5.31, accuracy: 0.01)
                XCTAssertEqual(frame.arcs[0].gradientEnd.x, 136.58, accuracy: 0.01)
                XCTAssertEqual(frame.arcs[0].gradientEnd.y, 25.31, accuracy: 0.01)
                XCTAssertEqual(frame.arcs[0].gradientStops[0].red, 0xd3 / 255.0, accuracy: 1e-3)
                XCTAssertEqual(frame.arcs[0].gradientStops[0].green, 0x71 / 255.0, accuracy: 1e-3)
                XCTAssertEqual(frame.arcs[0].gradientStops[0].blue, 0x69 / 255.0, accuracy: 1e-3)
                // The back half exists: real depth, not a flat ring.
                XCTAssertTrue(frame.arcs[0].back.flatMap { $0 }.count > 3, "t=\(fixture.t)")
            }
        }
    }

    /// The orbit ring seeds come from a fixed PRNG; the whole bouquet must
    /// match upstream shape for shape.
    func testOrbitRingSeedFixtures() {
        let expected: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (1.374316, 0.274937, 0.111637, 3.531251, 3.521581, 0.745288, 4.538151, 63.328311, 0.052606),
            (1.347803, 0.316944, 1.009311, 3.411252, 6.146908, 0.646808, 81.645993, 66.519804, 0.060184),
            (1.396025, 0.407338, 1.103976, 3.680664, 1.062764, 0.84126, 149.843713, 61.366803, 0.056178),
            (1.385397, 0.396188, 1.996122, 3.015526, 1.116472, 0.674048, 185.79063, 108.991233, 0.051693),
            (1.375075, 0.413304, 2.554288, 3.306341, 5.341918, 0.834125, 269.85057, 73.294934, 0.052619),
            (1.303824, 0.359854, 3.015789, 3.219782, 2.674188, 0.672155, 327.099594, 87.628341, 0.055452)
        ]
        XCTAssertEqual(BloubDecor.rings.count, expected.count)
        for (seed, expectation) in zip(BloubDecor.rings, expected) {
            XCTAssertEqual(seed.a, expectation.0, accuracy: 1e-5)
            XCTAssertEqual(seed.k, expectation.1, accuracy: 1e-5)
            XCTAssertEqual(seed.tilt, expectation.2, accuracy: 1e-5)
            XCTAssertEqual(seed.speed, expectation.3, accuracy: 1e-5)
            XCTAssertEqual(seed.phase, expectation.4, accuracy: 1e-5)
            XCTAssertEqual(seed.sweep, expectation.5, accuracy: 1e-5)
            XCTAssertEqual(seed.hue, expectation.6, accuracy: 1e-3)
            XCTAssertEqual(seed.hueSpan, expectation.7, accuracy: 1e-3)
            XCTAssertEqual(seed.width, expectation.8, accuracy: 1e-5)
            XCTAssertEqual(seed.cy, 0.1, accuracy: 1e-9)
        }
    }

    func testArcRenderKeepsEveryFrontAndBackRunAcrossMultipleDepthCrossings() {
        let arc = BloubDecor.arcRender(
            BloubDecor.rings[0],
            t: 0.1,
            scale: 100,
            id: "fixture",
            opacity: 1
        )

        XCTAssertEqual(
            arc.front.count + arc.back.count,
            3,
            "A 216° orbit trace crosses the silhouette plane three times"
        )
        XCTAssertTrue(arc.front.allSatisfy { $0.count >= 2 })
        XCTAssertTrue(arc.back.allSatisfy { $0.count >= 2 })
    }

    /// Per-state poses at their readable local times (BloubPoseBook).
    func testStatePoseFixtures() {
        func pose(_ state: BloubState) -> BloubPose {
            BloubStates.catalog[state]!.pose(CGFloat(BloubPoseBook.time[state]!))
        }

        // idle: the resting ball with the resting face.
        let idle = pose(.idle)
        XCTAssertEqual(idle.body.profile.radii[0], 1, accuracy: 1e-9)
        XCTAssertEqual(idle.gaze.yaw, 28.49, accuracy: 1e-9)
        XCTAssertEqual(idle.split, 15.46, accuracy: 1e-9)
        XCTAssertEqual(idle.eyes[0].width, 0.186, accuracy: 1e-9)
        XCTAssertEqual(idle.eyes[0].height, 0.412, accuracy: 1e-9)

        // thinking: the ball becomes the middle dot; eyes off; two side dots.
        let thinking = pose(.thinking)
        XCTAssertEqual(thinking.body.profile.radii[0], 0.20625, accuracy: 1e-5)
        XCTAssertEqual(thinking.body.center.x, -0.013, accuracy: 1e-9)
        XCTAssertEqual(thinking.eyeOpacity, 0)
        XCTAssertEqual(thinking.dots.count, 2)
        XCTAssertEqual(thinking.dots[0].x, -0.557, accuracy: 1e-5)
        XCTAssertEqual(thinking.dots[0].opacity, 0.55, accuracy: 1e-5)
        XCTAssertEqual(thinking.dots[1].r, 0.168566, accuracy: 1e-5)

        // alert @ 0.75: italic bar mid-flight with its teardrop dot.
        let alert = pose(.alert)
        XCTAssertEqual(alert.body.rotation, 0.308923, accuracy: 1e-5)
        XCTAssertEqual(alert.body.center.x, 0.323, accuracy: 1e-5)
        XCTAssertEqual(alert.body.center.y, -0.321464, accuracy: 1e-5)
        XCTAssertEqual(alert.eyeOpacity, 0)
        XCTAssertEqual(alert.dots.count, 1)
        XCTAssertEqual(alert.dots[0].x, 0.146661, accuracy: 1e-5)
        XCTAssertEqual(alert.dots[0].y, 0.217644, accuracy: 1e-5)
        XCTAssertEqual(alert.dots[0].dropRotation, 17.7, accuracy: 1e-9)
        XCTAssertNotNil(alert.dots[0].drop)

        // notify @ 0.9: settled badge on the rim, gaze turned away.
        let notify = pose(.notify)
        XCTAssertEqual(notify.gaze.yaw, -21.94, accuracy: 1e-9)
        XCTAssertEqual(notify.eyes[0].width, 0.505, accuracy: 1e-9)
        XCTAssertEqual(notify.notification?.x ?? 0, 0.745374, accuracy: 1e-5)
        XCTAssertEqual(notify.notification?.y ?? 0, -0.671138, accuracy: 1e-5)
        XCTAssertEqual(notify.notification?.r ?? 0, 0.15, accuracy: 1e-5)
        XCTAssertEqual(notify.notification?.notch ?? 0, 0.204, accuracy: 1e-5)

        // exclaim @ 0.8: upright tapered bar plus its dot.
        let exclaim = pose(.exclaim)
        XCTAssertEqual(exclaim.body.profile.radii[0], 0.10392, accuracy: 1e-5)
        XCTAssertEqual(exclaim.body.center.y, -0.1875, accuracy: 1e-9)
        XCTAssertEqual(exclaim.eyeOpacity, 0)
        XCTAssertEqual(exclaim.dots[0].y, 0.526, accuracy: 1e-9)

        // sleep @ 0.45: the bouncing dot at the bottom of its arc.
        let sleep = pose(.sleep)
        XCTAssertEqual(sleep.body.profile.radii[0], 0.1585, accuracy: 1e-9)
        XCTAssertEqual(sleep.body.center.y, -0.08, accuracy: 1e-5)

        // egg / hexagon: measured profiles with tightened faces.
        let egg = pose(.egg)
        XCTAssertEqual(egg.body.profile.radii, BloubProfileFixture.egg.radii)
        XCTAssertEqual(egg.split, 11.07, accuracy: 1e-9)
        let hexagon = pose(.hexagon)
        XCTAssertEqual(hexagon.body.profile.radii, BloubProfileFixture.hexagon.radii)
        XCTAssertEqual(hexagon.gaze.yaw, 23.11, accuracy: 1e-9)

        // play @ 0.9: triangle with the swoosh bouquet crossing it.
        let play = pose(.play)
        XCTAssertEqual(play.body.profile.radii, BloubProfileFixture.triangle.radii)
        XCTAssertEqual(play.body.center.y, 0.213, accuracy: 1e-9)
        XCTAssertEqual(play.arcs.count, 4)
        XCTAssertEqual(play.arcs[0].opacity, 1, accuracy: 1e-9)

        // orbit @ 1.2: triangle spinning, rings fully in, eyes racing.
        let orbit = pose(.orbit)
        XCTAssertEqual(orbit.body.rotation, -9.424778, accuracy: 1e-5)
        XCTAssertEqual(orbit.body.center.y, -0.213, accuracy: 1e-5)
        XCTAssertEqual(orbit.gaze.yaw, 93.395317, accuracy: 1e-4)
        XCTAssertEqual(orbit.arcs.count, 6)

        // swirl @ 0.5: rest body + face, three rings, no triangle.
        let swirl = pose(.swirl)
        XCTAssertEqual(swirl.body.profile.radii[0], 1, accuracy: 1e-9)
        XCTAssertEqual(swirl.gaze.yaw, 28.49, accuracy: 1e-9)
        XCTAssertEqual(swirl.arcs.count, 3)

        // burst @ 0.45: collapsed core, no eyes, particles behind.
        let burst = pose(.burst)
        XCTAssertEqual(burst.body.profile.radii[0], 0.170846, accuracy: 1e-5)
        XCTAssertEqual(burst.eyeOpacity, 0)
        XCTAssertTrue(burst.dotsBehind)
        XCTAssertEqual(burst.dots.count, 3)
        XCTAssertEqual(burst.dots[0].x, 0.043261, accuracy: 1e-5)
        XCTAssertEqual(burst.dots[0].y, -0.168727, accuracy: 1e-5)
        XCTAssertEqual(burst.dots[0].r, 0.062909, accuracy: 1e-5)
        XCTAssertEqual(burst.dots[2].opacity, 0.833333, accuracy: 1e-5)

        // comet @ 1.15: the dot with four ribbons.
        let comet = pose(.comet)
        XCTAssertEqual(comet.body.profile.radii[0], 0.129, accuracy: 1e-5)
        XCTAssertEqual(comet.body.center.y, 0.029758, accuracy: 1e-5)
        XCTAssertEqual(comet.eyeOpacity, 0)
        XCTAssertEqual(comet.arcs.count, 4)
    }
}
