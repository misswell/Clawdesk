import Foundation
import XCTest
@testable import Clawdesk

/// Click-vs-drag arbitration contract: a press is not a drag, only pointer
/// travel past the threshold is. This is the regression test for "a click
/// must not play the drag affordance or enter Mini Mode near a screen edge"
/// and "pointer jitter must not move the pet window".
final class PetPressGestureTests: XCTestCase {
    func testPressAloneDoesNotStartADrag() {
        var gesture = PetPressGesture()
        gesture.press(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(gesture.isDragging)
        XCTAssertFalse(gesture.release(), "a press-release is a click, not a drag")
    }

    func testJitterBelowThresholdNeverBecomesADrag() {
        var gesture = PetPressGesture()
        gesture.press(at: CGPoint(x: 100, y: 100))
        // ~2.7pt of travel: under the 4pt threshold.
        XCTAssertFalse(gesture.move(to: CGPoint(x: 102, y: 101)))
        XCTAssertFalse(gesture.isDragging)
        XCTAssertFalse(gesture.release(), "below-threshold travel is still a click")
    }

    func testThresholdCrossingStartsTheDragExactlyOnce() {
        var gesture = PetPressGesture()
        gesture.press(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(gesture.move(to: CGPoint(x: 105, y: 100)), "5pt of travel starts the drag")
        XCTAssertFalse(gesture.move(to: CGPoint(x: 110, y: 100)), "later moves keep returning false")
        XCTAssertTrue(gesture.isDragging)
        XCTAssertTrue(gesture.release())
    }

    func testExactThresholdDistanceStartsTheDrag() {
        var gesture = PetPressGesture()
        gesture.press(at: .zero)
        XCTAssertTrue(gesture.move(to: CGPoint(x: PetPressGesture.dragThresholdPoints, y: 0)))
    }

    func testDragReturningToThePressPointStaysADrag() {
        var gesture = PetPressGesture()
        gesture.press(at: CGPoint(x: 100, y: 100))
        _ = gesture.move(to: CGPoint(x: 140, y: 100))
        _ = gesture.move(to: CGPoint(x: 100, y: 100))
        XCTAssertTrue(gesture.isDragging, "a real drag cannot collapse back into a click")
        XCTAssertTrue(gesture.release())
    }

    func testMoveWithoutPressIsIgnored() {
        var gesture = PetPressGesture()
        XCTAssertFalse(gesture.move(to: CGPoint(x: 50, y: 50)))
        XCTAssertFalse(gesture.release())
    }

    func testSecondPressStartsClean() {
        var gesture = PetPressGesture()
        gesture.press(at: .zero)
        _ = gesture.move(to: CGPoint(x: 90, y: 0))
        XCTAssertTrue(gesture.release())
        gesture.press(at: .zero)
        XCTAssertFalse(gesture.isDragging)
        XCTAssertFalse(gesture.release())
    }
}
