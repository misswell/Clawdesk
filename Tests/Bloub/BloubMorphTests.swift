import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

/// Morph semantics: exponential ease-out entries, replay purity, and the
/// transition-continuity freeze that starts a new fade from the displayed
/// composite instead of the theoretical target.
final class BloubMorphTests: XCTestCase {
    func testSampleIsAPureFunctionOfTime() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setState(.orbit, at: 0)
        XCTAssertEqual(engine.sample(at: 0.7), engine.sample(at: 0.7))
        XCTAssertEqual(engine.sample(at: 2.3), engine.sample(at: 2.3))
        // Reading an earlier date replays the same image, including mid-fade.
        engine.setState(.burst, at: 1.0)
        XCTAssertEqual(engine.sample(at: 1.2), engine.sample(at: 1.2))
    }

    func testIdenticalTimelinesProduceIdenticalFrames() {
        func runTimeline() -> [BloubFrame] {
            let engine = BloubEngine(radius: 100, initial: .idle)
            engine.setState(.wide, at: 0.5)
            engine.setState(.thinking, at: 1.4)
            engine.setLook(BloubLook(yaw: 12, pitch: -6, mix: 1, spin: 0, wander: 0), at: 0.9)
            return [0.2, 0.7, 1.0, 1.6, 2.2].map { engine.sample(at: $0) }
        }
        XCTAssertEqual(runTimeline(), runTimeline())
    }

    func testSettingTheSameStateIsANoOp() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.sample(at: 1.0)
        let before = engine.sample(at: 1.5)
        engine.setState(.idle, at: 1.5)
        XCTAssertEqual(engine.sample(at: 1.5), before)
    }

    func testEntryUsesExponentialEaseOutWithoutOvershoot() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setState(.wide, at: 0)
        // wide's eyes are 0.875 tall against idle's 0.412: track the rendered
        // capsule height across the 0.55 s morph.
        func capsuleHeight(at t: TimeInterval) -> CGFloat {
            guard let eye = engine.sample(at: t).eyes.first else { return 0 }
            return eye.capsuleHeight * abs(eye.transform.d)
        }
        let start = capsuleHeight(at: 0.001)
        let mid = capsuleHeight(at: 0.275)
        let end = capsuleHeight(at: 0.55)
        let late = capsuleHeight(at: 0.8)
        XCTAssertGreaterThan(mid, start)
        XCTAssertGreaterThan(end, mid)
        // Ease-out saturates: no spring beyond the final pose.
        XCTAssertEqual(end, late, accuracy: 0.35)
    }

    /// Architecture rule: a state change landing mid-fade must start the new
    /// fade from the currently displayed composite. Upstream measured a 35.9 px
    /// jump when this was violated on `idle -> wide -> idle` at 100 ms.
    func testMidMorphChangeFreezesTheDisplayedComposite() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setState(.wide, at: 0.5)
        let before = engine.sample(at: 0.75)
        engine.setState(.idle, at: 0.75)
        let after = engine.sample(at: 0.75 + 1e-6)
        XCTAssertEqual(before.bodyPoints.first?.x ?? 0, after.bodyPoints.first?.x ?? 0, accuracy: 0.05)
        XCTAssertEqual(before.bodyPoints.first?.y ?? 0, after.bodyPoints.first?.y ?? 0, accuracy: 0.05)
        // The frozen composite carries the wide morph still in flight: its
        // eyes are already nearly wide, unlike a plain idle restart.
        let freshIdle = BloubEngine(radius: 100, initial: .idle)
        let idleFrame = freshIdle.sample(at: 0.75 + 1e-6)
        XCTAssertGreaterThan(
            (after.eyes.first?.capsuleHeight ?? 0) - (idleFrame.eyes.first?.capsuleHeight ?? 0),
            30,
            "frozen origin should keep the in-flight eye morph"
        )
    }

    func testChainedMidMorphChangesStayContinuous() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setState(.wide, at: 0)
        for (index, state) in [BloubState.thinking, .wide, .egg, .idle].enumerated() {
            let now = 0.1 + Double(index + 1) * 0.1
            // The displayed composite at the exact change instant is the
            // continuity baseline, whatever its own morph state.
            let before = engine.sample(at: now)
            engine.setState(state, at: now)
            let after = engine.sample(at: now + 1e-6)
            XCTAssertLessThan(
                abs(after.bodyPoints.first!.x - before.bodyPoints.first!.x),
                0.05,
                "jump entering \(state.rawValue)"
            )
            XCTAssertLessThan(
                abs(after.bodyPoints.first!.y - before.bodyPoints.first!.y),
                0.05,
                "jump entering \(state.rawValue)"
            )
        }
    }

    func testFadeIgnoresThePreviousStateOnceComplete() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.setState(.wide, at: 0)
        let settled = engine.sample(at: 2.0)
        // After the 0.55 s morph the wide pose is fully served (eyes 0.875).
        let wideEye = settled.eyes.first
        XCTAssertNotNil(wideEye)
        XCTAssertEqual(wideEye?.capsuleHeight ?? 0, 0.875 * 100, accuracy: 0.01)
    }

    func testBlinkInStatesMaskTheirEntry() {
        let masked = BloubEngine(radius: 100, initial: .idle)
        masked.setState(.wide, at: 1.0)
        let midBlink = masked.sample(at: 1.1).eyes.first
        XCTAssertNotNil(midBlink)
        // forced blink peaks at 0.1 s: the capsule is squashed to ~6 %.
        XCTAssertLessThan(abs(midBlink?.transform.d ?? 1), 0.12)

        let unmasked = BloubEngine(radius: 100, initial: .idle)
        unmasked.setState(.orbit, at: 1.0)
        let noBlink = unmasked.sample(at: 1.1).eyes.first
        XCTAssertNotNil(noBlink)
        XCTAssertGreaterThan(abs(noBlink?.transform.d ?? 0), 0.7)
    }
}
