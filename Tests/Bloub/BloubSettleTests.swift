import Foundation
import XCTest
@testable import Clawdesk

/// Idle-scheduling contracts (architecture rule: idle never means a permanent
/// 60 FPS clock). The engine tells the driver when only the slow rest life
/// remains, and the driver drops to a low cadence.
final class BloubSettleTests: XCTestCase {
    func testSettleTableCoversEveryState() {
        let expected: [BloubState: TimeInterval?] = [
            .idle: 0,
            .thinking: nil,
            .wink: 0,
            .wide: 0,
            .alert: 2.1,
            .notify: 0.5,
            .exclaim: 0,
            .sleep: nil,
            .egg: 0,
            .hexagon: 0,
            .play: 2.3,
            .orbit: 4.6,
            .burst: 2.5,
            .comet: 2.6,
            .swirl: 1.3
        ]
        XCTAssertEqual(Set(expected.keys), Set(BloubState.allCases))
        for state in BloubState.allCases {
            XCTAssertEqual(
                BloubStates.catalog[state]?.settlesAt,
                expected[state],
                state.rawValue
            )
        }
    }

    func testIdleSettlesAfterItsEntryMorph() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        XCTAssertFalse(engine.isSettled(at: 0.2), "entry morph still in flight")
        XCTAssertTrue(engine.isSettled(at: 0.5))
        // Settled is idempotent: repeated reads agree (purity).
        XCTAssertTrue(engine.isSettled(at: 0.5))
    }

    func testOneShotStatesSettleAtTheirMeasuredEnd() {
        // Alert keeps its sub-pixel buzz after the "!" lands; burst regrows
        // its core; orbit fades the rings out last.
        let cases: [(BloubState, TimeInterval)] = [
            (.alert, 2.1), (.notify, 0.5), (.play, 2.3),
            (.orbit, 4.6), (.burst, 2.5), (.comet, 2.6), (.swirl, 1.3)
        ]
        for (state, settle) in cases {
            let engine = BloubEngine(radius: 100, initial: state)
            let morph = BloubStates.catalog[state]!.morph
            let inside = max(morph, settle) - 0.1
            let after = max(morph, settle) + 0.5
            XCTAssertFalse(
                engine.isSettled(at: inside),
                "\(state.rawValue) must keep animating until \(settle)"
            )
            XCTAssertTrue(engine.isSettled(at: after), state.rawValue)
        }
    }

    func testLoopingStatesNeverSettle() {
        for state in [BloubState.thinking, .sleep] {
            let engine = BloubEngine(radius: 100, initial: state)
            XCTAssertFalse(
                engine.isSettled(at: 300),
                "\(state.rawValue) loops forever"
            )
        }
    }

    func testGazeCatchUpUnsettlesBriefly() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.reset(.idle, at: 10)
        XCTAssertTrue(engine.isSettled(at: 10.5))
        engine.setLook(
            BloubLook(yaw: 30, pitch: 0, mix: 1, spin: 0, wander: 0),
            at: 11
        )
        XCTAssertFalse(engine.isSettled(at: 11.1), "tracking must run at full speed")
        XCTAssertTrue(engine.isSettled(at: 11.4), "0.24 s catch-up is over")
    }

    func testCustomizationMorphsUnsettleBriefly() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        engine.reset(.idle, at: 10)
        engine.setShape(BloubShapeCatalog.shape(.pebble).profile, at: 11)
        XCTAssertFalse(engine.isSettled(at: 11.2), "shape morph in flight")
        XCTAssertTrue(engine.isSettled(at: 11.6))
        engine.setExpression(BloubExpression.expression(.happy), at: 12)
        XCTAssertFalse(engine.isSettled(at: 12.2), "expression morph in flight")
        XCTAssertTrue(engine.isSettled(at: 12.6))
    }

    func testForcedBlinkUnsettlesTheEntry() {
        let engine = BloubEngine(radius: 100, initial: .idle)
        // wide is blinkIn: the masked entry keeps the full frequency beyond
        // its morph end until the forced blink has played.
        engine.setState(.wide, at: 5)
        XCTAssertFalse(engine.isSettled(at: 5.3))
        XCTAssertTrue(engine.isSettled(at: 5.7))
    }
}
