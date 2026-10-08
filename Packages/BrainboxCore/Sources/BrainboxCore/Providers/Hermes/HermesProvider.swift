import Foundation

/// Placeholder for the Hermes Agent adapter.
///
/// STATUS: PENDING INTEGRATION. This type intentionally does nothing.
///
/// Hermes' real interfaces have not been inspected yet, so no endpoint,
/// message format or authentication scheme is assumed here. The planned
/// design (see docs/HERMES_INTEGRATION.md) is:
///
///     Brainbox app ──Brainbox Agent Protocol──▶ Brainbox Gateway
///                                                  └─ Hermes adapter ──(Hermes native interface)──▶ Hermes
///
/// In that design the app keeps using `RemoteAgentProvider` and this type
/// only exists if we later decide the translation must happen on-device.
/// Until the Hermes installation is inspected it reports itself as
/// unavailable and every call throws `AgentError.notImplemented`.
public final class HermesProvider: AgentProvider, @unchecked Sendable {
    public static let pendingMessage = "The Hermes adapter is pending integration. Use Mock for development, or Remote Agent once the Brainbox gateway is running. See docs/HERMES_INTEGRATION.md."

    private let connection = Broadcaster<ConnectionState>(initial: .failed(.notImplemented(detail: HermesProvider.pendingMessage)))
    private let status = Broadcaster<AgentStatus>(initial: .unavailable(reason: "Pending integration"))

    public init() {}

    public var descriptor: AgentDescriptor {
        AgentDescriptor(id: "hermes", name: "Hermes", kind: .hermes, version: nil, summary: "Pending integration — not connected")
    }

    public var capabilities: Set<ProviderCapability> { [] }

    public func connect() async throws { throw AgentError.notImplemented(detail: Self.pendingMessage) }
    public func disconnect() async {}
    public func connectionUpdates() -> AsyncStream<ConnectionState> { connection.subscribe() }
    public func statusUpdates() -> AsyncStream<AgentStatus> { status.subscribe() }
    public func currentStatus() async -> AgentStatus { status.value }

    public func send(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.failed(.notImplemented(detail: Self.pendingMessage)))
            continuation.finish()
        }
    }

    public func cancel(requestID: UUID) async {}
    public func conversationHistory() async throws -> [ConversationSummary] { throw AgentError.notImplemented(detail: Self.pendingMessage) }
    public func executeTool(_ invocation: ToolInvocation) async throws -> ToolResult { throw AgentError.notImplemented(detail: Self.pendingMessage) }
}
