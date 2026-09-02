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
            .roam: nil,
            .thinking: nil,
            .wink: 0,
            .wide: 0,
            .alert: 2.1,
            .notify: 0.5,
            .exclaim: 0,
            .sleep: nil,
            .yawning: nil,
            .dozing: 0.8,
            .collapsing: 1.0,
            .sleeping: nil,
            .waking: 1.3,
            .wakingFromDoze: 0.6,
            .building: nil,
            .carrying: nil,
            .sweeping: nil,
            .egg: 0,
            .hexagon: 0,
            .play: nil,
            .orbit: nil,
            .burst: 2.5,
            .comet: nil,
            .swirl: 1.3,
            .dizzy: nil,
            .miniIdle: 0,
            .miniPeek: 0.9,
            .miniAlert: 0.5,
            .miniHappy: 2.1,
            .miniWorking: nil,
            .miniCrabwalk: nil,
            .miniEnter: 1.2,
            .miniEnterSleep: 1.0,
            .miniSleep: nil
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

    func testFiniteStatesSettleAtTheirMeasuredEnd() {
        // Alert keeps its sub-pixel buzz after the "!" lands and burst
        // regrows its core. Work cycles and the sleep dot are intentionally
        // excluded: their catalogue settle time is nil because they loop
        // until the lifecycle state changes.
        for state in BloubState.allCases {
            guard let settle = BloubStates.catalog[state]?.settlesAt else { continue }
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
        let looping: [BloubState] = [
            .roam, .thinking, .sleep, .yawning, .sleeping, .play, .orbit,
            .comet, .dizzy, .building, .carrying, .sweeping, .miniWorking,
            .miniCrabwalk, .miniSleep
        ]
        for state in looping {
            let engine = BloubEngine(radius: 100, initial: state)
            XCTAssertFalse(
                engine.isSettled(at: 300),
                "\(state.rawValue) must keep animating until the lifecycle state changes"
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
