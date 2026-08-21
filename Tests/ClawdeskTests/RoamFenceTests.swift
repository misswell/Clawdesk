import CoreGraphics
import Foundation
import XCTest
@testable import Clawdesk

final class RoamFenceTests: XCTestCase {
    // MARK: - RoamArea JSON parsing

    func testParsesValidFenceWithExplicitEdges() {
        let area = RoamArea(json: ["enabled": true, "left": 0.5, "top": 0.5, "right": 1.0, "bottom": 1.0])
        XCTAssertNotNil(area)
        XCTAssertEqual(area?.left, 0.5)
        XCTAssertEqual(area?.top, 0.5)
        XCTAssertEqual(area?.right, 1.0)
        XCTAssertEqual(area?.bottom, 1.0)
    }

    func testMissingEdgesDefaultToFullRangeButStayNil() {
        let area = RoamArea(json: ["enabled": true])
        XCTAssertNotNil(area)
        XCTAssertNil(area?.left)
        XCTAssertNil(area?.right)
        XCTAssertNil(area?.top)
        XCTAssertNil(area?.bottom)
    }

    func testRejectsMalformedFences() {
        XCTAssertNil(RoamArea(json: ["enabled": "true"]))
        XCTAssertNil(RoamArea(json: ["enabled": true, "left": 0.8, "right": 0.2]))
        XCTAssertNil(RoamArea(json: ["enabled": true, "left": 1.5]))
        XCTAssertNil(RoamArea(json: ["enabled": true, "left": "0.5"]))
        XCTAssertNil(RoamArea(json: ["enabled": true, "top": 1.0, "bottom": 1.0]))
    }

    // MARK: - RoamPlanner containment

    func testPlannerKeepsWindowInsideWorkArea() {
        let workArea = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let target = RoamPlanner.nextTarget(
            currentOrigin: .zero,
            windowSize: CGSize(width: 240, height: 240),
            workArea: workArea,
            fence: nil,
            random: { $0.lowerBound }
        )
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.x, 8)
        XCTAssertEqual(target?.y, 8)
    }

    func testPlannerConfinesTargetToFence() {
        let workArea = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let fence = RoamArea(enabled: true, left: 0.5, top: 0.5, right: 1.0, bottom: 1.0)
        let target = RoamPlanner.nextTarget(
            currentOrigin: .zero,
            windowSize: CGSize(width: 240, height: 240),
            workArea: workArea,
            fence: fence,
            random: { $0.lowerBound }
        )
        XCTAssertEqual(target, CGPoint(x: 500, y: 350))
    }

    func testPlannerHoldsWhenFenceIsTooSmall() {
        let workArea = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let fence = RoamArea(enabled: true, left: 0.9, top: 0, right: 1.0, bottom: 1)
        let target = RoamPlanner.nextTarget(
            currentOrigin: .zero,
            windowSize: CGSize(width: 240, height: 240),
            workArea: workArea,
            fence: fence,
            random: { $0.lowerBound }
        )
        XCTAssertNil(target)
    }

    // MARK: - RoamFenceCoordinator file semantics

    @MainActor
    func testCoordinatorConfirmsValidFileAndKeepsPreviousOnMalformed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-roam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("roam-area.json")

        let coordinator = RoamFenceCoordinator()
        try coordinator.apply(RoamArea(enabled: true, left: 0.5, right: 1.0), to: file)
        coordinator.refresh(from: file)
        XCTAssertTrue(coordinator.confirmed)
        XCTAssertEqual(coordinator.current?.left, 0.5)

        try Data("{\"enabled\":\"yes\"}".utf8).write(to: file)
        coordinator.refresh(from: file)
        XCTAssertEqual(coordinator.current?.left, 0.5, "malformed input must keep the previous fence")
        XCTAssertNotNil(coordinator.lastWarning)
    }

    @MainActor
    func testCoordinatorRequiresTwoConsecutiveMissingChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-roam-del-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("roam-area.json")

        let coordinator = RoamFenceCoordinator()
        try coordinator.apply(RoamArea(enabled: true), to: file)
        try FileManager.default.removeItem(at: file)

        coordinator.refresh(from: file)
        XCTAssertNotNil(coordinator.current, "one missing check is not enough to drop the fence")

        coordinator.refresh(from: file)
        XCTAssertNil(coordinator.current, "two consecutive missing checks confirm deletion")
        XCTAssertTrue(coordinator.confirmed)
    }

    @MainActor
    func testCoordinatorHoldsUntilFirstStatusIsConfirmed() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-roam-missing-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("roam-area.json")

        let coordinator = RoamFenceCoordinator()
        coordinator.refresh(from: file)
        XCTAssertFalse(coordinator.confirmed)
        XCTAssertNil(coordinator.current)
    }
}
