import Foundation
import XCTest
@testable import Clawdesk

final class PermissionPolicyTests: XCTestCase {
    private func request(action: String?, command: String? = nil) -> PermissionRequest {
        PermissionRequest(sessionID: "s", agentID: "claude-code", title: "t", action: action, command: command)
    }

    func testOffDefersEverything() {
        XCTAssertNil(PermissionPolicy.decide(request: request(action: "Read"), automation: .off))
        XCTAssertNil(PermissionPolicy.decide(request: request(action: "Bash"), automation: .off))
    }

    func testAutoToolsAllowsReadOnlyAndDefersUnknown() {
        XCTAssertEqual(PermissionPolicy.decide(request: request(action: "Read"), automation: .autoTools), .allow)
        XCTAssertEqual(PermissionPolicy.decide(request: request(action: "Glob"), automation: .autoTools), .allow)
        XCTAssertNil(PermissionPolicy.decide(request: request(action: "Bash"), automation: .autoTools))
        XCTAssertNil(PermissionPolicy.decide(request: request(action: nil), automation: .autoTools))
    }

    func testUnattendedAllowsReadOnlyAndDeniesUnknown() {
        XCTAssertEqual(PermissionPolicy.decide(request: request(action: "Read"), automation: .unattended), .allow)
        XCTAssertEqual(PermissionPolicy.decide(request: request(action: "Bash"), automation: .unattended), .deny)
        XCTAssertEqual(PermissionPolicy.decide(request: request(action: nil), automation: .unattended), .deny)
    }

    func testDecisionUsesToolNameNotCommandText() {
        // A Bash request whose command happens to look read-only must never be
        // auto-approved based on the command content.
        let bash = request(action: "Bash", command: "ls -la")
        XCTAssertNil(PermissionPolicy.decide(request: bash, automation: .autoTools))
        XCTAssertEqual(PermissionPolicy.decide(request: bash, automation: .unattended), .deny)
    }
}
