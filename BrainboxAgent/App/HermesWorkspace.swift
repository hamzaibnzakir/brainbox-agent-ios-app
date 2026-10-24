import SwiftUI
import BrainboxCore

/// Hermes-specific app state: teammates, task (run) records, the session
/// browser, scheduled jobs and profile admin. Everything here is backed by
/// real server data or the user's own local definitions — nothing is
/// simulated outside the clearly-labelled Motion Lab.
@MainActor
@Observable
final class HermesWorkspace {
    // Teammates (local definitions).
    private(set) var teammates: [Teammate] = []
    var activeTeammateID: UUID = Teammate.mainAssistantID

    // Runs started from this app (Hermes has no list-runs endpoint).
    private(set) var runs: [RunRecord] = []

    // Server-backed state.
    private(set) var report: HermesCompatibilityReport?
    private(set) var gatewayInfo: BrainboxGatewayInfo?
    private(set) var profiles: [BrainboxProfileInfo] = []
    private(set) var toolsets: [HermesToolset] = []
    private(set) var skills: [HermesSkill] = []
    /// Read-only server overview from the Brainbox proxy (real numbers only).
    private(set) var overview: BrainboxSystemOverview?
    private(set) var overviewError: String?
    private(set) var overviewUpdated: Date?
    /// Hermes' slash commands and skills (via the proxy), for the composer.
    private(set) var commandCatalog: HermesCommandCatalog?
    /// Telegram-vs-API facts from the proxy (busy-input mode, remaining differences).
    private(set) var parity: HermesParityReport?

    /// What the proxy offers this device (nil = unknown / not behind the proxy).
    var features: BrainboxFeatures? { gatewayInfo?.features }

    /// Scheduled jobs (Hermes cron). Lives here, not in a view, so a "run now"
    /// being tracked keeps updating when you leave the screen and return.
    @ObservationIgnored let scheduledJobs = ScheduledJobsModel()

    @ObservationIgnored private let teammateStore: TeammateStore
    @ObservationIgnored private let runCache: JSONFileCache<[RunRecord]>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private(set) weak var provider: HermesAgentProvider?

    init(teammateURL: URL?, runsURL: URL?) {
        teammateStore = TeammateStore(url: teammateURL)
        runCache = runsURL.map { JSONFileCache<[RunRecord]>(url: $0) }
        teammates = teammateStore.load()
        scheduledJobs.clientProvider = { [weak self] in self?.client }
        runs = (runCache?.load() ?? []).sorted { $0.createdAt > $1.createdAt }
        if !teammates.contains(where: { $0.id == activeTeammateID }) {
            activeTeammateID = teammates.first?.id ?? Teammate.mainAssistantID
        }
    }

    var client: HermesAPIClient? { provider?.client }
    var isConnected: Bool { provider != nil && report?.isCompatible == true }

    // MARK: Provider attachment

    func attach(_ provider: HermesAgentProvider?) {
        activityTask?.cancel()
        self.provider = provider
        report = nil
        gatewayInfo = nil
        profiles = []
        overview = nil
        overviewError = nil
        commandCatalog = nil
        parity = nil
        guard let provider else { return }
        activityTask = Task { [weak self] in
            for await activity in provider.runActivity() {
                guard let self, !activity.runID.isEmpty else { continue }
                self.record(activity)
            }
        }
    }

    /// Called after the provider connected successfully.
    func refreshAfterConnect() async {
        report = provider?.compatibility
        guard let client else { return }
        gatewayInfo = try? await client.gatewayInfo()
        if gatewayInfo != nil { profiles = (try? await client.gatewayProfiles()) ?? [] }
        if gatewayInfo?.features?.commands == true { commandCatalog = try? await client.commandCatalog() }
        if gatewayInfo?.features?.parity == true { parity = try? await client.parityReport() }
        if report?.supports(.toolsets) == true { toolsets = (try? await client.toolsets()) ?? [] }
        if report?.supports(.skills) == true { skills = (try? await client.skills()) ?? [] }
    }

    func refreshOverview() async {
        guard let client else {
            overview = nil
            overviewError = "Not connected to Hermes."
            return
        }
        guard features?.diagnostics == true else {
            overviewError = gatewayInfo == nil
                ? "Server details come from the Brainbox proxy, which this connection doesn't go through."
                : "This Brainbox proxy is too old to report server details. Update it on the server."
            return
        }
        do {
            overview = try await client.systemOverview()
            overviewError = nil
            overviewUpdated = Date()
        } catch {
            overviewError = error.asAgentError.message
        }
    }

    // MARK: Teammates

    var activeTeammate: Teammate {
        teammates.first { $0.id == activeTeammateID } ?? teammates.first ?? Teammate.starterTeam[0]
    }

    var visibleTeammates: [Teammate] { teammates.filter { !$0.isArchived } }
    var archivedTeammates: [Teammate] { teammates.filter(\.isArchived) }

    func teammate(_ id: UUID?) -> Teammate? {
        guard let id else { return nil }
        return teammates.first { $0.id == id }
    }

    func save(_ teammate: Teammate) throws {
        try teammate.validate()
        var updated = teammate
        updated.name = teammate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.updatedAt = Date()
        if let index = teammates.firstIndex(where: { $0.id == teammate.id }) {
            teammates[index] = updated
        } else {
            teammates.append(updated)
        }
        teammateStore.save(teammates)
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let index = teammates.firstIndex(where: { $0.id == id }), id != Teammate.mainAssistantID else { return }
        teammates[index].isArchived = archived
        if archived && activeTeammateID == id { activeTeammateID = Teammate.mainAssistantID }
        teammateStore.save(teammates)
    }

    func delete(_ id: UUID) {
        guard id != Teammate.mainAssistantID else { return }
        teammates.removeAll { $0.id == id }
        if activeTeammateID == id { activeTeammateID = Teammate.mainAssistantID }
        teammateStore.save(teammates)
    }

    /// Options sent with each chat turn for a conversation.
    func requestOptions(for conversation: Conversation?) -> AgentRequestOptions? {
        let mate = teammate(conversation?.teammateID) ?? activeTeammate
        return AgentRequestOptions(
            sessionID: conversation?.backendSessionID,
            instructions: mate.runInstructions,
            model: conversation?.modelOverride ?? mate.model,
            provider: mate.provider,
            teammateID: mate.id,
            title: conversation?.title == Conversation.untitled ? nil : conversation?.title,
            profile: mate.profile,
            conversationHistory: conversation.flatMap { $0.carriesHistory ? CarriedHistory.build(from: $0) : nil })
    }

    // MARK: Runs

    var activeRuns: [RunRecord] { runs.filter { !$0.state.isTerminal && $0.state != .waitingForApproval } }
    var waitingRuns: [RunRecord] { runs.filter { $0.state == .waitingForApproval } }
    var finishedRuns: [RunRecord] { runs.filter { $0.state == .completed } }
    var failedRuns: [RunRecord] { runs.filter { [.failed, .cancelled, .interrupted].contains($0.state) } }

    func run(_ id: String) -> RunRecord? { runs.first { $0.id == id } }

    /// Called when a run's state changes (drives local notifications).
    @ObservationIgnored var onRunStateChange: ((RunRecord) -> Void)?

    private func record(_ activity: RunActivity) {
        if let index = runs.firstIndex(where: { $0.id == activity.runID }) {
            let before = runs[index].state
            runs[index] = runs[index].applying(activity)
            if runs[index].state != before { onRunStateChange?(runs[index]) }
        } else {
            let fresh = RunRecord(id: activity.runID, title: activity.title ?? "Agent run", state: activity.state ?? .running,
                                  createdAt: activity.date, updatedAt: activity.date,
                                  timeline: [RunTimelineEntry(date: activity.date, kind: .started, title: "Run started")])
            runs.insert(fresh.applying(activity), at: 0)
            if runs.count > 200 { runs.removeLast(runs.count - 200) }
        }
        persistRuns()
    }

    @ObservationIgnored private var persistTask: Task<Void, Never>?

    private func persistRuns() {
        // Debounced: streaming deltas arrive many times a second.
        persistTask?.cancel()
        let snapshot = runs
        let cache = runCache
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            cache?.store(snapshot)
        }
    }

    /// Re-reads one run's status from the server.
    func refresh(runID: String) async {
        guard let client else { return }
        do {
            let status = try await client.runStatus(id: runID)
            record(RunActivity(runID: runID, sessionID: status.sessionID, state: status.status))
            if status.status == .waitingForApproval, let approval = status.approval {
                let already = run(runID)?.timeline.last?.kind == .approvalRequested
                if !already { record(RunActivity(runID: runID, event: .approvalRequest(approval), state: .waitingForApproval)) }
            }
        } catch AgentError.remote(let code, _) where code == "run_not_found" {
            // Hermes forgets runs a while after they end; keep our record as-is.
        } catch {}
    }

    func pendingApproval(for runID: String) async -> AgentApproval? {
        guard let client, let status = try? await client.runStatus(id: runID), let request = status.approval else { return nil }
        return AgentApproval(runID: runID, command: request.command, description: request.description,
                             choices: request.choices, requestID: request.requestID)
    }

    func clearFinishedRuns() {
        runs.removeAll { $0.state.isTerminal }
        persistRuns()
    }

    // MARK: Profiles (Brainbox proxy admin)

    var canCreateProfiles: Bool { gatewayInfo?.profileAdmin == true }

    func reloadProfiles() async {
        guard let client, gatewayInfo != nil else { return }
        profiles = (try? await client.gatewayProfiles()) ?? profiles
    }

    func createProfile(name: String, description: String?, clone: Bool) async throws {
        guard let client else { throw AgentError.providerUnavailable(detail: "Connect to Hermes first.") }
        let profile = try await client.gatewayCreateProfile(name: name, description: description, cloneFromDefault: clone)
        profiles.removeAll { $0.name == profile.name }
        profiles.append(profile)
    }
}
