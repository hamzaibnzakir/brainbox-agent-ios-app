import Foundation
import XCTest
@testable import BrainboxCore

final class GatewayConnectionTests: XCTestCase {
    func testAuthenticatesAndExposesCapabilities() async throws {
        let gateway = FakeGateway()
        let connection = gateway.makeConnection()
        try await connection.connect()

        XCTAssertEqual(connection.connectionState.value, .connected)
        XCTAssertEqual(connection.authenticationState.value, .authenticated(subject: "Fake Agent"))
        let provider = RemoteAgentProvider(connection: connection)
        XCTAssertEqual(provider.descriptor.name, "Fake Agent")
        XCTAssertTrue(provider.capabilities.contains(.streaming))
        XCTAssertTrue(provider.capabilities.contains(.terminal))

        let hello = try XCTUnwrap(gateway.frames(ofType: BrainboxProtocol.ClientType.hello).first)
        XCTAssertEqual(hello.payload["protocolVersion"]?.intValue, BrainboxProtocol.version)
        XCTAssertEqual(hello.payload["platform"]?.stringValue, "ios")
        await connection.disconnect()
    }

    func testRejectedTokenFailsWithoutReconnecting() async throws {
        let gateway = FakeGateway()
        let connection = gateway.makeConnection(token: "wrong-token-0123456789")
        do {
            try await connection.connect()
            XCTFail("Expected authentication failure")
        } catch let error as AgentError {
            guard case .authenticationFailed = error else { return XCTFail("Unexpected \(error)") }
        }
        guard case .failed(let error) = connection.connectionState.value, case .authenticationFailed = error else {
            return XCTFail("State should be failed(auth), got \(connection.connectionState.value)")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gateway.transport.openCount, 1, "Auth failures must not trigger reconnect loops")
    }

    func testMissingTokenIsAnAuthenticationError() async {
        let gateway = FakeGateway()
        let config = GatewayConfiguration(url: URL(string: "wss://x.ts.net")!, clientVersion: "t")
        let transport = gateway.transport
        let connection = GatewayConnection(configuration: config, tokenProvider: { nil }, transportFactory: { transport })
        do {
            try await connection.connect()
            XCTFail("Expected failure")
        } catch {
            guard case .authenticationFailed = error.asAgentError else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(transport.openCount, 0)
    }

    func testStreamsAgentEventsForARequest() async throws {
        let gateway = FakeGateway()
        let conversationID = UUID()
        gateway.handler = { envelope, gw in
            guard envelope.type == BrainboxProtocol.ClientType.send, let raw = envelope.requestId, let rid = UUID(uuidString: raw) else { return }
            let call = ToolCall(id: "t1", kind: .terminal, name: "terminal.run", title: "Checking", input: "uptime")
            let events: [AgentEvent] = [
                .accepted(requestID: rid),
                .status(.thinking),
                .toolStarted(call),
                .toolOutput(toolCallID: "t1", chunk: "up 3 days\n"),
                .toolFinished(toolCallID: "t1", result: ToolResult(output: "up 3 days", exitCode: 0), status: .succeeded),
                .textDelta("All "),
                .textDelta("good."),
                .conversationTitle("Uptime"),
                .completed
            ]
            for event in events { gw.reply(try! WireCodec.envelope(for: event, requestID: rid, conversationID: conversationID)) }
        }
        let connection = gateway.makeConnection()
        let provider = RemoteAgentProvider(connection: connection)
        try await provider.connect()

        let request = AgentRequest(conversationID: conversationID, content: "uptime?")
        let events = try await collect(provider.send(request))

        XCTAssertEqual(events.first, .accepted(requestID: request.requestID))
        XCTAssertEqual(events.last, .completed)
        var message = Message(role: .assistant, content: "", state: .streaming)
        var title: String?
        for event in events { if let t = ChatReducer.apply(event, to: &message).title { title = t } }
        XCTAssertEqual(message.plainText, "All good.")
        XCTAssertEqual(message.segments, [.tool(id: "t1"), .text("All good.")])
        XCTAssertEqual(message.toolCalls.first?.liveOutput, "up 3 days\n")
        XCTAssertEqual(message.toolCalls.first?.status, .succeeded)
        XCTAssertEqual(message.state, .complete)
        XCTAssertEqual(title, "Uptime")

        let sent = try XCTUnwrap(gateway.frames(ofType: BrainboxProtocol.ClientType.send).first)
        XCTAssertEqual(sent.payload["content"]?.stringValue, "uptime?")
        XCTAssertEqual(sent.conversationId, BrainboxProtocol.id(conversationID))
        await provider.disconnect()
    }

    func testRPCCallDecodesResultAndErrors() async throws {
        let gateway = FakeGateway()
        gateway.handler = { envelope, gw in
            guard envelope.type == BrainboxProtocol.ClientType.rpc else { return }
            let method = envelope.payload["method"]?.stringValue
            if method == "fs.list" {
                let entries = [FileEntry(path: "/home/brainbox/a.yaml", isDirectory: false, size: 10)]
                gw.reply(WireEnvelope(type: BrainboxProtocol.ServerType.rpcResult, requestId: envelope.requestId, payload: ["result": try! JSONValue(encoding: entries)]))
            } else {
                gw.reply(WireEnvelope(type: BrainboxProtocol.ServerType.error, requestId: envelope.requestId, payload: try! JSONValue(encoding: ErrorPayload(code: "permission_denied", message: "nope"))))
            }
        }
        let connection = gateway.makeConnection()
        let files = RemoteFileSystemProvider(connection: connection)
        let listing = try await files.list("/home/brainbox")
        XCTAssertEqual(listing.map(\.name), ["a.yaml"])
        XCTAssertEqual(listing.first?.language, .yaml)

        do {
            _ = try await files.read("/root/secret")
            XCTFail("Expected permission error")
        } catch {
            XCTAssertEqual(error.asAgentError, .permissionDenied(detail: "nope"))
        }
        await connection.disconnect()
    }

    func testDropFailsInFlightRequestAndReconnects() async throws {
        let gateway = FakeGateway()
        gateway.handler = { envelope, gw in
            if envelope.type == BrainboxProtocol.ClientType.send, let raw = envelope.requestId, let rid = UUID(uuidString: raw) {
                gw.reply(try! WireCodec.envelope(for: .accepted(requestID: rid), requestID: rid, conversationID: UUID()))
                gw.reply(try! WireCodec.envelope(for: .textDelta("partial"), requestID: rid, conversationID: UUID()))
                // Server dies mid-answer.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gw.transport.serverDrop() }
            }
        }
        let connection = gateway.makeConnection()
        let provider = RemoteAgentProvider(connection: connection)
        try await provider.connect()
        let states = connection.connectionState.subscribe()

        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "hi")))
        XCTAssertEqual(events.last, .failed(.webSocketDisconnected), "In-flight requests fail; they are never replayed")

        _ = try await waitFor(states) { if case .reconnecting = $0 { return true }; return false }
        _ = try await waitFor(connection.connectionState.subscribe()) { $0 == .connected }
        XCTAssertGreaterThanOrEqual(gateway.transport.openCount, 2)
        XCTAssertEqual(gateway.frames(ofType: BrainboxProtocol.ClientType.send).count, 1, "The message must not be re-sent automatically")
        let resumeHello = gateway.frames(ofType: BrainboxProtocol.ClientType.hello).last
        XCTAssertEqual(resumeHello?.payload["resumeSession"]?.stringValue, "sess_1")
        await provider.disconnect()
        XCTAssertEqual(connection.connectionState.value, .disconnected)
    }

    func testCancelSendsCancelFrameAndEndsStream() async throws {
        let gateway = FakeGateway()
        gateway.handler = { envelope, gw in
            if envelope.type == BrainboxProtocol.ClientType.send, let raw = envelope.requestId, let rid = UUID(uuidString: raw) {
                gw.reply(try! WireCodec.envelope(for: .accepted(requestID: rid), requestID: rid, conversationID: UUID()))
                // never completes
            }
        }
        let connection = gateway.makeConnection()
        let provider = RemoteAgentProvider(connection: connection)
        try await provider.connect()
        let request = AgentRequest(conversationID: UUID(), content: "long task")
        let stream = provider.send(request)
        let collector = Task { try await self.collect(stream) }
        await gateway.transport.waitForSentFrames(2) // hello + send
        await provider.cancel(requestID: request.requestID)
        let events = try await collector.value
        XCTAssertEqual(events.last, .failed(.cancelled))
        XCTAssertEqual(gateway.frames(ofType: BrainboxProtocol.ClientType.cancel).first?.requestId, BrainboxProtocol.id(request.requestID))
        await provider.disconnect()
    }

    func testSubscriptionStreamsDecodedValues() async throws {
        let gateway = FakeGateway()
        gateway.handler = { envelope, gw in
            guard envelope.type == BrainboxProtocol.ClientType.subscribe else { return }
            for i in 0..<3 {
                let entry = LogEntry(level: .info, category: .gateway, source: "gw", message: "line \(i)")
                gw.reply(WireEnvelope(type: BrainboxProtocol.ServerType.streamData, requestId: envelope.requestId, payload: try! JSONValue(encoding: entry)))
            }
            gw.reply(WireEnvelope(type: BrainboxProtocol.ServerType.streamEnd, requestId: envelope.requestId))
        }
        let connection = gateway.makeConnection()
        let logs = RemoteLogProvider(connection: connection)
        var messages: [String] = []
        for try await entry in logs.stream(categories: [.gateway]) { messages.append(entry.message) }
        XCTAssertEqual(messages, ["line 0", "line 1", "line 2"])
        let subscribe = try XCTUnwrap(gateway.frames(ofType: BrainboxProtocol.ClientType.subscribe).first)
        XCTAssertEqual(subscribe.payload["method"]?.stringValue, "logs.stream")
        await connection.disconnect()
    }

    func testURLSessionTransportRejectsNonWebSocketSchemes() async {
        let transport = URLSessionWebSocketTransport()
        do {
            try await transport.open(url: URL(string: "https://example.com")!, headers: [:])
            XCTFail("Expected rejection")
        } catch {
            guard case .unableToConnect = error.asAgentError else { return XCTFail("Unexpected \(error)") }
        }
    }
}
