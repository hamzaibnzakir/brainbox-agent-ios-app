import Foundation
import XCTest
@testable import BrainboxCore

/// Interop tests: the real client stack (URLSessionWebSocketTransport +
/// Remote*Provider) against a real Brainbox gateway process.
/// CI starts `gateway/` with the echo adapter and sets:
///   BRAINBOX_LIVE_GATEWAY_URL, BRAINBOX_LIVE_GATEWAY_TOKEN, BRAINBOX_LIVE_FILE_ROOT
/// Skipped everywhere else.
final class LiveGatewayTests: XCTestCase {
    private var connection: GatewayConnection!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["BRAINBOX_LIVE_GATEWAY_URL"], let url = URL(string: raw), let token = env["BRAINBOX_LIVE_GATEWAY_TOKEN"] else {
            throw XCTSkip("Set BRAINBOX_LIVE_GATEWAY_URL/TOKEN to run live gateway interop tests")
        }
        connection = GatewayConnection(
            configuration: GatewayConfiguration(url: url, clientVersion: "live-test", connectTimeout: 10, requestTimeout: 20),
            tokenProvider: { token },
            transportFactory: { URLSessionWebSocketTransport() }
        )
        try await connection.connect()
    }

    override func tearDown() async throws {
        await connection?.disconnect()
    }

    func testChatStreamsThroughRealGateway() async throws {
        let agent = RemoteAgentProvider(connection: connection)
        XCTAssertTrue(agent.capabilities.contains(.streaming))
        let request = AgentRequest(conversationID: UUID(), content: "hello from swift, use a tool")
        var message = Message(role: .assistant, content: "", state: .streaming)
        var events: [AgentEvent] = []
        for try await event in agent.send(request) {
            events.append(event)
            ChatReducer.apply(event, to: &message)
        }
        XCTAssertEqual(events.first, .accepted(requestID: request.requestID))
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(message.state, .complete)
        XCTAssertTrue(message.plainText.contains("hello from swift"), message.plainText)
        XCTAssertEqual(message.toolCalls.first?.status, .succeeded)

        let history = try await agent.conversationHistory()
        XCTAssertTrue(history.contains { $0.id == request.conversationID })
    }

    func testCancelThroughRealGateway() async throws {
        let agent = RemoteAgentProvider(connection: connection)
        let request = AgentRequest(conversationID: UUID(), content: "a reply long enough to cancel " + String(repeating: "word ", count: 200))
        let stream = agent.send(request)
        let collector = Task { () -> [AgentEvent] in
            var all: [AgentEvent] = []
            for try await e in stream { all.append(e) }
            return all
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await agent.cancel(requestID: request.requestID)
        let events = try await collector.value
        XCTAssertEqual(events.last, .failed(.cancelled))
    }

    func testSystemModelsDecodeFromRealGateway() async throws {
        let vps = RemoteVPSProvider(connection: connection)
        let info = try await vps.serverInfo()
        XCTAssertFalse(info.hostname.isEmpty)
        let metrics = try await vps.metrics()
        XCTAssertTrue((0...1).contains(metrics.cpuUsage))
        XCTAssertGreaterThan(metrics.memoryTotalBytes, 0)
        _ = try await vps.processes()
        let services = try await vps.services()
        XCTAssertEqual(services, [])

        var samples = 0
        for try await _ in vps.metricsStream(interval: 0.5) {
            samples += 1
            if samples == 2 { break }
        }
        XCTAssertEqual(samples, 2)

        let logs = RemoteLogProvider(connection: connection)
        _ = try await logs.recent(limit: 10)
    }

    func testFilesThroughRealGateway() async throws {
        guard let root = ProcessInfo.processInfo.environment["BRAINBOX_LIVE_FILE_ROOT"] else { throw XCTSkip("no file root") }
        let files = RemoteFileSystemProvider(connection: connection)
        let roots = try await files.roots()
        XCTAssertTrue(roots.contains { $0.path.hasSuffix(FilePath.lastComponent(of: root)) })
        let path = FilePath.join(root, "swift-\(UUID().uuidString.prefix(6)).yaml")
        _ = try await files.createFile(at: path)
        let first = try await files.write(path, text: "a: 1\n", expectedVersion: nil)
        let read = try await files.read(path)
        XCTAssertEqual(read.text, "a: 1\n")
        XCTAssertEqual(read.version, first.version)
        do {
            _ = try await files.write(path, text: "stale", expectedVersion: "0-0")
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error.asAgentError, .fileConflict(path: path))
        }
        do {
            _ = try await files.read("/etc/shadow")
            XCTFail("expected permission denied")
        } catch {
            guard case .permissionDenied = error.asAgentError else { return XCTFail("\(error)") }
        }
        try await files.delete(path)
    }

    func testTerminalThroughRealGateway() async throws {
        let terminal = RemoteTerminalProvider(connection: connection)
        let session = try await terminal.openSession()
        var output = ""
        var exit: Int?
        for try await chunk in terminal.run("echo live-ok", in: session.id) {
            switch chunk {
            case .stdout(let s), .stderr(let s): output += s
            case .exit(let code): exit = code
            }
        }
        XCTAssertEqual(output, "live-ok\n")
        XCTAssertEqual(exit, 0)
        await terminal.closeSession(session.id)
    }

    func testWrongTokenIsRejectedByRealGateway() async throws {
        let url = connection.configuration.url
        let bad = GatewayConnection(configuration: GatewayConfiguration(url: url, clientVersion: "t", connectTimeout: 5),
                                    tokenProvider: { "definitely-not-the-token-000000" },
                                    transportFactory: { URLSessionWebSocketTransport() })
        do {
            try await bad.connect()
            XCTFail("expected rejection")
        } catch {
            guard case .authenticationFailed = error.asAgentError else { return XCTFail("\(error)") }
        }
    }
}
