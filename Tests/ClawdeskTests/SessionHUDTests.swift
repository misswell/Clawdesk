import Foundation
import XCTest
@testable import Clawdesk

final class SessionHUDTests: XCTestCase {
    func testRowsHideSleepingSessionsAndFoldAfterThreeVisibleRows() {
        let sessions = [
            makeSession(id: "one", state: .typing),
            makeSession(id: "two", state: .idle),
            makeSession(id: "sleep", state: .sleeping),
            makeSession(id: "three", state: .thinking),
            makeSession(id: "four", state: .juggling)
        ]

        let rows = SessionHUDGeometry.rows(from: sessions)

        XCTAssertEqual(rows.sessions.map(\.id), ["one", "two", "three"])
        XCTAssertEqual(rows.overflowCount, 1)
        XCTAssertEqual(SessionHUDGeometry.contentSize(for: rows), CGSize(width: 286, height: 184))
    }

    func testVisibilityRequiresEnabledAndVisibleSessionsUnlessDismissedByPinState() {
        XCTAssertFalse(SessionHUDVisibility.shouldShow(
            enabled: false,
            pinned: true,
            revealed: true,
            hasVisibleSessions: true
        ))
        XCTAssertFalse(SessionHUDVisibility.shouldShow(
            enabled: true,
            pinned: false,
            revealed: false,
            hasVisibleSessions: true
        ))
        XCTAssertTrue(SessionHUDVisibility.shouldShow(
            enabled: true,
            pinned: false,
            revealed: true,
            hasVisibleSessions: true
        ))
        XCTAssertTrue(SessionHUDVisibility.shouldShow(
            enabled: true,
            pinned: true,
            revealed: false,
            hasVisibleSessions: true
        ))
        XCTAssertFalse(SessionHUDVisibility.shouldShow(
            enabled: true,
            pinned: true,
            revealed: true,
            hasVisibleSessions: false
        ))
    }

    func testPetAndHUDHotZoneKeepsThePanelReachable() {
        let pet = CGRect(x: 100, y: 100, width: 120, height: 120)
        let hud = CGRect(x: 50, y: 220, width: 220, height: 100)

        XCTAssertTrue(SessionHUDVisibility.isInsideHotZone(
            CGPoint(x: 80, y: 150), petFrame: pet, hudFrame: hud
        ))
        XCTAssertTrue(SessionHUDVisibility.isInsideHotZone(
            CGPoint(x: 40, y: 270), petFrame: pet, hudFrame: hud
        ))
        XCTAssertFalse(SessionHUDVisibility.isInsideHotZone(
            CGPoint(x: 10, y: 10), petFrame: pet, hudFrame: hud
        ))
        XCTAssertTrue(SessionHUDVisibility.shouldKeepVisible(
            pinned: false,
            petHovering: false,
            hudHovering: true,
            pointerInHotZone: false
        ))
        XCTAssertTrue(SessionHUDVisibility.shouldKeepVisible(
            pinned: false,
            petHovering: false,
            hudHovering: false,
            pointerInHotZone: true
        ))
    }

    func testFrameUsesSpaceBelowPetAndFlipsAboveWhenNeeded() {
        let workArea = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 286, height: 100)

        let below = SessionHUDGeometry.frame(
            for: CGRect(x: 600, y: 300, width: 240, height: 240),
            workArea: workArea,
            contentSize: size
        )
        XCTAssertEqual(below.origin, CGPoint(x: 577, y: 192))

        let above = SessionHUDGeometry.frame(
            for: CGRect(x: 600, y: 20, width: 240, height: 240),
            workArea: workArea,
            contentSize: size
        )
        XCTAssertEqual(above.origin, CGPoint(x: 577, y: 268))
    }

    func testFrameClampsToVisibleScreenEdges() {
        let frame = SessionHUDGeometry.frame(
            for: CGRect(x: -100, y: 400, width: 240, height: 240),
            workArea: CGRect(x: 100, y: 40, width: 800, height: 600),
            contentSize: CGSize(width: 286, height: 100)
        )

        XCTAssertEqual(frame.minX, 110)
        XCTAssertEqual(frame.maxX, 396)
        XCTAssertEqual(frame.minY, 292)
    }

    private func makeSession(id: String, state: PetState) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            agentID: "codex",
            title: id,
            state: state,
            lastEvent: "event"
        )
    }
}
