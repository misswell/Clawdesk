import Foundation
import XCTest
@testable import Clawdesk

/// Clawdesk Behavior: fresh sessions earn a one-shot wink, launch never does.
final class SessionArrivalTests: XCTestCase {
    private func session(_ id: String) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            agentID: "claude-code",
            title: "session \(id)",
            state: .idle,
            lastEvent: "connect"
        )
    }

    func testLaunchBatchSeedsWithoutCelebrating() {
        var tracker = SessionArrivalTracker()
        XCTAssertEqual(tracker.arrivals(in: [session("a"), session("b")]), [])
        // Re-emitting the same sessions never celebrates.
        XCTAssertEqual(tracker.arrivals(in: [session("a"), session("b")]), [])
    }

    func testFreshSessionArrivesExactlyOnce() {
        var tracker = SessionArrivalTracker()
        _ = tracker.arrivals(in: [session("a")])
        XCTAssertEqual(tracker.arrivals(in: [session("a"), session("b")]), ["b"])
        XCTAssertEqual(tracker.arrivals(in: [session("a"), session("b")]), [])
    }

    func testEmptyBatchKeepsTheSeededState() {
        var tracker = SessionArrivalTracker()
        XCTAssertEqual(tracker.arrivals(in: []), [])
        // Still the first batch afterwards: seeding has not happened yet.
        XCTAssertEqual(tracker.arrivals(in: [session("a")]), [])
        XCTAssertEqual(tracker.arrivals(in: [session("b")]), ["b"])
    }

    func testDisappearingSessionDoesNotResurrect() {
        var tracker = SessionArrivalTracker()
        _ = tracker.arrivals(in: [session("a"), session("b")])
        // b ends, then a session with the same id returns (terminal restart):
        // it is genuinely new again and may be celebrated.
        _ = tracker.arrivals(in: [session("a")])
        XCTAssertEqual(tracker.arrivals(in: [session("a"), session("b")]), ["b"])
    }
}
