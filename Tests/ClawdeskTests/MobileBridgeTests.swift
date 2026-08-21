import Foundation
@preconcurrency import Network
import XCTest
@testable import Clawdesk

private enum MobileBridgeTestError: Error {
    case timeout
    case invalidResponse
}

final class MobileBridgeTests: XCTestCase {
    func testTokenIsPersistentHexAndRotationInvalidatesPreviousValue() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-mobile-test-\(UUID().uuidString)")
        let first = MobileBridge(homeDirectory: root)
        let original = first.accessToken
        XCTAssertEqual(original.count, 32)
        XCTAssertTrue(original.allSatisfy(\.isHexDigit))

        let rotated = first.rotateToken()
        XCTAssertNotEqual(rotated, original)
        XCTAssertEqual(MobileBridge(homeDirectory: root).accessToken, rotated)
    }

    func testWebSocketAcceptMatchesRFC6455Example() {
        XCTAssertEqual(
            MobileBridge.webSocketAccept(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testWebSocketHandshakeSnapshotAndIncrementalSessionEvents() async throws {
        let bridge = try await startBridge()
        defer { bridge.stop() }
        bridge.updateSnapshot([
            "state": "thinking",
            "sessions": [[
                "id": "session-1",
                "agentID": "codex",
                "title": "Build Clawdesk",
                "state": "thinking",
                "lastEvent": "UserPromptSubmit",
                "lastActivity": 1.0,
                "recentEvents": ["UserPromptSubmit"]
            ]]
        ])

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try openWebSocket(port: bridge.port, token: bridge.accessToken)
        let initial = try client.receiveText()
        let snapshot = try object(from: initial)
        XCTAssertEqual(snapshot["type"] as? String, "snapshot")
        XCTAssertEqual(snapshot["state"] as? String, "thinking")
        XCTAssertNotNil((snapshot["sessions"] as? [String: Any])?["session-1"])

        bridge.updateSnapshot([
            "state": "attention",
            "sessions": [[
                "id": "session-1",
                "agentID": "codex",
                "title": "Build Clawdesk",
                "state": "attention",
                "lastEvent": "Stop",
                "lastActivity": 2.0
            ]]
        ])
        let state = try object(from: try client.receiveText())
        XCTAssertEqual(state["type"] as? String, "state")
        XCTAssertEqual(state["sessionId"] as? String, "session-1")
        XCTAssertEqual((state["data"] as? [String: Any])?["state"] as? String, "attention")

        bridge.updateSnapshot(["state": "idle", "sessions": []])
        let deleted = try object(from: try client.receiveText())
        XCTAssertEqual(deleted["type"] as? String, "session_deleted")
        XCTAssertEqual(deleted["sessionId"] as? String, "session-1")
        client.close()
    }

    func testConnectionInfoDoesNotExposeTokenAndWrongTokenIsRejected() async throws {
        let bridge = try await startBridge()
        defer { bridge.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let (data, response) = try await request(session: session, port: bridge.port, path: "/api/connection-info")
        XCTAssertEqual(response.statusCode, 200)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(body.contains(bridge.accessToken))
        XCTAssertTrue(body.contains("\"port\""))

        let rejected = RawWebSocketClient(port: bridge.port, token: "0".repeated(32))
        do {
            try rejected.connect()
            XCTFail("A WebSocket with the wrong token must not receive a snapshot")
        } catch RawWebSocketError.httpStatus(let status) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Unexpected wrong-token handshake error: \(error)")
        }
        rejected.close()
    }

    func testWebSocketConnectionLimitIsEnforced() async throws {
        let bridge = try await startBridge()
        defer { bridge.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var clients: [RawWebSocketClient] = []
        for index in 0..<10 {
            let client = try openWebSocket(port: bridge.port, token: bridge.accessToken)
            do {
                _ = try client.receiveText()
            } catch {
                XCTFail("WebSocket client \(index + 1) did not receive its snapshot: \(error)")
                throw error
            }
            clients.append(client)
        }

        let overflow = RawWebSocketClient(port: bridge.port, token: bridge.accessToken)
        do {
            try overflow.connect()
            XCTFail("The eleventh WebSocket must be rejected")
        } catch RawWebSocketError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("Unexpected connection-limit handshake error: \(error)")
        }
        overflow.close()
        clients.forEach { $0.close() }
    }

    func testWebSocketInboundMessagesAreRateLimited() async throws {
        let bridge = try await startBridge()
        defer { bridge.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try openWebSocket(port: bridge.port, token: bridge.accessToken)
        _ = try client.receiveText()

        for _ in 0..<61 {
            try? client.sendText("{}")
        }
        do {
            _ = try client.receiveText(timeout: 2)
            XCTFail("The bridge must close a client after sixty inbound messages per minute")
        } catch MobileBridgeTestError.timeout {
            XCTFail("The bridge did not enforce its inbound message limit promptly")
        } catch RawWebSocketError.closed(let code) {
            XCTAssertEqual(code, 1008)
        } catch {
            XCTFail("Unexpected rate-limit close error: \(error)")
        }
        client.close()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 3
        return URLSession(configuration: configuration)
    }

    private func startBridge() async throws -> MobileBridge {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawdesk-mobile-network-\(UUID().uuidString)")
        let bridge = MobileBridge(homeDirectory: root, preferredPort: UInt16.random(in: 40000...48000))
        bridge.start()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var lastError: Error?
        for _ in 0..<100 {
            do {
                let (_, response) = try await request(session: session, port: bridge.port, path: "/health")
                if response.statusCode == 200 { return bridge }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        bridge.stop()
        throw lastError ?? MobileBridgeTestError.timeout
    }

    private func request(session: URLSession, port: UInt16, path: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw MobileBridgeTestError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw MobileBridgeTestError.invalidResponse }
        return (data, response)
    }

    private func openWebSocket(port: UInt16, token: String) throws -> RawWebSocketClient {
        let client = RawWebSocketClient(port: port, token: token)
        try client.connect()
        return client
    }

    private func object(from text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw MobileBridgeTestError.invalidResponse
        }
        return object
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}

private enum RawWebSocketError: Error {
    case connectionClosed
    case closed(UInt16)
    case invalidHandshake
    case httpStatus(Int)
    case unsupportedFrame
}

private final class RawResultGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw MobileBridgeTestError.timeout
        }
        lock.lock()
        let result = self.result
        lock.unlock()
        guard let result else { throw MobileBridgeTestError.invalidResponse }
        return try result.get()
    }
}

private final class RawWebSocketClient: @unchecked Sendable {
    private struct Frame {
        let opcode: UInt8
        let payload: Data
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "clawdesk-test-websocket", qos: .utility)
    private let token: String
    private var receiveBuffer = Data()
    private var handshakeStarted = false
    private let timeout: TimeInterval

    init(port: UInt16, token: String) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.token = token
        timeout = 3
    }

    func connect() throws {
        let gate = RawResultGate<Void>()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self, !self.handshakeStarted else { return }
                self.handshakeStarted = true
                self.sendHandshake(to: gate)
            case let .failed(error):
                gate.resolve(.failure(error))
            case .cancelled:
                gate.resolve(.failure(RawWebSocketError.connectionClosed))
            default:
                break
            }
        }
        connection.start(queue: queue)
        do {
            _ = try gate.wait(timeout: timeout)
        } catch {
            close()
            throw error
        }
    }

    func receiveText(timeout: TimeInterval = 3) throws -> String {
        let gate = RawResultGate<Frame>()
        receiveNextFrame(to: gate)
        do {
            let frame = try gate.wait(timeout: timeout)
            guard frame.opcode == 0x1, let text = String(data: frame.payload, encoding: .utf8) else {
                throw RawWebSocketError.unsupportedFrame
            }
            return text
        } catch {
            if case MobileBridgeTestError.timeout = error { close() }
            throw error
        }
    }

    func sendText(_ text: String) throws {
        let gate = RawResultGate<Void>()
        connection.send(content: Self.clientFrame(opcode: 0x1, payload: Data(text.utf8)), completion: .contentProcessed { error in
            if let error { gate.resolve(.failure(error)) }
            else { gate.resolve(.success(())) }
        })
        _ = try gate.wait(timeout: 2)
    }

    func close() {
        connection.cancel()
    }

    private func sendHandshake(to gate: RawResultGate<Void>) {
        let request = "GET /ws?token=\(token) HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                gate.resolve(.failure(error))
            } else {
                self.receiveHandshake(to: gate)
            }
        })
    }

    private func receiveHandshake(to gate: RawResultGate<Void>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            if let end = self.receiveBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: self.receiveBuffer.prefix(upTo: end.lowerBound), as: UTF8.self)
                self.receiveBuffer.removeFirst(end.upperBound)
                let status = header.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                guard let status else {
                    gate.resolve(.failure(RawWebSocketError.invalidHandshake))
                    return
                }
                if status == 101 { gate.resolve(.success(())) }
                else { gate.resolve(.failure(RawWebSocketError.httpStatus(status))) }
            } else if isComplete || error != nil {
                gate.resolve(.failure(error ?? RawWebSocketError.connectionClosed))
            } else {
                self.receiveHandshake(to: gate)
            }
        }
    }

    private func receiveNextFrame(to gate: RawResultGate<Frame>) {
        if let frame = nextFrame() {
            switch frame.opcode {
            case 0x1, 0x2:
                gate.resolve(.success(frame))
            case 0x8:
                let code = frame.payload.count >= 2
                    ? UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
                    : 1005
                gate.resolve(.failure(RawWebSocketError.closed(code)))
            case 0x9:
                connection.send(content: Self.clientFrame(opcode: 0xA, payload: frame.payload), completion: .contentProcessed { [weak self] _ in
                    self?.receiveNextFrame(to: gate)
                })
            default:
                gate.resolve(.failure(RawWebSocketError.unsupportedFrame))
            }
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data) }
            if isComplete || error != nil {
                gate.resolve(.failure(error ?? RawWebSocketError.connectionClosed))
            } else {
                self.receiveNextFrame(to: gate)
            }
        }
    }

    private func nextFrame() -> Frame? {
        let bytes = [UInt8](receiveBuffer)
        guard bytes.count >= 2 else { return nil }
        let first = bytes[0]
        let second = bytes[1]
        var length = Int(second & 0x7F)
        var index = 2
        if length == 126 {
            guard bytes.count >= index + 2 else { return nil }
            length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
        } else if length == 127 {
            guard bytes.count >= index + 8 else { return nil }
            var wide: UInt64 = 0
            for _ in 0..<8 { wide = (wide << 8) | UInt64(bytes[index]); index += 1 }
            guard wide <= 1_048_576, wide <= UInt64(Int.max) else {
                receiveBuffer.removeAll()
                return Frame(opcode: 0xFF, payload: Data())
            }
            length = Int(wide)
        }

        let masked = second & 0x80 != 0
        var mask = [UInt8]()
        if masked {
            guard bytes.count >= index + 4 else { return nil }
            mask = Array(bytes[index..<(index + 4)])
            index += 4
        }
        guard bytes.count >= index + length else { return nil }
        var payload = Array(bytes[index..<(index + length)])
        if masked { for offset in payload.indices { payload[offset] ^= mask[offset % 4] } }
        receiveBuffer.removeFirst(index + length)
        return Frame(opcode: first & 0x0F, payload: Data(payload))
    }

    private static func clientFrame(opcode: UInt8, payload: Data) -> Data {
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var frame = Data([0x80 | (opcode & 0x0F)])
        switch payload.count {
        case 0...125:
            frame.append(0x80 | UInt8(payload.count))
        case 126...65_535:
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(0x80 | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
            }
        }
        frame.append(contentsOf: mask)
        var bytes = [UInt8](payload)
        for offset in bytes.indices { bytes[offset] ^= mask[offset % 4] }
        frame.append(contentsOf: bytes)
        return frame
    }
}
