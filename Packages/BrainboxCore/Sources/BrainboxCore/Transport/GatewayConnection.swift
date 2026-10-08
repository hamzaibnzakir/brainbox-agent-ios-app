import Foundation

public struct GatewayConfiguration: Sendable, Hashable {
    /// e.g. wss://brainbox-gateway.tailnet-name.ts.net/v1/agent
    public var url: URL
    public var clientVersion: String
    public var connectTimeout: TimeInterval
    public var requestTimeout: TimeInterval
    public var heartbeatInterval: TimeInterval
    public var reconnectPolicy: ReconnectPolicy

    public init(url: URL, clientVersion: String, connectTimeout: TimeInterval = 15, requestTimeout: TimeInterval = 45, heartbeatInterval: TimeInterval = 20, reconnectPolicy: ReconnectPolicy = .standard) {
        self.url = url
        self.clientVersion = clientVersion
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.heartbeatInterval = heartbeatInterval
        self.reconnectPolicy = reconnectPolicy
    }
}

/// Owns one authenticated WebSocket to a Brainbox gateway and multiplexes
/// agent requests, RPC calls and subscriptions over it by `requestId`.
///
/// Reconnection: on any unexpected drop, all in-flight requests fail with
/// `.webSocketDisconnected` (they are never replayed — a half-run command
/// must not silently run twice) and the connection re-establishes itself
/// with exponential backoff until `disconnect()` is called or
/// authentication is rejected.
public final class GatewayConnection: @unchecked Sendable {
    public let configuration: GatewayConfiguration
    public let connectionState = Broadcaster<ConnectionState>(initial: .disconnected)
    public let authenticationState = Broadcaster<AuthenticationState>(initial: .unauthenticated)
    public let agentStatus = Broadcaster<AgentStatus>(initial: .offline)

    private let tokenProvider: @Sendable () -> String?
    private let makeTransport: TransportFactory

    private struct State {
        var transport: WebSocketTransport?
        var generation = 0
        var wantsConnection = false
        var isEstablishing = false
        var session: String?
        var welcome: AuthOKPayload?
        var pending: [String: AsyncThrowingStream<WireEnvelope, Error>.Continuation] = [:]
        var loops: [Task<Void, Never>] = []
        var reconnectTask: Task<Void, Never>?
    }

    private let state = Locked(State())

    public init(configuration: GatewayConfiguration, tokenProvider: @escaping @Sendable () -> String?, transportFactory: @escaping TransportFactory) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.makeTransport = transportFactory
    }

    deinit {
        let s = state.current
        s.loops.forEach { $0.cancel() }
        s.reconnectTask?.cancel()
        s.transport?.close()
    }

    public var welcome: AuthOKPayload? { state.withLock { $0.welcome } }
    public var isConnected: Bool { connectionState.value == .connected }

    // MARK: Lifecycle

    public func connect() async throws {
        let shouldStart = state.withLock { s -> Bool in
            s.wantsConnection = true
            if s.transport != nil || s.isEstablishing { return false }
            s.isEstablishing = true
            return true
        }
        guard shouldStart else {
            try await waitUntilConnected()
            return
        }
        connectionState.send(.connecting)
        do {
            try await establish()
        } catch {
            let agentError = error.asAgentError
            state.withLock { $0.isEstablishing = false }
            if agentError.isRetryable {
                scheduleReconnect(startingAt: 1)
            } else {
                state.withLock { $0.wantsConnection = false }
                connectionState.send(.failed(agentError))
            }
            throw agentError
        }
    }

    /// Intentional disconnect: stops reconnecting and fails in-flight work.
    public func disconnect() async {
        let (transport, loops, reconnect) = state.withLock { s -> (WebSocketTransport?, [Task<Void, Never>], Task<Void, Never>?) in
            s.wantsConnection = false
            s.generation += 1
            let t = s.transport
            s.transport = nil
            let l = s.loops
            s.loops = []
            let r = s.reconnectTask
            s.reconnectTask = nil
            return (t, l, r)
        }
        reconnect?.cancel()
        loops.forEach { $0.cancel() }
        transport?.close()
        failAllPending(with: .webSocketDisconnected)
        agentStatus.send(.offline)
        connectionState.send(.disconnected)
    }

    /// Called when the app returns to the foreground or the network comes
    /// back: skips any remaining backoff and tries immediately.
    public func reconnectNow() {
        let shouldKick = state.withLock { s -> Bool in
            guard s.wantsConnection, s.transport == nil, !s.isEstablishing else { return false }
            s.reconnectTask?.cancel()
            s.reconnectTask = nil
            return true
        }
        if shouldKick { scheduleReconnect(startingAt: 1, immediate: true) }
    }

    private func waitUntilConnected() async throws {
        for await value in connectionState.subscribe() {
            switch value {
            case .connected: return
            case .failed(let error): throw error
            case .disconnected:
                if !state.withLock({ $0.wantsConnection }) { throw AgentError.webSocketDisconnected }
            default: continue
            }
        }
        throw AgentError.webSocketDisconnected
    }

    private func establish() async throws {
        guard let token = tokenProvider(), !token.isEmpty else {
            authenticationState.send(.failed(reason: "No access token saved"))
            throw AgentError.authenticationFailed(detail: "Add the gateway access token in Settings → Connection.")
        }
        authenticationState.send(.authenticating)
        let transport = makeTransport()
        let timedOut = Locked(false)
        let watchdog = Task { [configuration] in
            try? await Task.sleep(nanoseconds: UInt64(configuration.connectTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            transport.close()
        }
        defer { watchdog.cancel() }

        let welcome: AuthOKPayload
        do {
            try await transport.open(url: configuration.url, headers: ["Sec-WebSocket-Protocol": "brainbox.v\(BrainboxProtocol.version)"])
            let resume = state.withLock { $0.session }
            let hello = WireEnvelope(
                type: BrainboxProtocol.ClientType.hello,
                payload: try JSONValue(encoding: HelloPayload(token: token, clientVersion: configuration.clientVersion, resumeSession: resume))
            )
            try await transport.send(try hello.encodedString())
            let reply = try WireEnvelope.decode(try await transport.receive())
            switch reply.type {
            case BrainboxProtocol.ServerType.authOK:
                welcome = try reply.payload.decode(as: AuthOKPayload.self)
            case BrainboxProtocol.ServerType.authError, BrainboxProtocol.ServerType.error:
                let payload = (try? reply.payload.decode(as: ErrorPayload.self)) ?? ErrorPayload(code: "auth_failed", message: "The gateway rejected the access token.")
                transport.close()
                authenticationState.send(.failed(reason: payload.message))
                throw AgentError.authenticationFailed(detail: payload.message)
            default:
                transport.close()
                throw AgentError.protocolViolation(detail: "Expected auth.ok, got \(reply.type).")
            }
        } catch {
            transport.close()
            if timedOut.current { throw AgentError.timedOut }
            throw error
        }

        let generation = state.withLock { s -> Int in
            s.generation += 1
            s.transport = transport
            s.session = welcome.session
            s.welcome = welcome
            s.isEstablishing = false
            return s.generation
        }
        authenticationState.send(.authenticated(subject: welcome.agent.name))
        agentStatus.send(.ready)
        connectionState.send(.connected)
        startLoops(transport: transport, generation: generation, heartbeat: welcome.heartbeatSeconds ?? configuration.heartbeatInterval)
    }

    private func startLoops(transport: WebSocketTransport, generation: Int, heartbeat: TimeInterval) {
        let receive = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await transport.receive()
                    self?.handle(text: text, generation: generation)
                } catch {
                    self?.handleDrop(generation: generation, error: error.asAgentError)
                    return
                }
            }
        }
        let ping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(heartbeat, 1) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let frame = try? WireEnvelope(type: BrainboxProtocol.ClientType.ping).encodedString() else { continue }
                do {
                    try await transport.send(frame)
                } catch {
                    transport.close() // receive loop observes the drop
                    return
                }
                _ = self
            }
        }
        state.withLock { $0.loops = [receive, ping] }
    }

    private func handle(text: String, generation: Int) {
        guard let envelope = try? WireEnvelope.decode(text) else { return }
        guard state.withLock({ $0.generation == generation }) else { return }

        if envelope.type == BrainboxProtocol.ServerType.status, envelope.requestId == nil {
            agentStatus.send(WireCodec.decodeStatus(envelope.payload))
            return
        }
        if envelope.type == BrainboxProtocol.ServerType.pong { return }

        guard let requestId = envelope.requestId else { return }
        let terminal = WireCodec.isTerminal(envelope.type)
        let continuation = state.withLock { s -> AsyncThrowingStream<WireEnvelope, Error>.Continuation? in
            terminal ? s.pending.removeValue(forKey: requestId) : s.pending[requestId]
        }
        guard let continuation else { return }
        if envelope.type == BrainboxProtocol.ServerType.status {
            agentStatus.send(WireCodec.decodeStatus(envelope.payload))
        }
        continuation.yield(envelope)
        if terminal { continuation.finish() }
    }

    private func handleDrop(generation: Int, error: AgentError) {
        let shouldReconnect = state.withLock { s -> Bool? in
            guard s.generation == generation else { return nil }
            s.transport = nil
            s.loops.forEach { $0.cancel() }
            s.loops = []
            return s.wantsConnection
        }
        guard let shouldReconnect else { return }
        failAllPending(with: .webSocketDisconnected)
        agentStatus.send(.offline)
        if shouldReconnect {
            scheduleReconnect(startingAt: 1)
        } else {
            connectionState.send(.disconnected)
        }
    }

    private func scheduleReconnect(startingAt firstAttempt: Int, immediate: Bool = false) {
        let policy = configuration.reconnectPolicy
        let task = Task { [weak self] in
            var attempt = firstAttempt
            while !Task.isCancelled {
                guard let self else { return }
                guard self.state.withLock({ $0.wantsConnection }) else { return }
                let delay: TimeInterval
                if immediate && attempt == firstAttempt {
                    delay = 0
                } else if let next = policy.delay(forAttempt: attempt) {
                    delay = next
                } else {
                    self.connectionState.send(.failed(.unableToConnect(detail: "Gave up after \(attempt - 1) attempts. Pull to retry.")))
                    self.state.withLock { $0.wantsConnection = false }
                    return
                }
                self.connectionState.send(.reconnecting(attempt: attempt, retryIn: delay))
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled, self.state.withLock({ $0.wantsConnection }) else { return }
                self.state.withLock { $0.isEstablishing = true }
                do {
                    try await self.establish()
                    self.state.withLock { $0.reconnectTask = nil }
                    return
                } catch {
                    self.state.withLock { $0.isEstablishing = false }
                    let agentError = error.asAgentError
                    if case .authenticationFailed = agentError {
                        self.state.withLock { $0.wantsConnection = false }
                        self.connectionState.send(.failed(agentError))
                        return
                    }
                    attempt += 1
                }
            }
        }
        state.withLock { $0.reconnectTask = task }
    }

    private func failAllPending(with error: AgentError) {
        let all = state.withLock { s -> [AsyncThrowingStream<WireEnvelope, Error>.Continuation] in
            let values = Array(s.pending.values)
            s.pending.removeAll()
            return values
        }
        all.forEach { $0.finish(throwing: error) }
    }

    // MARK: Messaging

    /// Sends a frame that carries a `requestId` and returns every frame the
    /// gateway sends back for it, ending at a terminal frame.
    public func request(_ envelope: WireEnvelope) -> AsyncThrowingStream<WireEnvelope, Error> {
        guard let requestId = envelope.requestId else {
            return AsyncThrowingStream { $0.finish(throwing: AgentError.protocolViolation(detail: "Requests need a requestId.")) }
        }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let transport = self.state.withLock { s -> WebSocketTransport? in
                guard let t = s.transport else { return nil }
                s.pending[requestId] = continuation
                return t
            }
            guard let transport else {
                continuation.finish(throwing: self.state.withLock({ $0.wantsConnection }) ? AgentError.webSocketDisconnected : AgentError.unableToConnect(detail: "Not connected to the gateway."))
                return
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.pending.removeValue(forKey: requestId) }
            }
            Task {
                do {
                    try await transport.send(try envelope.encodedString())
                } catch {
                    _ = self.state.withLock { $0.pending.removeValue(forKey: requestId) }
                    continuation.finish(throwing: error.asAgentError)
                }
            }
        }
    }

    /// Fire-and-forget frame (cancel, unsubscribe).
    public func sendFrame(_ envelope: WireEnvelope) async throws {
        guard let transport = state.withLock({ $0.transport }) else { throw AgentError.webSocketDisconnected }
        try await transport.send(try envelope.encodedString())
    }

    /// Ends a pending request locally (e.g. after the user hits Stop).
    public func finishRequest(_ requestId: String, throwing error: AgentError?) {
        let continuation = state.withLock { $0.pending.removeValue(forKey: requestId) }
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    /// One request → one `rpc.result`.
    public func call(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        try await ensureConnected()
        let requestId = BrainboxProtocol.id(UUID())
        let frame = WireEnvelope(type: BrainboxProtocol.ClientType.rpc, requestId: requestId, payload: ["method": .string(method), "params": params])
        let stream = request(frame)
        let timeout = configuration.requestTimeout
        return try await Timeout.run(seconds: timeout) {
            for try await envelope in stream {
                switch envelope.type {
                case BrainboxProtocol.ServerType.rpcResult:
                    return envelope.payload["result"] ?? .null
                case BrainboxProtocol.ServerType.error:
                    throw ((try? envelope.payload.decode(as: ErrorPayload.self))?.agentError ?? AgentError.remote(code: "unknown", message: "RPC failed"))
                default:
                    continue
                }
            }
            throw AgentError.webSocketDisconnected
        }
    }

    public func call<T: Decodable>(_ method: String, params: JSONValue = .object([:]), as type: T.Type) async throws -> T {
        try await call(method, params: params).decode(as: T.self)
    }

    /// Long-lived subscription (metrics, logs, terminal output).
    public func subscribe(_ method: String, params: JSONValue = .object([:])) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let requestId = BrainboxProtocol.id(UUID())
            let task = Task {
                do {
                    try await self.ensureConnected()
                    let frame = WireEnvelope(type: BrainboxProtocol.ClientType.subscribe, requestId: requestId, payload: ["method": .string(method), "params": params])
                    for try await envelope in self.request(frame) {
                        switch envelope.type {
                        case BrainboxProtocol.ServerType.streamData:
                            continuation.yield(envelope.payload)
                        case BrainboxProtocol.ServerType.streamEnd:
                            continuation.finish()
                            return
                        case BrainboxProtocol.ServerType.error:
                            let error = (try? envelope.payload.decode(as: ErrorPayload.self))?.agentError ?? AgentError.remote(code: "unknown", message: "Stream failed")
                            continuation.finish(throwing: error)
                            return
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error.asAgentError)
                }
            }
            continuation.onTermination = { [weak self] reason in
                task.cancel()
                guard case .cancelled = reason, let self else { return }
                Task { try? await self.sendFrame(WireEnvelope(type: BrainboxProtocol.ClientType.unsubscribe, requestId: requestId)) }
            }
        }
    }

    public func ensureConnected() async throws {
        if isConnected { return }
        try await connect()
    }
}
