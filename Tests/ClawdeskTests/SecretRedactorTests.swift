import XCTest
@testable import Clawdesk

final class SecretRedactorTests: XCTestCase {
    func testRedactsProviderTokenShapes() {
        XCTAssertEqual(
            SecretRedactor.redact("key sk-proj-abc123def456 end"),
            "key <redacted:token> end"
        )
        XCTAssertEqual(
            SecretRedactor.redact("xoxb-1234567890abcdef"),
            "<redacted:token>"
        )
        XCTAssertEqual(
            SecretRedactor.redact("ghp_abcdefghijklmnopqrst"),
            "<redacted:token>"
        )
        XCTAssertEqual(
            SecretRedactor.redact("AIzaSyA1234567890abcdefghijklmnopqrstu"),
            "<redacted:token>"
        )
        XCTAssertEqual(
            SecretRedactor.redact("1234567890:ABCdefGHI_jkl-MNOPQRstu"),
            "<redacted:telegram-token>"
        )
    }

    func testRedactsAuthorizationHeadersAndSecretNamedPairs() {
        XCTAssertTrue(SecretRedactor.redact("authorization: Bearer abc123").hasPrefix("authorization=<redacted>"))
        XCTAssertEqual(
            SecretRedactor.redact("api_key = \"super-secret-value\""),
            "api_key=<redacted>"
        )
        XCTAssertEqual(
            SecretRedactor.redact("ANTHROPIC_API_KEY: sk-123456789012"),
            "ANTHROPIC_API_KEY=<redacted>"
        )
    }

    func testRedactsSlackWebhookURLsButKeepsProse() {
        XCTAssertTrue(SecretRedactor.redact("post to https://hooks.slack.com/services/T00/B00/XXXXXXXX").contains("<redacted:slack-webhook>"))
        // Ordinary prose with the word "secret" but no key=value shape survives.
        XCTAssertEqual(SecretRedactor.redact("basic authentication is used"), "basic authentication is used")
    }

    func testLocalEventServerScrubsAssistantOutput() {
        XCTAssertEqual(
            LocalEventServer.scrubbedAssistantOutput("line1\nline2\u{7}"),
            "line1 line2 "
        )
        let long = String(repeating: "a", count: 3_000)
        XCTAssertEqual(LocalEventServer.scrubbedAssistantOutput(long).count, 2_400)
    }
}
