import Foundation
import XCTest
@testable import Clawdesk

final class QuotaRingTests: XCTestCase {
    private func report(provider: String, buckets: [(id: String, percent: Int, minutes: Int?)]) -> QuotaReport {
        QuotaReport(
            providerID: provider,
            displayName: provider,
            buckets: buckets.map { QuotaBucket(id: $0.id, usedPercent: $0.percent, windowMinutes: $0.minutes) }
        )
    }

    func testCoinOrdersShortWindowOuterAndWeeklyInner() {
        let r = report(provider: "claude", buckets: [("weekly", 30, 10080), ("fiveHour", 50, 300)])
        let coin = QuotaRingGeometry.coin(for: r)
        XCTAssertEqual(coin?.outerPercent, 50)
        XCTAssertEqual(coin?.innerPercent, 30)
    }

    func testCoinWithoutWeeklyOnlyDrawsOuter() {
        let r = report(provider: "codex", buckets: [("fiveHour", 40, 300)])
        let coin = QuotaRingGeometry.coin(for: r)
        XCTAssertEqual(coin?.outerPercent, 40)
        XCTAssertNil(coin?.innerPercent)
    }

    func testCoinsCapAtFourAndCountOverflow() {
        let reports = (1...6).map { report(provider: "p\($0)", buckets: [("w", $0, 300)]) }
        let result = QuotaRingGeometry.coins(from: reports, show: true)
        XCTAssertEqual(result.coins.count, 4)
        XCTAssertEqual(result.overflow, 2)
    }

    func testShowGateAndHiddenProviders() {
        let reports = [
            report(provider: "claude", buckets: [("w", 10, 300)]),
            report(provider: "codex", buckets: [("w", 20, 300)])
        ]
        XCTAssertTrue(QuotaRingGeometry.coins(from: reports, show: false).coins.isEmpty)
        XCTAssertEqual(
            QuotaRingGeometry.coins(from: reports, show: true, hiddenProviders: ["claude"]).coins.map(\.providerID),
            ["codex"]
        )
    }

    func testClusterSizeScalesWithCoinsAndOverflow() {
        let two = QuotaRingGeometry.clusterSize(coinCount: 2, overflow: 0)
        XCTAssertEqual(two.height, 30 * 2 + 8, accuracy: 0.001)
        let overflow = QuotaRingGeometry.clusterSize(coinCount: 4, overflow: 3)
        XCTAssertGreaterThan(overflow.height, two.height)
    }
}
