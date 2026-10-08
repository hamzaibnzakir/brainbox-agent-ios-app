import Foundation
import XCTest
@testable import BrainboxCore

/// Scripted Brainbox gateway on top of the in-memory transport.
final class FakeGateway: @unchecked Sendable {
    let transport = InMemoryWebSocketTransport()
    let validToken = "test-token-0123456789abcdef"
    let received = Locked<[WireEnvelope]>([])
    var handler: ((WireEnvelope, FakeGateway) -> Void)?
    var capabilities: [String] = ["streaming", "cancellation", "toolExecution", "terminal"]

    init() {
        transport.onClientFrame = { [weak self] text in
            guard let self, let envelope = try? WireEnvelope.decode(text) else { return }
            self.received.withLock { $0.append(envelope) }
            if envelope.type == BrainboxProtocol.ClientType.hello {
                let token = envelope.payload["token"]?.stringValue
                if token == self.validToken {
                    let ok = AuthOKPayload(session: "sess_1", agent: AgentDescriptorPayload(id: "fake", name: "Fake Agent", version: "1.0"), capabilities: self.capabilities, heartbeatSeconds: 30)
                    self.transport.serverSend(WireEnvelope(type: BrainboxProtocol.ServerType.authOK, payload: try! JSONValue(encoding: ok)))
                } else {
                    self.transport.serverSend(WireEnvelope(type: BrainboxProtocol.ServerType.authError, payload: try! JSONValue(encoding: ErrorPayload(code: "auth_failed", message: "bad token"))))
                }
                return
            }
            self.handler?(envelope, self)
        }
    }

    func reply(_ envelope: WireEnvelope) { transport.serverSend(envelope) }

    func frames(ofType type: String) -> [WireEnvelope] {
        received.withLock { $0.filter { $0.type == type } }
    }

    func makeConnection(token: String? = nil, policy: ReconnectPolicy = ReconnectPolicy(initialDelay: 0.01, multiplier: 1, maxDelay: 0.01, maxAttempts: 50, jitter: 0)) -> GatewayConnection {
        let config = GatewayConfiguration(url: URL(string: "wss://gateway.example.ts.net/v1/agent")!, clientVersion: "test", connectTimeout: 2, requestTimeout: 2, heartbeatInterval: 30, reconnectPolicy: policy)
        let tokenValue = token ?? validToken
        let transport = self.transport
        return GatewayConnection(configuration: config, tokenProvider: { tokenValue }, transportFactory: { transport })
    }
}

extension XCTestCase {
    /// Waits until `stream` yields a value matching `predicate`.
    func waitFor<T: Sendable>(_ stream: AsyncStream<T>, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line, where predicate: @escaping @Sendable (T) -> Bool) async throws -> T {
        let result = try await Timeout.run(seconds: timeout) { () -> T? in
            for await value in stream where predicate(value) { return value }
            return nil
        }
        guard let result else {
            XCTFail("Stream ended before the expected value", file: file, line: line)
            throw AgentError.timedOut
        }
        return result
    }

    func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>, timeout: TimeInterval = 5) async throws -> [AgentEvent] {
        try await Timeout.run(seconds: timeout) {
            var events: [AgentEvent] = []
            for try await event in stream { events.append(event) }
            return events
        }
    }
}
