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
