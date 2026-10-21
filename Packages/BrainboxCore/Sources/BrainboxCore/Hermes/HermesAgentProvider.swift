import Foundation

/// Extra controls only server-side run backends (Hermes) offer.
/// The UI discovers them with `as? RunControllingProvider`.
public protocol RunControllingProvider: AgentProvider {
    /// Server run id for an in-flight request, once accepted.
    func runID(for requestID: UUID) -> String?
    /// Injects guidance into a running agent (Hermes `/steer`).
    func steer(runID: String, text: String) async throws
    /// Answers an approval the agent is blocked on.
    func respond(to approval: AgentApproval, choice: HermesApprovalChoice) async throws
    /// Re-attaches to a run after a reconnect or relaunch by polling its
    /// status. `alreadyStreamed` is the text the user has already seen.
    func resume(runID: String, alreadyStreamed: String) -> AsyncThrowingStream<AgentEvent, Error>
    /// Stops a run by id (Tasks screen).
    func stop(runID: String) async throws
    /// Live feed of run activity for the Tasks screen.
    func runActivity() -> AsyncStream<RunActivity>
    var compatibility: HermesCompatibilityReport? { get }
    var client: HermesAPIClient { get }
}

/// One thing that happened in a run, published for the Tasks screen.
public struct RunActivity: Hashable, Sendable {
    public var runID: String
    public var sessionID: String?
    public var conversationID: UUID?
    public var teammateID: UUID?
    public var title: String?
    public var event: HermesRunEvent?
    public var state: HermesRunState?
    public var date: Date

    public init(runID: String, sessionID: String? = nil, conversationID: UUID? = nil, teammateID: UUID? = nil,
                title: String? = nil, event: HermesRunEvent? = nil, state: HermesRunState? = nil, date: Date = Date()) {
        self.runID = runID
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.title = title
        self.event = event
        self.state = state
        self.date = date
    }
}

/// Talks to the Hermes API Server (directly or through the Brainbox
/// gateway proxy). Every chat turn is a server-side run (`POST /v1/runs`),
/// so long work keeps going on the VPS when the phone sleeps.
public final class HermesAgentProvider: RunControllingProvider, @unchecked Sendable {
    public let client: HermesAPIClient
    private let connection = Broadcaster<ConnectionState>(initial: .disconnected)
    private let status = Broadcaster<AgentStatus>(initial: .offline)
    private let activity = Broadcaster<RunActivity>(initial: RunActivity(runID: "", date: .distantPast))
    private let state = Locked<State>(State())
    private let pause: @Sendable (TimeInterval) async throws -> Void

    private struct State {
        var report: HermesCompatibilityReport?
        var runs: [UUID: String] = [:]          // requestID → runID
        var runClients: [String: HermesAPIClient] = [:] // runID → profile-routed client
        var createdSessions: Set<String> = []   // "profile|session"
        var heartbeat: Task<Void, Never>?
        var activeRequests = 0
        /// Requests sent but whose `run_id` hasn't come back yet.
        var awaitingRunID: Set<UUID> = []
        /// Stop requested before the run id was known; applied on arrival.
        var pendingStops: Set<UUID> = []
    }

    public init(client: HermesAPIClient, pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }) {
        self.client = client
        self.pause = pause
    }

    deinit { state.withLock { $0.heartbeat?.cancel() } }

    public var compatibility: HermesCompatibilityReport? { state.withLock { $0.report } }

    public var descriptor: AgentDescriptor {
        var name = "Hermes"
        if let profile = client.configuration.profile, !profile.isEmpty, profile != "default" {
            name = profile
        } else if let model = compatibility?.model, !model.isEmpty, model != "hermes-agent" {
            name = model
        }
        return AgentDescriptor(id: "hermes", name: name, kind: .hermes, version: "API v1", summary: "Hermes Agent on your VPS")
    }

    public var capabilities: Set<ProviderCapability> {
        var caps: Set<ProviderCapability> = [.streaming, .conversationHistory]
        if compatibility?.supports(.stop) ?? true { caps.insert(.cancellation) }
        caps.insert(.toolExecution)
        return caps
    }

    // MARK: Connection

    public func connect() async throws {
        connection.send(.connecting)
        do {
            let caps = try await client.capabilities()
            let report = HermesCompatibilityReport.evaluate(caps)
            state.withLock { $0.report = report }
            guard report.isCompatible else {
                let error = AgentError.providerUnavailable(detail: "This Hermes server is missing features the app needs: " + report.problems.joined(separator: " "))
                connection.send(.failed(error))
                status.send(.unavailable(reason: "Incompatible server"))
                throw error
            }
            connection.send(.connected)
            if state.withLock({ $0.activeRequests }) == 0 { status.send(.ready) }
            startHeartbeat()
        } catch let error as AgentError {
            if case .failed = connection.value {} else { connection.send(.failed(error)) }
            status.send(.offline)
            throw error
        } catch {
            let agentError = error.asAgentError
            connection.send(.failed(agentError))
            status.send(.offline)
            throw agentError
        }
    }

    public func disconnect() async {
        state.withLock { $0.heartbeat?.cancel(); $0.heartbeat = nil }
        connection.send(.disconnected)
        status.send(.offline)
    }

    /// Cheap liveness check every 45 s while connected. A failure flips the
    /// state to `.reconnecting` and the next success flips it back.
    private func startHeartbeat() {
        let task = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard let self, !Task.isCancelled else { return }
                do {
                    _ = try await self.client.health()
                    failures = 0
                    if !self.connection.value.isConnected { self.connection.send(.connected); self.status.send(.ready) }
                } catch {
                    failures += 1
                    self.connection.send(.reconnecting(attempt: failures, retryIn: 45))
                }
            }
        }
        state.withLock { $0.heartbeat?.cancel(); $0.heartbeat = task }
    }

    public func connectionUpdates() -> AsyncStream<ConnectionState> { connection.subscribe() }
    public func statusUpdates() -> AsyncStream<AgentStatus> { status.subscribe() }
    public func currentStatus() async -> AgentStatus { status.value }
    public func runActivity() -> AsyncStream<RunActivity> { activity.subscribe() }

    // MARK: Sessions

    /// The Hermes session backing a local conversation.
    public static func sessionID(for conversationID: UUID) -> String {
        HermesSessionSource.appSessionPrefix + conversationID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    private func ensureSession(id: String, title: String?, client: HermesAPIClient) async throws {
        let key = "\(client.configuration.profile ?? "default")|\(id)"
        if state.withLock({ $0.createdSessions.contains(key) }) { return }
        do {
            _ = try await client.createSession(id: id, title: title)
        } catch AgentError.remote(let code, _) where code == "session_exists" {
            // Already there — fine.
        } catch AgentError.remote(let code, _) where code == "invalid_title" {
            // Titles are unique server-side; fall back to an untitled session.
            do {
                _ = try await client.createSession(id: id, title: nil)
            } catch AgentError.remote(let code, _) where code == "session_exists" {
                // Already there — fine.
            }
        }
        state.withLock { _ = $0.createdSessions.insert(key) }
    }

    // MARK: Sending

    public func send(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.run(request, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AgentRequest, continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        state.withLock { $0.activeRequests += 1 }
        defer {
            let remaining = state.withLock { s -> Int in s.activeRequests -= 1; return s.activeRequests }
            if remaining == 0 && connection.value.isConnected { status.send(.ready) }
        }
        continuation.yield(.accepted(requestID: request.requestID))
        continuation.yield(.status(.thinking))
        status.send(.thinking)

        let options = request.options
        let client = self.client.with(profile: options?.profile)
        let requestID = request.requestID
        // The app only ever writes to its own `ios_` sessions. Anything else
        // (Telegram, CLI, other API clients) is read-only from here.
        if let explicit = options?.sessionID, !explicit.hasPrefix(HermesSessionSource.appSessionPrefix) {
            continuation.yield(.failed(.permissionDenied(detail: "This conversation points at a session the app may not write to. Continue it as a copy instead.")))
            continuation.finish()
            return
        }
        let sessionID = options?.sessionID ?? Self.sessionID(for: request.conversationID)
        state.withLock { _ = $0.awaitingRunID.insert(requestID) }
        func stopRequestedEarly() -> Bool {
            state.withLock { $0.pendingStops.contains(requestID) }
        }
        func forgetEarlyStop() {
            state.withLock { s in
                s.awaitingRunID.remove(requestID)
                s.pendingStops.remove(requestID)
            }
        }
        let runID: String
        do {
            if options?.sessionID == nil {
                try await ensureSession(id: sessionID, title: options?.title ?? Conversation.suggestedTitle(from: request.content), client: client)
            }
            if stopRequestedEarly() || Task.isCancelled {
                // Stopped before anything ran: don't start a run at all.
                forgetEarlyStop()
                continuation.yield(.failed(.cancelled))
                continuation.finish()
                return
            }
            let runOptions = HermesAPIClient.RunOptions(
                sessionID: sessionID,
                instructions: options?.instructions,
                model: options?.model,
                provider: options?.provider,
                idempotencyKey: requestID.uuidString.lowercased(),
                conversationHistory: options?.conversationHistory)
            // Detached from this task's cancellation: once the POST is on the
            // wire Hermes may already be running it, so we must get the
            // run id back to be able to stop it.
            let accepted = try await Task { try await client.createRun(input: request.content, options: runOptions) }.value
            runID = accepted.runID
        } catch {
            forgetEarlyStop()
            continuation.yield(.failed(Task.isCancelled ? .cancelled : error.asAgentError))
            continuation.finish()
            return
        }

        let stopNow = state.withLock { s -> Bool in
            s.awaitingRunID.remove(requestID)
            s.runs[requestID] = runID
            s.runClients[runID] = client
            return s.pendingStops.remove(requestID) != nil
        }
        if stopNow || Task.isCancelled {
            // A Stop arrived while the run was being created: apply it now,
            // also detached so the stop request itself isn't cancelled.
            _ = await Task { try? await client.stopRun(id: runID) }.value
            if Task.isCancelled {
                state.withLock { s in
                    _ = s.runs.removeValue(forKey: requestID)
                    _ = s.runClients.removeValue(forKey: runID)
                }
                continuation.yield(.failed(.cancelled))
                continuation.finish()
                return
            }
        }
        continuation.yield(.runStarted(runID: runID, sessionID: sessionID))
        publish(RunActivity(runID: runID, sessionID: sessionID, conversationID: request.conversationID,
                            teammateID: options?.teammateID, title: Conversation.suggestedTitle(from: request.content), state: .running))

        var mapper = HermesRunMapper(runID: runID)
        let context = (sessionID: sessionID, conversationID: request.conversationID)
        do {
            for try await event in client.runEvents(id: runID) {
                publish(RunActivity(runID: runID, sessionID: context.sessionID, conversationID: context.conversationID, event: event, state: Self.state(after: event)))
                for mapped in mapper.map(event) {
                    if case .status(let s) = mapped { status.send(s) }
                    continuation.yield(mapped)
                }
                if mapper.finished { break }
            }
        } catch {
            if Task.isCancelled {
                continuation.yield(.failed(.cancelled))
                continuation.finish()
                return
            }
            // Fall through to recovery: the run keeps going server-side.
        }

        if !mapper.finished {
            continuation.yield(.notice("Live stream interrupted — following the run by status."))
            await poll(runID: runID, mapper: &mapper, continuation: continuation, context: context)
        }
        state.withLock { s in
            _ = s.runs.removeValue(forKey: request.requestID)
            _ = s.runClients.removeValue(forKey: runID)
        }
        continuation.finish()
    }

    /// Polls `GET /v1/runs/{id}` until the run settles. Used after a dropped
    /// event stream and when resuming after relaunch.
    private func poll(runID: String, mapper: inout HermesRunMapper,
                      continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
                      context: (sessionID: String?, conversationID: UUID?)) async {
        var failures = 0
        while !mapper.finished {
            if Task.isCancelled { continuation.yield(.failed(.cancelled)); return }
            do {
                let status = try await client(forRun: runID).runStatus(id: runID)
                failures = 0
                for mapped in mapper.reconcile(status) { continuation.yield(mapped) }
                publish(RunActivity(runID: runID, sessionID: status.sessionID ?? context.sessionID, conversationID: context.conversationID, state: status.status))
                if mapper.finished { return }
            } catch AgentError.remote(let code, _) where code == "run_not_found" {
                continuation.yield(.failed(.remote(code: "run_expired", message: "Hermes no longer tracks this run (status is kept only briefly after it ends). Its reply is in the session history.")))
                return
            } catch {
                failures += 1
                if failures >= 20 {
                    continuation.yield(.failed(.remote(code: "run_detached", message: "Lost contact with this run. It may still be running on the VPS — check Tasks.")))
                    return
                }
            }
            do { try await self.pause(min(client.configuration.pollInterval * Double(max(failures, 1)), 15)) } catch {
                continuation.yield(.failed(.cancelled)); return
            }
        }
    }

    public func resume(runID: String, alreadyStreamed: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                var mapper = HermesRunMapper(runID: runID)
                if !alreadyStreamed.isEmpty { _ = mapper.map(.messageDelta(alreadyStreamed)) }
                await self.poll(runID: runID, mapper: &mapper, continuation: continuation, context: (nil, nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func publish(_ activity: RunActivity) {
        self.activity.send(activity)
    }

    static func state(after event: HermesRunEvent) -> HermesRunState? {
        switch event {
        case .approvalRequest: return .waitingForApproval
        case .approvalResponded, .toolStarted, .messageDelta: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        case .stopping: return .stopping
        default: return nil
        }
    }

    // MARK: Controls

    public func runID(for requestID: UUID) -> String? { state.withLock { $0.runs[requestID] } }

    public func cancel(requestID: UUID) async {
        // Known run: stop it. Otherwise remember the Stop; `run` applies it
        // the moment Hermes returns the run id (or skips the run entirely).
        let runID = state.withLock { s -> String? in
            if let id = s.runs[requestID] { return id }
            if s.awaitingRunID.contains(requestID) { s.pendingStops.insert(requestID) }
            return nil
        }
        guard let runID else { return }
        try? await stop(runID: runID)
    }

    public func stop(runID: String) async throws {
        try await client(forRun: runID).stopRun(id: runID)
    }

    /// The profile-routed client a run was created with (default otherwise).
    public func client(forRun runID: String) -> HermesAPIClient {
        state.withLock { $0.runClients[runID] } ?? client
    }

    public func steer(runID: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await client(forRun: runID).steerRun(id: runID, text: trimmed)
    }

    public func respond(to approval: AgentApproval, choice: HermesApprovalChoice) async throws {
        guard approval.choices.contains(choice.rawValue) || choice == .deny else {
            throw AgentError.permissionDenied(detail: "Hermes did not offer “\(choice.title)” for this action.")
        }
        try await client(forRun: approval.runID).respondToApproval(runID: approval.runID, choice: choice, requestID: approval.requestID)
    }

    // MARK: History & tools

    public func conversationHistory() async throws -> [ConversationSummary] {
        let page = try await client.sessions(limit: 100)
        return page.sessions.compactMap { session -> ConversationSummary? in
            guard session.sourceKind == .ios, let id = Self.conversationID(fromSessionID: session.id) else { return nil }
            return ConversationSummary(id: id, title: session.displayTitle, updatedAt: session.lastActivity ?? Date(), preview: session.preview ?? "")
        }
    }

    /// Inverse of `sessionID(for:)`.
    public static func conversationID(fromSessionID id: String) -> UUID? {
        guard id.hasPrefix(HermesSessionSource.appSessionPrefix) else { return nil }
        let hex = String(id.dropFirst(HermesSessionSource.appSessionPrefix.count))
        guard hex.count == 32 else { return nil }
        let chars = Array(hex)
        let parts = [8, 4, 4, 4, 12]
        var index = 0
        var groups: [String] = []
        for length in parts {
            groups.append(String(chars[index..<(index + length)]))
            index += length
        }
        return UUID(uuidString: groups.joined(separator: "-"))
    }

    public func executeTool(_ invocation: ToolInvocation) async throws -> ToolResult {
        throw AgentError.notImplemented(detail: "Hermes runs tools itself during a run. Ask the agent instead.")
    }
}

public extension ProviderSuite {
    /// Hermes backend: the agent only. Server metrics, terminal and files
    /// stay with the Brainbox gateway's own WebSocket backend.
    static func hermes(client: HermesAPIClient) -> ProviderSuite {
        ProviderSuite(agent: HermesAgentProvider(client: client), vps: nil, terminal: nil, files: nil, logs: nil)
    }
}
