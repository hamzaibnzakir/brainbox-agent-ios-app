import SwiftUI
import UIKit
import BackgroundTasks
import BrainboxCore

/// Bottom navigation. Settings is reached from the gear on Home and Server.
enum AppTab: String, CaseIterable, Identifiable {
    case home, agent, team, tasks, vps
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .agent: return "Chat"
        case .team: return "Workspace"
        case .tasks: return "Tasks"
        case .vps: return "Server"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .agent: return "bubble.left.and.text.bubble.right"
        case .team: return "square.grid.2x2"
        case .tasks: return "checklist"
        case .vps: return "server.rack"
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
    let hermes: HermesWorkspace
    @ObservationIgnored let credentials: CredentialStore

    private(set) var suite: ProviderSuite
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var agentStatus: AgentStatus = .offline
    private(set) var connectionError: AgentError?
    private(set) var hasToken = false
    private(set) var hasHermesToken = false
    var selectedTab: AppTab = .home
    /// Settings is a sheet over whatever tab is open.
    var showSettings = false
    /// A deep link (notification tap or brainbox:// URL) waiting for its screen.
    var pendingLink: BrainboxDeepLink?
    /// The last requests made to Hermes / the proxy (Diagnostics; paths only).
    @ObservationIgnored let requestLog = RecordingHTTPTransport(URLSessionHTTPTransport())
    let notifications: NotificationManager
    let transfers = TransferManager()
    let agents: ParallelAgentsStore

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

        let workspace = HermesWorkspace(
            teammateURL: environment.usesEphemeralStorage ? nil : JSONFileCache<[Teammate]>.defaultURL(named: "teammates"),
            runsURL: environment.usesEphemeralStorage ? nil : JSONFileCache<[RunRecord]>.defaultURL(named: "hermes-runs"))
        if let saved = UUID(uuidString: settings.lastTeammateID), workspace.teammate(saved) != nil {
            workspace.activeTeammateID = saved
        }
        self.hermes = workspace
        self.notifications = NotificationManager(defaults: defaults, enabled: !environment.usesEphemeralStorage)
        self.agents = ParallelAgentsStore(
            cacheURL: environment.usesEphemeralStorage ? nil : JSONFileCache<[ParallelTask]>.defaultURL(named: "parallel-tasks"),
            defaults: defaults, client: { [weak workspace] in workspace?.client })

        let initialSuite = ProviderSuite.mock(fast: environment.isUITesting)
        self.suite = initialSuite
        self.chat = ChatStore(store: conversationStore, provider: { initialSuite.agent }, isOnline: { true })

        // Re-point closures at self now that all stored properties exist.
        chat.provider = { [unowned self] in self.suite.agent }
        chat.isOnline = { [unowned self] in self.network.isOnline }
        chat.onReplyFinished = { [weak self] message in self?.replyFinished(message) }
        agents.onTaskChange = { [weak self] task in
            self?.notifications.parallelTaskChanged(task)
            self?.chat.deliverBackgroundResult(task)
        }
        hermes.onRunStateChange = { [weak self] run in
            self?.notifications.runChanged(runID: run.id, title: run.title, state: run.state)
        }
        chat.requestOptions = { [unowned self] conversation in
            self.settings.providerKind == .hermes ? self.hermes.requestOptions(for: conversation) : nil
        }
        chat.activeTeammateID = { [unowned self] in self.hermes.activeTeammateID }
        chat.commandCatalog = { [unowned self] in self.hermes.commandCatalog }
        chat.statusSummary = { [unowned self] in
            var parts = ["Backend: \(self.settings.providerKind.displayName) — \(self.connectionState.label)"]
            if let info = self.hermes.gatewayInfo { parts.append("Brainbox proxy v\(info.version ?? "?")") }
            if let hermes = self.hermes.overview?.hermes {
                parts.append(hermes.reachable ? "Hermes responding" + (hermes.latencyMs.map { " (\(Int($0)) ms)" } ?? "") : "Hermes not responding")
            }
            return parts.joined(separator: "\n")
        }
        chat.lifecycleClient = { [unowned self] in
            self.settings.providerKind == .hermes && self.hermes.isConnected ? self.hermes.client : nil
        }
        network.onReconnect = { [weak self] in self?.handleNetworkReturn() }
        hasToken = ((try? credentials.read(.gatewayToken)) ?? nil) != nil
        hasHermesToken = ((try? credentials.read(.hermesToken)) ?? nil) != nil
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
            keepFinishingInBackground()
            notifications.scheduleBackgroundRefresh()
        case .active:
            gate.noteForegrounded()
            Task { await notifications.refreshPermission() }
            gateway?.reconnectNow()
            // iOS suspends sockets in the background: re-open live run streams now (the relay
            // resumes them from the last event, so nothing is lost or repeated).
            chat.reconnectLiveRuns()
            if isHermes, !connectionState.isConnected { Task { await connect() } }
        default:
            break
        }
    }

    private func handleNetworkReturn() {
        gateway?.reconnectNow()
        chat.reconnectLiveRuns()
        if settings.providerKind != .remote, !connectionState.isConnected {
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
            if let url = settings.validatedHermesURL, hasHermesToken {
                let credentials = self.credentials
                let client = HermesAPIClient(
                    configuration: HermesConfiguration(baseURL: url),
                    transport: requestLog,
                    tokenProvider: { (try? credentials.read(.hermesToken)) ?? nil })
                suite = .hermes(client: client)
            } else {
                suite = ProviderSuite(agent: UnavailableAgentProvider(reason: "Add your Hermes URL and device token in Settings → Hermes."), vps: nil, terminal: nil, files: nil, logs: nil)
            }
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
        hermes.attach(suite.agent as? HermesAgentProvider)
        observe(suite.agent)
        Task { await connect() }
    }

    var hermesProvider: HermesAgentProvider? { suite.agent as? HermesAgentProvider }
    var isHermes: Bool { hermesProvider != nil }

    func connect() async {
        connectionError = nil
        do {
            try await suite.agent.connect()
            if isHermes {
                await hermes.refreshAfterConnect()
                chat.resumeInterruptedRuns()
                agents.resume()
                await chat.syncArchiveState()
                await notifications.refreshPermission()
                startJobWatch()
            }
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
                if wasConnected && !state.isConnected {
                    let hour = Int(Date().timeIntervalSince1970 / 3600)
                    self.notifications.post(LocalAlert(kind: .connectionLost, title: "Brainbox disconnected",
                                                       body: "Lost the connection to \(agent.descriptor.name). Reconnecting…",
                                                       link: "brainbox://server", dedupeKey: "conn:\(hour)"))
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
        // Hermes replies are covered by run-state alerts (same dedupe key); this covers
        // other backends. No reply text goes on the lock screen.
        let title = chat.conversations.first { c in c.messages.contains { $0.id == message.id } }?.title ?? ""
        let key = message.runID ?? message.id.uuidString
        switch message.state {
        case .complete: notifications.runChanged(runID: key, title: title, state: .completed)
        case .failed: notifications.runChanged(runID: key, title: title, state: .failed)
        default: break
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

    func saveHermesToken(_ token: String) throws {
        try credentials.write(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .hermesToken)
        hasHermesToken = true
    }

    func deleteHermesToken() throws {
        try credentials.delete(.hermesToken)
        hasHermesToken = false
    }

    func readHermesToken() -> String? {
        (try? credentials.read(.hermesToken)) ?? nil
    }

    func selectTeammate(_ id: UUID) {
        hermes.activeTeammateID = id
        settings.lastTeammateID = id.uuidString
    }

    // MARK: Local notifications

    @ObservationIgnored private var jobWatch: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// While the app is open and connected: check scheduled jobs every minute.
    private func startJobWatch() {
        jobWatch?.cancel()
        jobWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isHermes, let client = self.hermes.client else { return }
                if let jobs = try? await client.jobs() { self.notifications.jobsChanged(jobs) }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// iOS gives a backgrounded app ~30 s: enough for a reply that's about to
    /// finish to stream its end and post its notification.
    private func keepFinishingInBackground() {
        guard chat.isStreaming, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "finish-reply") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
        Task { [weak self] in
            while let self, self.chat.isStreaming, self.backgroundTaskID != .invalid {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, self.backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }

    /// iOS background refresh: check jobs and in-flight runs, post what changed.
    func runBackgroundCheck(_ task: BGAppRefreshTask) {
        notifications.scheduleBackgroundRefresh()
        let work = Task { [weak self] in
            guard let self, self.isHermes, let client = self.hermes.client else { return false }
            if let jobs = try? await client.jobs() { self.notifications.jobsChanged(jobs) }
            for run in self.hermes.runs where !run.state.isTerminal {
                guard let status = try? await client.runStatus(id: run.id) else { continue }
                self.notifications.runChanged(runID: run.id, title: run.title, state: status.status)
            }
            self.notifications.noteBackgroundCheck()
            return true
        }
        task.expirationHandler = { work.cancel() }
        Task {
            let ok = await work.value
            task.setTaskCompleted(success: ok)
        }
    }

    // MARK: Deep links

    func open(_ url: URL) {
        guard let link = BrainboxDeepLink.parse(url) else { return }
        open(link)
    }

    func open(_ link: BrainboxDeepLink) {
        showSettings = false
        switch link {
        case .chat(let sessionID):
            if chat.openConversation(boundTo: sessionID) { selectedTab = .agent } else { selectedTab = .home }
        case .job, .run:
            pendingLink = link
            selectedTab = .tasks
        case .server, .files, .terminal:
            pendingLink = link
            selectedTab = .vps
        case .agents:
            selectedTab = .team
        case .settings:
            showSettings = true
        }
    }

    /// Wipes local data. Never touches anything on the server.
    func eraseLocalData() {
        chat.deleteAll()
        snapshotCache.clear()
        try? credentials.delete(.gatewayToken)
        try? credentials.delete(.hermesToken)
        hasToken = false
        hasHermesToken = false
        hermes.clearFinishedRuns()
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
