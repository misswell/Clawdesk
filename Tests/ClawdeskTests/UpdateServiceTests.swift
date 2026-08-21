import Foundation
import XCTest
@testable import Clawdesk

final class UpdateServiceTests: XCTestCase {
    func testCompatibleMacAssetPrefersNativeArchitectureAndIgnoresSourceArchives() throws {
        let assets = [
            ReleaseAsset(name: "Clawdesk-macos-universal.dmg", downloadURL: try XCTUnwrap(URL(string: "https://example.com/universal.dmg"))),
            ReleaseAsset(name: "Clawdesk-macos-arm64.dmg", downloadURL: try XCTUnwrap(URL(string: "https://example.com/arm64.dmg"))),
            ReleaseAsset(name: "Source code.zip", downloadURL: try XCTUnwrap(URL(string: "https://example.com/source.zip")))
        ]

        let selected = UpdateService.selectCompatibleAsset(assets: assets, platform: "macos", architecture: "arm64")
        XCTAssertEqual(selected?.name, "Clawdesk-macos-arm64.dmg")
        XCTAssertNil(UpdateService.selectCompatibleAsset(assets: assets, platform: "windows", architecture: "arm64"))
    }

    func testReleaseAssetDigestIsOptionalButPreserved() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/Clawdesk.dmg"))
        let digest = String(repeating: "a", count: 64)
        let asset = ReleaseAsset(name: "Clawdesk.dmg", downloadURL: url, size: 42, sha256: digest)

        XCTAssertEqual(asset.sha256, digest)
        XCTAssertEqual(asset.size, 42)
    }
}
