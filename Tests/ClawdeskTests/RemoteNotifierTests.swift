import Foundation
import XCTest
@testable import Clawdesk

@MainActor
final class RemoteNotifierTests: XCTestCase {
    func testLegacySettingsDecodeWithoutApprovalKeys() throws {
        let data = Data(#"{"enabled":true,"telegramChatID":"12345"}"#.utf8)
        let settings = try JSONDecoder().decode(RemoteChannelSettings.self, from: data)

        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.telegramChatID, "12345")
        XCTAssertFalse(settings.telegramApprovalEnabled)
        XCTAssertNil(settings.telegramApprovalUserID)
        XCTAssertEqual(settings.telegramApprovalTimeoutSeconds, 60)
        XCTAssertFalse(settings.feishuApprovalEnabled)
        XCTAssertEqual(settings.feishuPlatform, "feishu")
        XCTAssertEqual(settings.feishuApproverIDType, "open_id")
    }

    func testFeishuCardAndCallbackRequireConfiguredApprover() throws {
        var settings = RemoteChannelSettings()
        settings.feishuApprovalEnabled = true
        settings.feishuAppID = "cli_test"
        settings.feishuAppSecret = "secret"
        settings.feishuApproverID = "ou_allowed"

        let request = PermissionRequest(
            id: "request-feishu",
            sessionID: "session-1",
            agentID: "claude-code",
            title: "Run a tool",
            command: "echo safe"
        )
        let card = FeishuApprovalTransport.approvalCard(for: request)
        let body = try JSONSerialization.data(withJSONObject: card)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("request-feishu"))
        XCTAssertTrue(text.contains("Allow"))
        XCTAssertTrue(text.contains("Deny"))

        let event: [String: Any] = [
            "event": [
                "operator": ["operator_id": ["open_id": "ou_allowed"]],
                "action": ["value": #"{"requestID":"request-feishu","decision":"allow"}"#]
            ]
        ]
        XCTAssertEqual(
            FeishuApprovalTransport.parseApprovalAction(event, settings: settings)?.decision,
            .allow
        )

        var unauthorized = event
        unauthorized["event"] = [
            "operator": ["operator_id": ["open_id": "ou_other"]],
            "action": ["value": #"{"requestID":"request-feishu","decision":"allow"}"#]
        ]
        XCTAssertNil(FeishuApprovalTransport.parseApprovalAction(unauthorized, settings: settings))
    }

    func testFeishuFrameCodecRoundTripsHeadersAndPayload() throws {
        let frame = FeishuFrameCodec.Frame(
            sequenceID: 7,
            logID: 9,
            serviceID: 3,
            method: 1,
            headers: [
                .init(key: "type", value: "event"),
                .init(key: "message_id", value: "m-1")
            ],
            payload: Data("{\"ok\":true}".utf8)
        )

        let decoded = try FeishuFrameCodec.decode(FeishuFrameCodec.encode(frame))
        XCTAssertEqual(decoded, frame)
    }

    func testTelegramCallbackParserAcceptsOnlyAllowAndDeny() {
        XCTAssertEqual(
            RemoteNotifier.parseTelegramApprovalCallback("clawdesk:req-1:allow")?.decision,
            .allow
        )
        XCTAssertEqual(
            RemoteNotifier.parseTelegramApprovalCallback("clawdesk:req-1:deny")?.decision,
            .deny
        )
        XCTAssertNil(RemoteNotifier.parseTelegramApprovalCallback("clawdesk:req-1:defer"))
        XCTAssertNil(RemoteNotifier.parseTelegramApprovalCallback("other:req-1:allow"))
        XCTAssertNil(RemoteNotifier.parseTelegramApprovalCallback("clawdesk::allow"))
    }

    func testApprovalPayloadUsesOpaqueCallbackAndBoundedPlainText() throws {
        let request = PermissionRequest(
            id: "request-1",
            sessionID: "session-1",
            agentID: "claude-code",
            title: String(repeating: "x", count: 2_000),
            command: "echo safe"
        )

        let payload = RemoteNotifier.telegramApprovalPayload(for: request)
        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertLessThanOrEqual(text.count, 3_500)
        XCTAssertTrue(text.contains("Clawdesk permission request"))

        let markup = try XCTUnwrap(payload["reply_markup"] as? [String: Any])
        let keyboard = try XCTUnwrap(markup["inline_keyboard"] as? [[Any]])
        let buttons = try XCTUnwrap(keyboard.first as? [[String: Any]])
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(buttons[0]["callback_data"] as? String, "clawdesk:request-1:allow")
        XCTAssertEqual(buttons[1]["callback_data"] as? String, "clawdesk:request-1:deny")
    }

    func testApprovalPayloadNeverCarriesCommandsOrSecrets() {
        let request = PermissionRequest(
            id: "request-2",
            sessionID: "session-2",
            agentID: "claude-code",
            title: "Run deployment",
            action: "Bash",
            command: "curl -H \"Authorization: Bearer sk-abcdefghijklmnopqrst\" https://example.com",
            input: "/tmp/build/out.log sk-proj-abcdefghijklmnopqrst"
        )

        let payload = RemoteNotifier.telegramApprovalPayload(for: request)
        let text = payload["text"] as? String ?? ""
        // Upstream rule: commands and raw tool input never leave the desktop.
        XCTAssertFalse(text.contains("curl"))
        XCTAssertFalse(text.contains("sk-proj-"), "provider tokens must be stripped even from fallback text")
        XCTAssertTrue(text.contains("Action: Bash"))
        // A path-shaped target survives as the bounded fallback summary.
        XCTAssertTrue(text.contains("/tmp/build/out.log"))
    }

    func testFallbackDetailExtractsOnlyPathLikeTargets() {
        XCTAssertEqual(RemoteNotifier.fallbackDetail(from: "writing /Users/me/notes.txt now"), "/Users/me/notes.txt")
        XCTAssertEqual(RemoteNotifier.fallbackDetail(from: "~/docs/report.md"), "~/docs/report.md")
        XCTAssertEqual(RemoteNotifier.fallbackDetail(from: "see https://example.com/x"), "https://example.com/x")
        XCTAssertNil(RemoteNotifier.fallbackDetail(from: "echo hello world"))
        XCTAssertNil(RemoteNotifier.fallbackDetail(from: nil))
    }
}
