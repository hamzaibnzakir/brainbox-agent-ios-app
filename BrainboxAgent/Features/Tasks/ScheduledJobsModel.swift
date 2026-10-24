import Foundation
import Observation
import BrainboxCore

/// State behind the Scheduled screens: the job list (refreshed every 15 s
/// while visible), "run now" tracking (polled every 5 s until a terminal
/// state or timeout — never re-triggered) and run results.
///
/// Every call is an existing Hermes route the proxy already allows:
/// `GET /api/jobs`, `POST /api/jobs/{id}/run|pause|resume`,
/// `DELETE /api/jobs/{id}`, `GET /api/sessions?source=cron`,
/// `GET /api/sessions/{id}/messages`. Cron sessions are only read.
@MainActor
@Observable
final class ScheduledJobsModel {
    struct RunNowState: Equatable {
        var tracker: RunNowTracker
        var phase: RunNowTracker.Phase
        /// The run (cron session) this request produced, once found.
        var resultRun: CronRun?
    }

    static let refreshInterval: TimeInterval = 15

    private(set) var jobs: [HermesJob] = []
    private(set) var loading = false
    private(set) var error: AgentError?
    private(set) var unavailable: String?
    private(set) var lastRefreshed: Date?
    private(set) var runNow: [String: RunNowState] = [:]

    @ObservationIgnored var clientProvider: () -> HermesAPIClient?
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored var pause: (TimeInterval) async throws -> Void
    @ObservationIgnored private var pollers: [String: Task<Void, Never>] = [:]

    init(client: @escaping () -> HermesAPIClient? = { nil },
         now: @escaping () -> Date = Date.init,
         pause: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.clientProvider = client
        self.now = now
        self.pause = pause
    }

    func job(_ id: String) -> HermesJob? { jobs.first { $0.id == id } }

    func phase(of job: HermesJob) -> HermesJobPhase { HermesJobLifecycle.phase(of: job, now: now()) }

    func clearError() { error = nil }

    // MARK: List

    /// `GET /api/jobs?include_disabled=true` — the only route that includes
    /// each job's `latest_execution`.
    @discardableResult
    func refresh() async -> Bool {
        guard let client = clientProvider() else {
            unavailable = "Connect to Hermes to manage scheduled tasks."
            return false
        }
        loading = true
        defer { loading = false }
        do {
            jobs = try await client.jobs()
            error = nil
            unavailable = nil
            lastRefreshed = now()
            return true
        } catch AgentError.remote(let code, let message) where code == "http_501" || code == "not_found" {
            unavailable = code == "not_found"
                ? "This Hermes server does not expose the jobs API."
                : "Hermes reports its scheduler module is unavailable: \(HermesTextSanitizer.sanitize(message))"
        } catch {
            self.error = error.asAgentError
        }
        return false
    }

    /// Refreshes now and then every 15 s until the calling task is cancelled
    /// (SwiftUI cancels `.task` when the screen disappears).
    func autoRefresh() async {
        while !Task.isCancelled {
            await refresh()
            do { try await pause(Self.refreshInterval) } catch { return }
        }
    }

    // MARK: Run now

    /// Requests one run. Ignored while an earlier request for the same job is
    /// still pending, so a double tap can't queue twice from here.
    func runNow(_ job: HermesJob) async {
        if let current = runNow[job.id], !current.phase.isTerminal { return }
        guard let client = clientProvider() else { return }
        // Baseline from fresh data so the new attempt can be told apart.
        await refresh()
        let baseline = self.job(job.id) ?? job
        let tracker = RunNowTracker(job: baseline, triggeredAt: now())
        runNow[job.id] = RunNowState(tracker: tracker, phase: .requesting)
        do {
            let updated = try await client.runJobNow(id: job.id)
            replace(updated)
            // Accepted means queued — not running, not done.
            runNow[job.id]?.phase = .queued
        } catch {
            runNow[job.id] = nil
            self.error = error.asAgentError
            return
        }
        startPolling(jobID: job.id)
    }

    func dismissRunNow(_ jobID: String) {
        pollers[jobID]?.cancel()
        pollers[jobID] = nil
        runNow[jobID] = nil
    }

    private func startPolling(jobID: String) {
        pollers[jobID]?.cancel()
        pollers[jobID] = Task { [weak self] in
            await self?.poll(jobID: jobID)
        }
    }

    private func poll(jobID: String) async {
        while !Task.isCancelled {
            do { try await pause(RunNowTracker.pollInterval) } catch { return }
            guard let state = runNow[jobID] else { return }
            // A failed refresh keeps the last known job; the tracker still
            // times out on its own clock.
            await refresh()
            let phase = state.tracker.evaluate(job(jobID), now: now())
            runNow[jobID]?.phase = phase
            if phase.isTerminal {
                if phase == .completed || isFailed(phase) {
                    runNow[jobID]?.resultRun = await findResultRun(jobID: jobID, tracker: state.tracker)
                }
                pollers[jobID] = nil
                return
            }
        }
    }

    private func isFailed(_ phase: RunNowTracker.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func findResultRun(jobID: String, tracker: RunNowTracker) async -> CronRun? {
        guard let client = clientProvider(), let job = job(jobID) else { return nil }
        guard let runs = try? await client.cronRuns(for: job) else { return nil }
        if let execution = tracker.correlatedExecution(in: job), let match = CronRunMatcher.run(for: execution, in: runs) {
            return match
        }
        return CronRunMatcher.runs(startedAfter: tracker.triggeredAt, in: runs).last
    }

    // MARK: Other actions

    func setPaused(_ job: HermesJob, paused: Bool) async {
        await perform { client in
            let updated: HermesJob
            if paused {
                updated = try await client.pauseJob(id: job.id)
            } else {
                updated = try await client.resumeJob(id: job.id)
            }
            self.replace(updated)
        }
    }

    /// Deletes the job. Hermes (284d220 `remove_job`) removes the schedule and
    /// erases the job's saved outputs; it does NOT stop a run in progress.
    func delete(_ job: HermesJob) async {
        await perform { client in
            try await client.deleteJob(id: job.id)
            self.dismissRunNow(job.id)
            self.jobs.removeAll { $0.id == job.id }
        }
        await refresh()
    }

    // MARK: Runs and results (read-only)

    func runs(for job: HermesJob) async throws -> [CronRun] {
        guard let client = clientProvider() else { throw AgentError.providerUnavailable(detail: "Not connected to Hermes.") }
        return try await client.cronRuns(for: job)
    }

    func result(for run: CronRun) async throws -> (result: CronRunResult, messages: [HermesMessage]) {
        guard let client = clientProvider() else { throw AgentError.providerUnavailable(detail: "Not connected to Hermes.") }
        return try await client.cronRunResult(sessionID: run.sessionID)
    }

    // MARK: Helpers

    private func replace(_ updated: HermesJob) {
        guard let index = jobs.firstIndex(where: { $0.id == updated.id }) else { return }
        var merged = updated
        // Single-job responses don't carry `latest_execution`; keep the last known one.
        if merged.latestExecution == nil { merged.latestExecution = jobs[index].latestExecution }
        jobs[index] = merged
    }

    private func perform(_ body: (HermesAPIClient) async throws -> Void) async {
        guard let client = clientProvider() else { return }
        do {
            try await body(client)
            error = nil
        } catch {
            self.error = error.asAgentError
        }
    }
}
