import Foundation
import XCTest
@testable import Clawdesk

final class QuotaTests: XCTestCase {
    func testClaudeStatuslineRateLimitsBecomeUsedPercentageBuckets() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let rateLimits: [String: Any] = [
            "five_hour": ["used_percentage": 61.2, "resets_at": 2_000.0],
            "seven_day": ["used_percentage": 12.4, "resets_at": 3_000.0]
        ]

        let report = try XCTUnwrap(QuotaReportParser.claude(rateLimits: rateLimits, capturedAt: capturedAt))
        XCTAssertEqual(report.providerID, "claude")
        XCTAssertEqual(report.buckets.map(\.id), ["fiveHour", "weekly"])
        XCTAssertEqual(report.buckets.map(\.usedPercent), [61, 12])
        XCTAssertEqual(report.buckets[0].resetAt, Date(timeIntervalSince1970: 2_000))
    }

    func testCodexUsesReportedWindowAndKeepsSparkSeparate() throws {
        let rateLimits: [String: Any] = [
            "limit_id": "codex_bengalfox",
            "primary": ["used_percent": 86, "window_minutes": 300, "resets_in_seconds": 600],
            "secondary": ["used_percent": 42, "window_minutes": 10_080, "resets_in_seconds": 86_400]
        ]
        let now = Date(timeIntervalSince1970: 10_000)
        let report = try XCTUnwrap(QuotaReportParser.codex(rateLimits: rateLimits, capturedAt: now, now: now))

        XCTAssertEqual(report.providerID, "codex-spark")
        XCTAssertEqual(report.buckets.map(\.id), ["fiveHour", "weekly"])
        XCTAssertEqual(report.buckets.map(\.windowMinutes), [300, 10_080])
        XCTAssertEqual(report.buckets[0].resetAt, Date(timeIntervalSince1970: 10_600))
    }

    func testQuotaStoreRejectsOlderReports() {
        let store = QuotaStore(persistenceURL: nil)
        let newer = QuotaReport(
            providerID: "codex",
            displayName: "Codex",
            buckets: [QuotaBucket(id: "fiveHour", usedPercent: 40)],
            capturedAt: Date(timeIntervalSince1970: 20)
        )
        let older = QuotaReport(
            providerID: "codex",
            displayName: "Codex",
            buckets: [QuotaBucket(id: "fiveHour", usedPercent: 90)],
            capturedAt: Date(timeIntervalSince1970: 10)
        )

        _ = store.apply(newer)
        _ = store.apply(older)
        XCTAssertEqual(store.reports.first?.buckets.first?.usedPercent, 40)
    }

    func testQuotaStorePersistsLatestReportForTheNextLaunch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdesk-quota-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let report = QuotaReport(
            providerID: "codex",
            displayName: "Codex",
            buckets: [QuotaBucket(id: "fiveHour", usedPercent: 22, windowMinutes: 300)],
            capturedAt: Date(timeIntervalSince1970: 2_000)
        )
        _ = QuotaStore(persistenceURL: url).apply(report)

        let reloaded = QuotaStore(persistenceURL: url)

        XCTAssertEqual(reloaded.reports.first?.providerID, "codex")
        XCTAssertEqual(reloaded.reports.first?.buckets.first?.usedPercent, 22)
        XCTAssertEqual(reloaded.reports.first?.buckets.first?.displayWindow, "5h")
    }
}
