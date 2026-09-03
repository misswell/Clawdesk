import Foundation
import XCTest
@testable import Clawdesk

final class SoftwareUpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertLessThan(ClawdeskVersion("0.1.0")!, ClawdeskVersion("0.1.1")!)
        XCTAssertLessThan(ClawdeskVersion("0.1.9")!, ClawdeskVersion("0.2.0")!)
        XCTAssertLessThan(ClawdeskVersion("1.0.0")!, ClawdeskVersion("1.0.0.1")!)
        XCTAssertEqual(ClawdeskVersion("1.0.0"), ClawdeskVersion("v1.0.0"))
        XCTAssertNil(ClawdeskVersion("abc"))
        XCTAssertNil(ClawdeskVersion("1.2.x"))
    }

    func testReleaseDecodeRequiresMatchingArchiveAndDigest() throws {
        let json: [String: Any] = [
            "tag_name": "v0.2.0",
            "body": "notes",
            "draft": false,
            "prerelease": false,
            "assets": [[
                "name": "Clawdesk-0.2.0-macos.zip",
                "browser_download_url": "https://example.com/Clawdesk-0.2.0-macos.zip",
                "digest": "sha256:" + String(repeating: "a", count: 64)
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let release = try ClawdeskRelease.decodeGitHubResponse(data)
        XCTAssertEqual(release.version.description, "0.2.0")
        XCTAssertTrue(release.isNewer(than: "0.1.1"))
        XCTAssertFalse(release.isNewer(than: "0.3.0"))
        XCTAssertEqual(release.sha256.count, 64)
    }

    func testReleaseDecodeRejectsMismatchedArchiveName() {
        let json: [String: Any] = [
            "tag_name": "v0.2.0",
            "body": nil as String?,
            "draft": false,
            "prerelease": false,
            "assets": [[
                "name": "other.zip",
                "browser_download_url": "https://example.com/other.zip",
                "digest": "sha256:" + String(repeating: "a", count: 64)
            ]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try ClawdeskRelease.decodeGitHubResponse(data))
    }
}

@MainActor
final class UpdateDismissalTests: XCTestCase {
    private func makeUpdater(defaults: UserDefaults) -> ClawdeskSoftwareUpdater {
        ClawdeskSoftwareUpdater(
            currentVersion: "0.1.0",
            session: URLSession.shared,
            applicationURL: URL(fileURLWithPath: "/tmp/Clawdesk.app"),
            defaults: defaults
        )
    }

    func testDismissedVersionIsReportedAndPrunedAfterCatchUp() {
        let suite = "clawdesk-update-dismissal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let updater = makeUpdater(defaults: defaults)

        XCTAssertFalse(updater.pendingUpdateIsDismissed)

        // Simulate postponing a pending release by injecting the state the
        // check would produce, then dismissing it.
        updater.markAvailableForTesting(ClawdeskRelease(
            version: ClawdeskVersion("0.2.0")!,
            releaseNotes: "",
            archiveURL: URL(string: "https://example.com/x.zip")!,
            sha256: String(repeating: "a", count: 64)
        ))
        updater.dismissPendingUpdate()
        XCTAssertTrue(updater.dismissedVersions.contains("0.2.0"))
        XCTAssertEqual(updater.state, .upToDate)

        // Re-checking flags the release again, but the dismissal is visible
        // to prompt paths so background checks stay quiet.
        updater.markAvailableForTesting(ClawdeskRelease(
            version: ClawdeskVersion("0.2.0")!,
            releaseNotes: "",
            archiveURL: URL(string: "https://example.com/x.zip")!,
            sha256: String(repeating: "a", count: 64)
        ))
        XCTAssertTrue(updater.pendingUpdateIsDismissed)

        // Once the running version catches up, the stale dismissal is pruned.
        let caughtUp = ClawdeskSoftwareUpdater(
            currentVersion: "0.2.0",
            session: URLSession.shared,
            applicationURL: URL(fileURLWithPath: "/tmp/Clawdesk.app"),
            defaults: defaults
        )
        caughtUp.pruneDismissalsForTesting()
        XCTAssertFalse(caughtUp.dismissedVersions.contains("0.2.0"))
        defaults.removePersistentDomain(forName: suite)
    }
}
