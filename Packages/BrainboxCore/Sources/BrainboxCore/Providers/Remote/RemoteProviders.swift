import Foundation

/// Talks the Brainbox Agent Protocol to a gateway. Any backend (Hermes via
/// an adapter, a custom agent, a hosted model wrapper) can sit behind the
/// gateway without the app changing.
public final class RemoteAgentProvider: AgentProvider, @unchecked Sendable {
    public let connection: GatewayConnection

    public init(connection: GatewayConnection) {
        self.connection = connection
    }

    public var descriptor: AgentDescriptor {
        if let agent = connection.welcome?.agent {
            return AgentDescriptor(id: agent.id, name: agent.name, kind: .remote, version: agent.version, summary: "Connected through the Brainbox gateway")
        }
        return AgentDescriptor(id: "remote", name: "Remote Agent", kind: .remote, summary: "Brainbox Agent Protocol over WebSocket")
    }

    public var capabilities: Set<ProviderCapability> {
        connection.welcome?.providerCapabilities ?? []
    }

    public func connect() async throws { try await connection.connect() }
    public func disconnect() async { await connection.disconnect() }
    public func connectionUpdates() -> AsyncStream<ConnectionState> { connection.connectionState.subscribe() }
    public func statusUpdates() -> AsyncStream<AgentStatus> { connection.agentStatus.subscribe() }
    public func currentStatus() async -> AgentStatus { connection.agentStatus.value }

    public func send(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let connection = self.connection
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await connection.ensureConnected()
                    var sawTerminal = false
                    for try await envelope in connection.request(WireCodec.sendFrame(request)) {
                        guard let event = try WireCodec.event(from: envelope) else { continue }
                        continuation.yield(event)
                        if case .completed = event { sawTerminal = true; break }
                        if case .failed = event { sawTerminal = true; break }
                    }
                    if !sawTerminal {
                        continuation.yield(.failed(Task.isCancelled ? .cancelled : .webSocketDisconnected))
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.asAgentError))
                    continuation.finish()
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    Task { try? await connection.sendFrame(WireCodec.cancelFrame(requestID: request.requestID)) }
                }
            }
        }
    }

    public func cancel(requestID: UUID) async {
        try? await connection.sendFrame(WireCodec.cancelFrame(requestID: requestID))
        connection.finishRequest(BrainboxProtocol.id(requestID), throwing: .cancelled)
    }

    public func conversationHistory() async throws -> [ConversationSummary] {
        try await connection.call("conversations.list", as: [ConversationSummary].self)
    }

    public func executeTool(_ invocation: ToolInvocation) async throws -> ToolResult {
        try await connection.call("tool.execute", params: try JSONValue(encoding: invocation), as: ToolResult.self)
    }
}

public final class RemoteVPSProvider: VPSProvider, @unchecked Sendable {
    private let connection: GatewayConnection
    public init(connection: GatewayConnection) { self.connection = connection }

    public func serverInfo() async throws -> ServerInfo { try await connection.call("vps.info", as: ServerInfo.self) }
    public func metrics() async throws -> ServerMetrics { try await connection.call("vps.metrics", as: ServerMetrics.self) }
    public func services() async throws -> [ServiceStatus] { try await connection.call("vps.services", as: [ServiceStatus].self) }
    public func processes() async throws -> [ProcessEntry] { try await connection.call("vps.processes", as: [ProcessEntry].self) }

    public func perform(_ action: ServiceAction, service name: String) async throws -> ServiceStatus {
        try await connection.call("vps.service.action", params: ["name": .string(name), "action": .string(action.rawValue)], as: ServiceStatus.self)
    }

    public func metricsStream(interval: TimeInterval) -> AsyncThrowingStream<ServerMetrics, Error> {
        let upstream = connection.subscribe("vps.metrics", params: ["intervalSeconds": .number(interval)])
        return upstream.decoded(as: ServerMetrics.self)
    }
}

public final class RemoteTerminalProvider: TerminalProvider, @unchecked Sendable {
    private let connection: GatewayConnection
    public init(connection: GatewayConnection) { self.connection = connection }

    public func openSession() async throws -> TerminalSession {
        try await connection.call("terminal.open", as: TerminalSession.self)
    }

    public func closeSession(_ id: UUID) async {
        _ = try? await connection.call("terminal.close", params: ["sessionId": .string(BrainboxProtocol.id(id))])
    }

    public func run(_ command: String, in sessionID: UUID) -> AsyncThrowingStream<TerminalOutput, Error> {
        let upstream = connection.subscribe("terminal.run", params: ["sessionId": .string(BrainboxProtocol.id(sessionID)), "command": .string(command)])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in upstream {
                        switch value["stream"]?.stringValue {
                        case "stdout": continuation.yield(.stdout(value["data"]?.stringValue ?? ""))
                        case "stderr": continuation.yield(.stderr(value["data"]?.stringValue ?? ""))
                        case "exit": continuation.yield(.exit(code: value["code"]?.intValue ?? -1))
                        default: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(sessionID: UUID) async {
        _ = try? await connection.call("terminal.interrupt", params: ["sessionId": .string(BrainboxProtocol.id(sessionID))])
    }
}

public final class RemoteFileSystemProvider: FileSystemProvider, @unchecked Sendable {
    private let connection: GatewayConnection
    public init(connection: GatewayConnection) { self.connection = connection }

    public func roots() async throws -> [FileEntry] { try await connection.call("fs.roots", as: [FileEntry].self) }
    public func list(_ path: String) async throws -> [FileEntry] { try await connection.call("fs.list", params: ["path": .string(path)], as: [FileEntry].self) }
    public func read(_ path: String) async throws -> FileContent { try await connection.call("fs.read", params: ["path": .string(path)], as: FileContent.self) }

    public func write(_ path: String, text: String, expectedVersion: String?) async throws -> FileContent {
        var params: [String: JSONValue] = ["path": .string(path), "text": .string(text)]
        if let expectedVersion { params["expectedVersion"] = .string(expectedVersion) }
        return try await connection.call("fs.write", params: .object(params), as: FileContent.self)
    }

    public func createFile(at path: String) async throws -> FileEntry { try await connection.call("fs.createFile", params: ["path": .string(path)], as: FileEntry.self) }
    public func createDirectory(at path: String) async throws -> FileEntry { try await connection.call("fs.createDirectory", params: ["path": .string(path)], as: FileEntry.self) }
    public func rename(_ path: String, to newName: String) async throws -> FileEntry { try await connection.call("fs.rename", params: ["path": .string(path), "newName": .string(newName)], as: FileEntry.self) }
    public func delete(_ path: String) async throws { _ = try await connection.call("fs.delete", params: ["path": .string(path)]) }
    public func search(_ query: String, in path: String) async throws -> [FileEntry] { try await connection.call("fs.search", params: ["query": .string(query), "path": .string(path)], as: [FileEntry].self) }
}

public final class RemoteLogProvider: LogStreamProvider, @unchecked Sendable {
    private let connection: GatewayConnection
    public init(connection: GatewayConnection) { self.connection = connection }

    public func recent(limit: Int) async throws -> [LogEntry] {
        try await connection.call("logs.recent", params: ["limit": .number(Double(limit))], as: [LogEntry].self)
    }

    public func stream(categories: Set<LogCategory>) -> AsyncThrowingStream<LogEntry, Error> {
        let names = categories.map { JSONValue.string($0.rawValue) }
        return connection.subscribe("logs.stream", params: ["categories": .array(names)]).decoded(as: LogEntry.self)
    }
}

public extension ProviderSuite {
    /// Builds every remote provider over one shared gateway connection.
    static func remote(connection: GatewayConnection) -> ProviderSuite {
        ProviderSuite(
            agent: RemoteAgentProvider(connection: connection),
            vps: RemoteVPSProvider(connection: connection),
            terminal: RemoteTerminalProvider(connection: connection),
            files: RemoteFileSystemProvider(connection: connection),
            logs: RemoteLogProvider(connection: connection)
        )
    }
}

extension AsyncThrowingStream where Element == JSONValue, Failure == Error {
    func decoded<T: Decodable & Sendable>(as type: T.Type) -> AsyncThrowingStream<T, Error> {
        let upstream = self
        return AsyncThrowingStream<T, Error> { continuation in
            let task = Task {
                do {
                    for try await value in upstream {
                        continuation.yield(try value.decode(as: T.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
