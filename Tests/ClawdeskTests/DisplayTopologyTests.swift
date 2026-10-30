import Foundation
import XCTest
@testable import Clawdesk

/// Window containment across displays. The union of the visible frames is
/// only an outer bound: with staggered monitors it admits dead zones where
/// no display exists, and a window clamped there is unreachable. The clamp
/// is loose (overhangs allowed, like upstream `looseClampPetToDisplays`) but
/// the result must overlap a real display — otherwise it is pulled to the
/// nearest work area.
final class DisplayTopologyTests: XCTestCase {
    private let left = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    /// Staggered top-right display: its lower edge sits at y=200 while the
    /// left display reaches x=1920, so the region x>1920, y<200 belongs to
    /// the union of both screens but to neither of them.
    private let right = CGRect(x: 1_920, y: 200, width: 1_920, height: 1_080)

    func testWindowOnAScreenKeepsUpstreamLooseBehaviour() {
        let clamped = DisplayTopology.clampLooseOrigin(
            CGPoint(x: 3_750, y: 100),
            windowSize: CGSize(width: 200, height: 200),
            visibleFrames: [left, right]
        )
        // Union clamp alone: the frame still overlaps the right display.
        XCTAssertEqual(clamped, CGPoint(x: 3_640, y: 100))
    }

    func testDeadZoneBetweenStaggeredDisplaysIsUnreachable() {
        let size = CGSize(width: 200, height: 200)
        let clamped = DisplayTopology.clampLooseOrigin(
            CGPoint(x: 2_000, y: 0),
            windowSize: size,
            visibleFrames: [left, right]
        )
        let frame = CGRect(origin: clamped, size: size)
        XCTAssertTrue(right.intersects(frame), "must be pulled out of the dead zone")
        XCTAssertFalse(left.intersects(frame))
    }

    func testPulledWindowLandsOnTheNearestDisplay() {
        let size = CGSize(width: 200, height: 200)
        let clamped = DisplayTopology.clampLooseOrigin(
            CGPoint(x: 2_000, y: 0),
            windowSize: size,
            visibleFrames: [left, right]
        )
        XCTAssertEqual(
            clamped,
            DisplayTopology.clamp(origin: CGPoint(x: 2_000, y: 0), windowSize: size, into: right),
            "the right display's centre is closer to the dead zone"
        )
    }

    func testUnpluggedDisplayOldSpotRecoversToTheRemainingScreen() {
        let size = CGSize(width: 200, height: 200)
        let clamped = DisplayTopology.clampLooseOrigin(
            CGPoint(x: 5_000, y: 1_500),
            windowSize: size,
            visibleFrames: [left]
        )
        XCTAssertEqual(
            clamped,
            DisplayTopology.clamp(origin: CGPoint(x: 5_000, y: 1_500), windowSize: size, into: left)
        )
    }

    func testEmptyScreenListReturnsOriginUnchanged() {
        let origin = CGPoint(x: 12, y: 34)
        XCTAssertEqual(
            DisplayTopology.clampLooseOrigin(
                origin,
                windowSize: CGSize(width: 10, height: 10),
                visibleFrames: []
            ),
            origin
        )
    }
}
