import SwiftUI
import BrainboxCore

enum AppTab: String, CaseIterable, Identifiable {
    case home, agent, vps, files, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .agent: return "Agent"
        case .vps: return "VPS"
        case .files: return "Files"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .agent: return "sparkles"
        case .vps: return "server.rack"
        case .files: return "folder"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Root application state: owns settings, security, the active provider
/// suite and the chat store. Swapping backends = swapping the suite.
@MainActor
@Observable
final class AppModel {
    let environment: LaunchEnvironment
    let settings: AppSettings
    let gate: BiometricGate
    let network = NetworkMonitor()
    let toasts = ToastCenter()
    let chat: ChatStore
    @ObservationIgnored let credentials: CredentialStore

    private(set) var suite: ProviderSuite
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var agentStatus: AgentStatus = .offline
    private(set) var connectionError: AgentError?
    private(set) var hasToken = false
    var selectedTab: AppTab = .agent

    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var gateway: GatewayConnection?
    @ObservationIgnored let snapshotCache: JSONFileCache<ServerSnapshot>

    init(environment: LaunchEnvironment = .current) {
        self.environment = environment
        if environment.isUITesting { Motion.ambientEnabled = false }
        let defaults: UserDefaults
        if environment.usesEphemeralStorage {
            let suiteName = "brainbox.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            defaults = .standard
        }
        let settings = AppSettings(defaults: defaults, isTesting: environment.usesEphemeralStorage)
        self.settings = settings

        #if canImport(Security)
        self.credentials = environment.usesEphemeralStorage ? InMemoryCredentialStore() : KeychainCredentialStore()
        #else
        self.credentials = InMemoryCredentialStore()
        #endif

        self.gate = BiometricGate(policy: { settings.policy }, bypass: environment.usesEphemeralStorage)

        let conversationStore: ConversationStore = environment.usesEphemeralStorage
            ? InMemoryConversationStore()
            : FileConversationStore(directory: FileConversationStore.defaultDirectory())
        self.snapshotCache = JSONFileCache(url: environment.usesEphemeralStorage
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bb-snapshot-\(UUID().uuidString).json")
            : JSONFileCache<ServerSnapshot>.defaultURL(named: "server-snapshot"))

        let initialSuite = ProviderSuite.mock(fast: environment.isUITesting)
        self.suite = initialSuite
        self.chat = ChatStore(store: conversationStore, provider: { initialSuite.agent }, isOnline: { true })

        // Re-point closures at self now that all stored properties exist.
        chat.provider = { [unowned self] in self.suite.agent }
        chat.isOnline = { [unowned self] in self.network.isOnline }
        chat.onReplyFinished = { [weak self] message in self?.replyFinished(message) }
        network.onReconnect = { [weak self] in self?.handleNetworkReturn() }
        hasToken = ((try? credentials.read(.gatewayToken)) ?? nil) != nil
    }

    // MARK: Lifecycle

    func start() {
        if !environment.isUnitTesting { network.start() }
        rebuildSuite()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            gate.noteBackgrounded()
        case .active:
            gate.noteForegrounded()
            gateway?.reconnectNow()
        default:
            break
        }
    }

    private func handleNetworkReturn() {
        gateway?.reconnectNow()
        if settings.providerKind == .mock, !connectionState.isConnected {
            Task { await connect() }
        }
    }

    // MARK: Providers

    var agentDescriptor: AgentDescriptor { suite.agent.descriptor }
    var capabilities: Set<ProviderCapability> { suite.agent.capabilities }
    var isMock: Bool { settings.providerKind == .mock }

    func switchProvider(to kind: ProviderKind) {
        guard kind != settings.providerKind || gateway == nil else { return }
        settings.providerKind = kind
        rebuildSuite()
    }

    /// Re-creates the provider suite from settings and reconnects.
    func rebuildSuite() {
        let old = suite
        let oldGateway = gateway
        observers.forEach { $0.cancel() }
        observers.removeAll()
        Task { await old.agent.disconnect() }
        _ = oldGateway

        connectionError = nil
        gateway = nil

        switch settings.providerKind {
        case .mock:
            suite = .mock(fast: environment.isUITesting)
        case .hermes:
            suite = .hermesPending()
        case .remote:
            if let url = settings.validatedBackendURL {
                let credentials = self.credentials
                let connection = GatewayConnection(
                    configuration: GatewayConfiguration(url: url, clientVersion: Bundle.main.appVersion),
                    tokenProvider: { (try? credentials.read(.gatewayToken)) ?? nil },
                    transportFactory: { URLSessionWebSocketTransport() }
                )
                gateway = connection
                suite = .remote(connection: connection)
            } else {
                suite = ProviderSuite(agent: UnavailableAgentProvider(reason: "Add your gateway URL and access token in Settings → Connection."), vps: nil, terminal: nil, files: nil, logs: nil)
            }
        }
        observe(suite.agent)
        Task { await connect() }
    }

    func connect() async {
        connectionError = nil
        do {
            try await suite.agent.connect()
        } catch {
            let agentError = error.asAgentError
            // Retryable failures are already being retried by the gateway.
            if !agentError.isRetryable || settings.providerKind != .remote { connectionError = agentError }
        }
    }

    func reconnect() {
        if let gateway {
            gateway.reconnectNow()
            if case .failed = connectionState { Task { await connect() } }
        } else {
            Task { await connect() }
        }
    }

    private func observe(_ agent: AgentProvider) {
        let connectionTask = Task { [weak self] in
            for await state in agent.connectionUpdates() {
                guard let self else { return }
                let wasConnected = self.connectionState.isConnected
                withAnimation(Motion.standard) { self.connectionState = state }
                if case .failed(let error) = state { self.connectionError = error }
                if state.isConnected { self.connectionError = nil }
                if wasConnected && !state.isConnected && self.settings.notifyOnDisconnect {
                    Notifier.post(title: "Brainbox disconnected", body: "Reconnecting to \(agent.descriptor.name)…")
                }
            }
        }
        let statusTask = Task { [weak self] in
            for await status in agent.statusUpdates() {
                guard let self else { return }
                withAnimation(Motion.standard) { self.agentStatus = status }
            }
        }
        observers = [connectionTask, statusTask]
    }

    private func replyFinished(_ message: Message) {
        if settings.notifyOnTaskComplete, !message.toolCalls.isEmpty {
            Notifier.post(title: "Task finished", body: String(message.content.prefix(120)))
        }
    }

    // MARK: Credentials

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try credentials.write(trimmed, for: .gatewayToken)
        hasToken = true
    }

    func deleteToken() throws {
        try credentials.delete(.gatewayToken)
        hasToken = false
    }

    func readToken() -> String? {
        (try? credentials.read(.gatewayToken)) ?? nil
    }

    /// Wipes local data. Never touches anything on the server.
    func eraseLocalData() {
        chat.deleteAll()
        snapshotCache.clear()
        try? credentials.delete(.gatewayToken)
        hasToken = false
    }
}

/// Used when a backend can't be built yet (e.g. Remote with no URL).
final class UnavailableAgentProvider: AgentProvider, @unchecked Sendable {
    let reason: String
    private let state: Broadcaster<ConnectionState>
    private let status = Broadcaster<AgentStatus>(initial: .unavailable(reason: "Not configured"))

    init(reason: String) {
        self.reason = reason
        self.state = Broadcaster(initial: .failed(.providerUnavailable(detail: reason)))
    }

    var descriptor: AgentDescriptor { AgentDescriptor(id: "unconfigured", name: "Remote Agent", kind: .remote, summary: "Not configured") }
    var capabilities: Set<ProviderCapability> { [] }
    func connect() async throws { throw AgentError.providerUnavailable(detail: reason) }
    func disconnect() async {}
    func connectionUpdates() -> AsyncStream<ConnectionState> { state.subscribe() }
    func statusUpdates() -> AsyncStream<AgentStatus> { status.subscribe() }
    func currentStatus() async -> AgentStatus { status.value }
    func send(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let reason = self.reason
        return AsyncThrowingStream { continuation in
            continuation.yield(.failed(.providerUnavailable(detail: reason)))
            continuation.finish()
        }
    }
    func cancel(requestID: UUID) async {}
    func conversationHistory() async throws -> [ConversationSummary] { [] }
    func executeTool(_ invocation: ToolInvocation) async throws -> ToolResult { throw AgentError.providerUnavailable(detail: reason) }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
