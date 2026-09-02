import Foundation
import XCTest
@testable import Clawdesk

/// Catalogue-level guarantees: the state set is complete, the reading order
/// excludes the interface-only transition, and every agent-side `PetState`
/// resolves through the mapper seam.
final class BloubStateTests: XCTestCase {
    func testCatalogCoversEveryStateExactlyOnce() {
        XCTAssertEqual(Set(BloubStates.catalog.keys), Set(BloubState.allCases))
        XCTAssertEqual(BloubStates.catalog.count, BloubState.allCases.count)
    }

    func testPoseBookCoversEveryState() {
        for state in BloubState.allCases {
            XCTAssertNotNil(BloubPoseBook.time[state], "missing readable pose time for \(state)")
        }
    }

    func testSequenceExcludesSwirl() {
        // swirl is an interface transition and dizzy is a runtime reaction,
        // not a montage block; neither belongs in the reading order.
        let expected: [BloubState] = [
            .idle, .thinking, .wink, .wide, .alert, .notify, .exclaim, .sleep,
            .egg, .hexagon, .play, .orbit, .burst, .comet
        ]
        XCTAssertEqual(BloubStates.sequence, expected)
        XCTAssertFalse(BloubStates.sequence.contains(.swirl))
        XCTAssertFalse(BloubStates.sequence.contains(.dizzy))
    }

    func testMorphDurationsAreBounded() {
        for (state, definition) in BloubStates.catalog {
            XCTAssertGreaterThan(definition.morph, 0, state.rawValue)
            XCTAssertLessThan(definition.morph, 2, state.rawValue)
            // minDuration encodes when the state's own animation resolves
            // (the "!" back in place, the core regrown); it must exist
            // whenever declared and stay sane.
            if let minDuration = definition.minDuration {
                XCTAssertGreaterThan(minDuration, 0, state.rawValue)
            }
        }
        // The measured one-shots declare their internal resolution times.
        XCTAssertEqual(BloubStates.catalog[.alert]?.minDuration, 2)
        XCTAssertNil(BloubStates.catalog[.orbit]?.minDuration, "orbit is a continuous multi-agent work cycle")
        XCTAssertEqual(BloubStates.catalog[.burst]?.minDuration, 2.4)
        XCTAssertNil(BloubStates.catalog[.comet]?.minDuration, "comet is a continuous work cycle")
    }

    func testMapperCoversEveryPetState() {
        let expected: [PetState: BloubState] = [
            .idle: .idle,
            .roam: .roam,
            .thinking: .thinking,
            .typing: .play,
            .building: .building,
            .juggling: .orbit,
            .sweeping: .sweeping,
            .carrying: .carrying,
            .error: .exclaim,
            .reactFlail: .exclaim,
            .attention: .burst,
            .notification: .notify,
            .dizzy: .dizzy,
            .yawning: .yawning,
            .dozing: .dozing,
            .collapsing: .collapsing,
            .sleeping: .sleeping,
            .waking: .waking,
            .wakingFromDoze: .wakingFromDoze,
            .dragging: .wide,
            .reactDouble: .wink,
            .miniIdle: .miniIdle,
            .miniPeek: .miniPeek,
            .miniAlert: .miniAlert,
            .miniHappy: .miniHappy,
            .miniWorking: .miniWorking,
            .miniCrabwalk: .miniCrabwalk,
            .miniEnter: .miniEnter,
            .miniEnterSleep: .miniEnterSleep,
            .miniSleep: .miniSleep
        ]
        XCTAssertEqual(Set(expected.keys), Set(PetState.allCases))
        for petState in PetState.allCases {
            XCTAssertEqual(
                BloubStateMapper.state(for: petState),
                expected[petState],
                "unexpected mapping for \(petState.rawValue)"
            )
        }
    }

    func testMapperRefinesJugglingBySubagentCount() {
        XCTAssertEqual(BloubStateMapper.state(for: .juggling, subagentCount: 0), .comet)
        XCTAssertEqual(BloubStateMapper.state(for: .juggling, subagentCount: 1), .comet)
        XCTAssertEqual(BloubStateMapper.state(for: .juggling, subagentCount: 2), .orbit)
        XCTAssertEqual(BloubStateMapper.state(for: .juggling, subagentCount: 5), .orbit)
        // Non-juggling states ignore the count.
        XCTAssertEqual(BloubStateMapper.state(for: .idle, subagentCount: 4), .idle)
    }

    func testEngineServesEveryStateWithoutCrashing() {
        for state in BloubState.allCases {
            let engine = BloubEngine(radius: 100, initial: state)
            let time = BloubPoseBook.time[state] ?? 1
            let frame = engine.sample(at: time)
            XCTAssertEqual(frame.bodyPoints.count, RadialProfile.sampleCount)
            for point in frame.bodyPoints {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite, state.rawValue)
            }
        }
    }

    func testThinkingAndWorkingUseDistinctContinuousAnimations() {
        let thinking = BloubEngine(radius: 100, initial: .thinking)
        let thinkingStart = thinking.sample(at: 0.2)
        let thinkingLater = thinking.sample(at: 0.8)
        XCTAssertEqual(thinkingStart.dots.count, 2)
        XCTAssertEqual(thinkingLater.dots.count, 2)
        XCTAssertNotEqual(thinkingStart.dots, thinkingLater.dots)

        let working = BloubEngine(radius: 100, initial: .play)
        let workingFrame = working.sample(at: 0.9)
        XCTAssertTrue(workingFrame.dots.isEmpty, "play should not use thought dots")
        XCTAssertEqual(workingFrame.arcs.count, 4)

        for (state, label) in [
            (BloubState.thinking, "thinking"),
            (.play, "play"),
            (.orbit, "orbit"),
            (.comet, "comet"),
            (.building, "building"),
            (.carrying, "carrying"),
            (.sweeping, "sweeping")
        ] {
            let engine = BloubEngine(radius: 100, initial: state)
            XCTAssertFalse(engine.isSettled(at: 120), "\(label) must keep animating while work is active")
        }
    }

    func testDizzyPoseContainsMovingRingsAndBodyMotion() {
        let engine = BloubEngine(radius: 100, initial: .dizzy)
        let first = engine.sample(at: 0.1)
        let second = engine.sample(at: 1.2)

        XCTAssertEqual(first.arcs.count, 3)
        XCTAssertEqual(second.arcs.count, 3)
        XCTAssertNotEqual(first.bodyPoints, second.bodyPoints)
        XCTAssertNotEqual(first.eyes, second.eyes)
        XCTAssertFalse(engine.isSettled(at: 20))
    }
}
