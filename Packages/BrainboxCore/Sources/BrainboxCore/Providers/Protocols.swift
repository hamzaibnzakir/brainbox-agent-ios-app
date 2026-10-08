import Foundation

/// The single interface between Brainbox Agent's UI and any AI backend.
///
///     Brainbox UI → AgentConnection (app) → AgentProvider → backend
///
/// Implementations: `MockAgentProvider` (development), `RemoteAgentProvider`
/// (Brainbox Agent Protocol over a WebSocket gateway) and `HermesProvider`
/// (pending integration). Nothing in the UI knows which one is active.
public protocol AgentProvider: AnyObject, Sendable {
    var descriptor: AgentDescriptor { get }
    var capabilities: Set<ProviderCapability> { get }

    func connect() async throws
    func disconnect() async

    /// Hot stream of connection state. Each call returns a new subscription
    /// that immediately yields the current state.
    func connectionUpdates() -> AsyncStream<ConnectionState>

    /// Hot stream of agent status changes not tied to a specific request.
    func statusUpdates() -> AsyncStream<AgentStatus>

    func currentStatus() async -> AgentStatus

    /// Sends a user message and streams the response as `AgentEvent`s.
    /// The stream finishes after `.completed` or `.failed`.
    /// Cancelling the consuming task cancels the request.
    func send(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error>

    /// Cancels an in-flight request (stop generation).
    func cancel(requestID: UUID) async

    func conversationHistory() async throws -> [ConversationSummary]

    /// Runs a tool directly (e.g. from a quick action), outside a chat turn.
    func executeTool(_ invocation: ToolInvocation) async throws -> ToolResult
}

/// Server metrics, services and processes.
public protocol VPSProvider: AnyObject, Sendable {
    func serverInfo() async throws -> ServerInfo
    func metrics() async throws -> ServerMetrics
    /// Periodic metrics. Finishes with an error if the backend goes away.
    func metricsStream(interval: TimeInterval) -> AsyncThrowingStream<ServerMetrics, Error>
    func services() async throws -> [ServiceStatus]
    func processes() async throws -> [ProcessEntry]
    func perform(_ action: ServiceAction, service name: String) async throws -> ServiceStatus
}

/// Command execution. No SSH details leak into the UI: the backend decides
/// how commands run (SSH, local shell, sandbox, agent tool...).
public protocol TerminalProvider: AnyObject, Sendable {
    func openSession() async throws -> TerminalSession
    func closeSession(_ id: UUID) async
    /// Streams output for one command. Cancelling the consumer or calling
    /// `cancel(sessionID:)` interrupts the command (SIGINT semantics).
    func run(_ command: String, in sessionID: UUID) -> AsyncThrowingStream<TerminalOutput, Error>
    func cancel(sessionID: UUID) async
}

/// Remote file access. The backend decides which roots are reachable —
/// the app never assumes unrestricted root access.
public protocol FileSystemProvider: AnyObject, Sendable {
    func roots() async throws -> [FileEntry]
    func list(_ path: String) async throws -> [FileEntry]
    func read(_ path: String) async throws -> FileContent
    /// Writes text. `expectedVersion` enables conflict detection.
    @discardableResult
    func write(_ path: String, text: String, expectedVersion: String?) async throws -> FileContent
    func createFile(at path: String) async throws -> FileEntry
    func createDirectory(at path: String) async throws -> FileEntry
    func rename(_ path: String, to newName: String) async throws -> FileEntry
    func delete(_ path: String) async throws
    func search(_ query: String, in path: String) async throws -> [FileEntry]
}

public protocol LogStreamProvider: AnyObject, Sendable {
    func recent(limit: Int) async throws -> [LogEntry]
    func stream(categories: Set<LogCategory>) -> AsyncThrowingStream<LogEntry, Error>
}

/// Bundles every provider a backend offers. The app swaps whole backends
/// (mock ↔ remote ↔ hermes) by swapping one of these.
public struct ProviderSuite: Sendable {
    public var agent: AgentProvider
    public var vps: VPSProvider?
    public var terminal: TerminalProvider?
    public var files: FileSystemProvider?
    public var logs: LogStreamProvider?

    public init(agent: AgentProvider, vps: VPSProvider?, terminal: TerminalProvider?, files: FileSystemProvider?, logs: LogStreamProvider?) {
        self.agent = agent
        self.vps = vps
        self.terminal = terminal
        self.files = files
        self.logs = logs
    }
}
