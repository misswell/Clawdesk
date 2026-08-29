import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Time semantics: the engine owns no clock, transitions are timestamped, and
/// the decoration timelines (badge pop, blink mask, ring spin) land where the
/// reference video puts them.
final class BloubTimingTests: XCTestCase {
    func testEngineHasNoClockOfItsOwn() {
        // Two engines sampled at the same date without any setter agree —
        // sampling neither reads nor advances hidden time.
        let a = BloubEngine(radius: 100, initial: .idle)
        let b = BloubEngine(radius: 100, initial: .idle)
        XCTAssertEqual(a.sample(at: 12.4), b.sample(at: 12.4))
        // And out-of-order reads replay, which is impossible with an internal
        // ticking clock.
        XCTAssertEqual(a.sample(at: 12.4), a.sample(at: 12.4))
    }

    func testStateChangeTimestampDrivesTheMorph() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setState(.notify, at: 2.0)
        // Before the change the engine still serves idle, even at a later date
        // than the change: time is an argument, not a current value.
        let eyes = engine.sample(at: 1.0).eyes
        XCTAssertEqual(eyes.count, 2)
        // The served frame at t=1.0 must carry the idle split (15.46), not
        // notify's (18.89).
        let life = BloubMotion.liveliness(at: 1.0)
        let expected = BloubFace.eyePoses(
            gaze: BloubGaze(
                yaw: 28.49 + life.dYaw,
                pitch: 28.62 + life.dPitch,
                roll: -13 + life.dRoll
            ),
            scale: 100,
            split: BloubFace.eyeSplit
        )
        XCTAssertEqual(eyes[1].transform.tx, expected[1].x + CGFloat(life.driftX) * 100, accuracy: 1e-4)
    }

    func testNotificationPopPeaksThenStabilises() {
        let engine = BloubEngine(radius: 100, initial: .notify)
        // p = t / 0.45; the pop peaks 14 % above the rest radius early on.
        let peak = engine.sample(at: 0.135).notification?.radius ?? 0
        XCTAssertEqual(peak, 0.15 * 1.1013 * 100, accuracy: 0.2)
        let settled = engine.sample(at: 1.0).notification?.radius ?? 0
        XCTAssertEqual(settled, 15, accuracy: 0.01)
        // The notch rides along with the badge scale.
        let notch = engine.sample(at: 1.0).notch?.radius ?? 0
        XCTAssertEqual(notch, settled + BloubDecor.notifMargin * 100, accuracy: 0.01)
    }

    func testAlertRunTravelsThenReturns() {
        let engine = BloubEngine(radius: 100, initial: .alert)
        let startX = engine.sample(at: 0.001).body.center.x
        let midX = engine.sample(at: 0.75).body.center.x
        let returnedX = engine.sample(at: 2.1).body.center.x
        XCTAssertLessThan(startX, 0)
        XCTAssertGreaterThan(midX, 0.3)
        XCTAssertEqual(returnedX, 0.1, accuracy: 0.01)
        // The "!" glyph keeps its measured tilt.
        XCTAssertEqual(engine.sample(at: 0.75).body.rotation, 17.7 * .pi / 180, accuracy: 1e-6)
    }

    func testBurstCollapsesThenRegrows() {
        let engine = BloubEngine(radius: 100, initial: .burst)
        XCTAssertGreaterThan(engine.sample(at: 0.001).body.profile.radii[0], 0.99)
        // Bottom of the collapse: 0.166.
        XCTAssertEqual(engine.sample(at: 0.7).body.profile.radii[0], 0.166, accuracy: 0.002)
        // Regrown core by 2.4 s, eyes faded back in.
        XCTAssertEqual(engine.sample(at: 2.4).body.profile.radii[0], 1, accuracy: 0.002)
        XCTAssertEqual(engine.sample(at: 2.4).eyes.count, 2)
        // Particles pass behind the core while it is swallowed.
        XCTAssertTrue(engine.sample(at: 0.45).dotsBehind)
    }

    func testSleepIsASmallBouncingDot() {
        let engine = BloubEngine(radius: 100, initial: .sleep)
        let frame = engine.sample(at: 0.15)
        XCTAssertEqual(frame.body.profile.radii[0], 0.1585, accuracy: 1e-9)
        XCTAssertGreaterThan(frame.body.center.y, 0.11)
        XCTAssertEqual(frame.eyes.count, 0)
        // The bounce period is 0.6 s around +0.11: a quarter period later the
        // dot sits below the axis (golden upstream pose at t=0.45: -0.08).
        XCTAssertEqual(engine.sample(at: 0.45).body.center.y, -0.08, accuracy: 0.02)
    }

    func testOrbitRingsEnterOneByOneThenFadeOut() {
        let engine = BloubEngine(radius: 100, initial: .orbit)
        XCTAssertEqual(engine.sample(at: 0.0).arcs.count, 0)
        XCTAssertGreaterThanOrEqual(engine.sample(at: 0.5).arcs.count, 3)
        XCTAssertEqual(engine.sample(at: 1.0).arcs.count, 6)
        XCTAssertEqual(engine.sample(at: 5.0).arcs.count, 0)
    }

    func testOrbitRingsSpinDeterministically() {
        let engine = BloubEngine(radius: 100, initial: .orbit)
        let first = engine.sample(at: 2.0).arcs[0]
        let second = engine.sample(at: 2.1).arcs[0]
        XCTAssertEqual(first.gradientStops, second.gradientStops)
        XCTAssertNotEqual(first.front, second.front)
        // Same date through a fresh engine: identical traces.
        XCTAssertEqual(BloubEngine(radius: 100, initial: .orbit).sample(at: 2.0).arcs, engine.sample(at: 2.0).arcs)
    }

    func testCometTrailOrbitsADotThatStaysCentred() {
        let engine = BloubEngine(radius: 100, initial: .comet)
        let frame = engine.sample(at: 1.0)
        XCTAssertEqual(frame.body.profile.radii[0], BloubDecor.cometDot, accuracy: 0.001)
        XCTAssertEqual(frame.arcs.count, 4)
        XCTAssertLessThanOrEqual(frame.body.center.y, 0.05)
        // Past 1.95 s the trail has faded; the dot regrows into a ball.
        XCTAssertEqual(engine.sample(at: 2.3).arcs.count, 0)
        XCTAssertGreaterThan(engine.sample(at: 2.3).body.profile.radii[0], 0.9)
    }

    func testThinkingDotsPulseLeftToRight() {
        let engine = BloubEngine(radius: 100, initial: .thinking)
        // The body BECOMES the middle dot; the side dots are decorations.
        let frame = engine.sample(at: 1.1)
        XCTAssertEqual(frame.body.center.x, BloubDecor.dotX[1], accuracy: 0.02)
        XCTAssertEqual(frame.dots.count, 2)
        XCTAssertLessThan(frame.dots[0].position.x, 0)
        XCTAssertGreaterThan(frame.dots[1].position.x, 0)
    }
}
