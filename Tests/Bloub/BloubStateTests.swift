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
        // swirl is an interface transition, not a catalogue animation; it must
        // never appear in the reading order nor accept catalogue blocks.
        XCTAssertEqual(BloubStates.sequence.count, 14)
        XCTAssertFalse(BloubStates.sequence.contains(.swirl))
        XCTAssertEqual(Set(BloubStates.sequence), Set(BloubState.allCases).subtracting([.swirl]))
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
        // The two measured one-shots declare their internal resolution times.
        XCTAssertEqual(BloubStates.catalog[.alert]?.minDuration, 2)
        XCTAssertEqual(BloubStates.catalog[.orbit]?.minDuration, 2.5)
        XCTAssertEqual(BloubStates.catalog[.burst]?.minDuration, 2.4)
        XCTAssertEqual(BloubStates.catalog[.comet]?.minDuration, 2.4)
    }

    func testMapperCoversEveryPetState() {
        let expected: [PetState: BloubState] = [
            .idle: .idle,
            .miniIdle: .idle,
            .miniPeek: .idle,
            .thinking: .thinking,
            .typing: .orbit,
            .building: .hexagon,
            .juggling: .orbit,
            .sweeping: .comet,
            .carrying: .egg,
            .error: .exclaim,
            .reactFlail: .exclaim,
            .attention: .burst,
            .miniHappy: .burst,
            .notification: .notify,
            .miniAlert: .notify,
            .yawning: .sleep,
            .dozing: .sleep,
            .collapsing: .sleep,
            .sleeping: .sleep,
            .waking: .swirl,
            .wakingFromDoze: .swirl,
            .dragging: .wide,
            .reactDouble: .wink
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
}
