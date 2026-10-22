import Foundation

// Scheduled-task (Hermes cron) lifecycle, "run now" tracking and run results.
//
// Everything here is derived from existing, read-only Hermes API data
// (verified against hermes-agent 284d220):
//   * GET /api/jobs                    → jobs incl. `latest_execution` (list only)
//   * GET /api/sessions?source=cron    → one session per cron run,
//                                        id `cron_<job_id>_<YYYYmmdd_HHMMSS>`,
//                                        title `<job name> · <Mon DD HH:MM>`
//   * GET /api/sessions/{id}/messages  → that run's transcript
// Nothing here writes to Hermes except the explicit "run now" call.

// MARK: - Lifecycle

/// What a scheduled job is doing, from the fields Hermes actually returns.
/// Never "completed" just because a request was accepted.
public enum HermesJobPhase: Hashable, Sendable {
    /// Enabled, waiting for its next run; has never run (or no outcome yet).
    case scheduled
    /// Run requested (`manual_run_at`) or due, not yet picked up by the scheduler.
    case queued
    /// Claimed by the scheduler, about to start.
    case starting
    case running
    case completed
    /// The run worked but delivering its result failed.
    case completedDeliveryFailed
    case failed
    /// Hermes can't confirm how the last attempt ended (worker vanished).
    case unknown
    case paused
    /// A one-shot or limited job that has finished all its runs.
    case finished

    public var label: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .queued: return "Queued"
        case .starting: return "Starting"
        case .running: return "Running"
        case .completed: return "Completed"
        case .completedDeliveryFailed: return "Completed · delivery failed"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        case .paused: return "Paused"
        case .finished: return "Finished"
        }
    }

    public var isActive: Bool { self == .queued || self == .starting || self == .running }
}

public enum HermesJobLifecycle {
    /// Phase of a job right now. Precedence: an in-flight attempt beats
    /// everything; then pause; then a pending manual run; then the outcome
    /// of the last finished attempt; then Hermes' own state.
    public static func phase(of job: HermesJob, now: Date = Date()) -> HermesJobPhase {
        if let execution = job.latestExecution {
            switch execution.status {
            case .claimed: return .starting
            case .running: return .running
            default: break
            }
        }
        if !job.enabled || job.paused || job.state == "paused" { return .paused }
        if job.manualRunAt != nil { return .queued }
        if let execution = job.latestExecution, isNewest(execution, comparedTo: job) {
            switch execution.status {
            case .completed:
                return deliveryFailed(job) ? .completedDeliveryFailed : (job.state == "completed" ? .finished : .completed)
            case .failed: return .failed
            case .unknown: return .unknown
            default: break
            }
        }
        switch job.lastStatus {
        case "ok"?: return job.state == "completed" ? .finished : .completed
        case "delivery_failed"?: return .completedDeliveryFailed
        case "error"?, "failed"?: return .failed
        case nil: break
        default: return .unknown
        }
        if job.state == "error" { return .failed }
        if job.state == "completed" { return .finished }
        if let next = job.nextRun.flatMap(HermesDates.parse), next <= now { return .queued }
        return .scheduled
    }

    /// The ledger's newest attempt is authoritative unless the job record
    /// shows a later finished run (ledger write failed or was pruned).
    static func isNewest(_ execution: HermesJobExecution, comparedTo job: HermesJob) -> Bool {
        guard let lastRun = job.lastRun.flatMap(HermesDates.parse) else { return true }
        let executionTime = (execution.finishedAt ?? execution.startedAt ?? execution.claimedAt).flatMap(HermesDates.parse)
        guard let executionTime else { return true }
        return executionTime >= lastRun.addingTimeInterval(-120)
    }

    static func deliveryFailed(_ job: HermesJob) -> Bool {
        job.lastStatus == "delivery_failed"
    }

    /// The most useful failure text for a job, sanitized for display.
    public static func failureDetail(of job: HermesJob) -> String? {
        let candidates = [job.latestExecution?.status == .failed ? job.latestExecution?.error : nil,
                          job.lastError,
                          job.lastStatus == "delivery_failed" ? job.lastDeliveryError : nil]
        for case let text? in candidates where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return HermesTextSanitizer.sanitize(text)
        }
        return nil
    }
}

// MARK: - Run now

/// Follows one "run now" request. Hermes' trigger call returns only the
/// updated job (no execution id), so the run is correlated as: the first
/// ledger attempt whose id differs from the one seen before triggering and
/// that was claimed no earlier than the trigger. Without such evidence the
/// state stays queued, and after `timeout` becomes unknown — it is never
/// reported as completed, and the job is never triggered again.
public struct RunNowTracker: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case requesting
        case queued
        case starting
        case running
        case completed
        case failed(String?)
        case unknown(String)

        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .unknown: return true
            default: return false
            }
        }

        public var label: String {
            switch self {
            case .requesting: return "Sending…"
            case .queued: return "Queued — waiting for the scheduler"
            case .starting: return "Starting"
            case .running: return "Running"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .unknown: return "Status unknown"
            }
        }
    }

    public static let pollInterval: TimeInterval = 5
    /// Scheduler tick (~60 s) + Hermes' default 600 s inactivity watchdog + margin.
    public static let timeout: TimeInterval = 12 * 60
    /// Allowed clock difference between the phone and the VPS.
    public static let clockSkew: TimeInterval = 120

    public let jobID: String
    public let baselineExecutionID: String?
    public let baselineLastRun: String?
    public let triggeredAt: Date

    public init(job: HermesJob, triggeredAt: Date = Date()) {
        jobID = job.id
        baselineExecutionID = job.latestExecution?.id
        baselineLastRun = job.lastRun
        self.triggeredAt = triggeredAt
    }

    /// The execution this request started, once one is visible.
    public func correlatedExecution(in job: HermesJob) -> HermesJobExecution? {
        guard let execution = job.latestExecution, execution.id != baselineExecutionID else { return nil }
        if let claimed = (execution.claimedAt ?? execution.startedAt).flatMap(HermesDates.parse),
           claimed < triggeredAt.addingTimeInterval(-Self.clockSkew) {
            return nil
        }
        return execution
    }

    public func evaluate(_ job: HermesJob?, now: Date = Date()) -> Phase {
        guard let job else { return .unknown("This job no longer exists on Hermes.") }
        if let execution = correlatedExecution(in: job) {
            switch execution.status {
            case .claimed: return pendingOrTimedOut(.starting, now: now)
            case .running: return pendingOrTimedOut(.running, now: now)
            case .completed: return .completed
            case .failed: return .failed(execution.error.map { HermesTextSanitizer.sanitize($0) })
            case .unknown:
                return .unknown("Hermes couldn't confirm how this run ended (its worker stopped before recording a result).")
            }
        }
        // No ledger evidence: fall back to the job record's own outcome,
        // but only if it changed since we triggered.
        if let lastRun = job.lastRun, lastRun != baselineLastRun, job.manualRunAt == nil {
            switch job.lastStatus {
            case "ok"?, "delivery_failed"?: return .completed
            case "error"?, "failed"?: return .failed(HermesJobLifecycle.failureDetail(of: job))
            default: return .unknown("Hermes recorded a run but not its outcome.")
            }
        }
        return pendingOrTimedOut(.queued, now: now)
    }

    private func pendingOrTimedOut(_ phase: Phase, now: Date) -> Phase {
        guard now.timeIntervalSince(triggeredAt) > Self.timeout else { return phase }
        let minutes = Int(Self.timeout / 60)
        switch phase {
        case .queued:
            return .unknown("No run was picked up within \(minutes) minutes. Hermes may be busy or its scheduler may be stopped. The job was not triggered again.")
        default:
            return .unknown("Still \(phase.label.lowercased()) after \(minutes) minutes. The list keeps refreshing; check back later.")
        }
    }
}

// MARK: - Runs and results

/// One cron run, as stored by Hermes as a session.
public struct CronRun: Hashable, Sendable, Identifiable {
    public var id: String { sessionID }
    public var sessionID: String
    public var jobID: String
    public var title: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var endReason: String?
    public var messageCount: Int?

    public init(sessionID: String, jobID: String, title: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil,
                endReason: String? = nil, messageCount: Int? = nil) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.messageCount = messageCount
    }
}

public enum CronRunMatcher {
    public static func idPrefix(for jobID: String) -> String { "cron_\(jobID)_" }

    /// Title Hermes gives a run's session (see `cron/scheduler.py`).
    public static func titlePrefix(for jobName: String) -> String {
        let collapsed = jobName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(60)).trimmingCharacters(in: .whitespaces) + " · "
    }

    /// Sessions that belong to `job`, newest first. Matches the session id
    /// prefix; the title is only used for sessions with no `cron_<id>_` id at
    /// all (e.g. after a compression rotation), and only from cron sources.
    public static func runs(for job: HermesJob, in sessions: [HermesSession]) -> [CronRun] {
        let prefix = idPrefix(for: job.id)
        let title = titlePrefix(for: job.name)
        var seen = Set<String>()
        let matched = sessions.filter { session in
            guard seen.insert(session.id).inserted else { return false }
            if session.id.hasPrefix(prefix) { return true }
            let fromCron = session.source == "cron" || session.id.hasPrefix("cron_")
            let otherJob = session.id.hasPrefix("cron_") && !session.id.hasPrefix(prefix)
            return fromCron && !otherJob && (session.title?.hasPrefix(title) ?? false)
        }
        return matched.map { session in
            CronRun(sessionID: session.id, jobID: job.id, title: session.title,
                    startedAt: session.startedAt.map { Date(timeIntervalSince1970: $0) } ?? timestamp(fromSessionID: session.id, jobID: job.id),
                    endedAt: session.endedAt.map { Date(timeIntervalSince1970: $0) },
                    endReason: session.endReason, messageCount: session.messageCount)
        }
        .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// `cron_<job>_<YYYYmmdd_HHMMSS>` → that wall-clock time. Hermes writes it
    /// in its own time zone, which the id doesn't record, so this is read as
    /// UTC and only used for ordering when `started_at` is missing.
    public static func timestamp(fromSessionID id: String, jobID: String) -> Date? {
        let prefix = idPrefix(for: jobID)
        guard id.hasPrefix(prefix) else { return nil }
        let stamp = String(id.dropFirst(prefix.count).prefix(15))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.date(from: stamp)
    }

    /// The run that belongs to a ledger attempt: the session that started
    /// closest to the attempt's start, within `tolerance`.
    public static func run(for execution: HermesJobExecution, in runs: [CronRun], tolerance: TimeInterval = 300) -> CronRun? {
        guard let start = (execution.startedAt ?? execution.claimedAt).flatMap(HermesDates.parse) else { return nil }
        return runs
            .compactMap { run -> (CronRun, TimeInterval)? in
                guard let started = run.startedAt else { return nil }
                let distance = abs(started.timeIntervalSince(start))
                return distance <= tolerance ? (run, distance) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    /// Runs that started at or after a "run now" trigger (allowing clock skew).
    public static func runs(startedAfter date: Date, in runs: [CronRun]) -> [CronRun] {
        runs.filter { ($0.startedAt ?? .distantPast) >= date.addingTimeInterval(-RunNowTracker.clockSkew) }
    }
}

/// What a run produced, taken from its transcript.
public enum CronRunResult: Hashable, Sendable {
    /// The final assistant reply.
    case text(String)
    /// The run has messages but no assistant reply (e.g. it failed first).
    case noReply
    /// The session has no messages (yet).
    case empty

    public static func from(messages: [HermesMessage]) -> CronRunResult {
        guard !messages.isEmpty else { return .empty }
        let ordered = messages.enumerated().sorted { a, b in
            switch (a.element.timestamp, b.element.timestamp) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }.map(\.element)
        if let reply = ordered.last(where: { $0.role == "assistant" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .text(reply.content)
        }
        return .noReply
    }
}

// MARK: - Helpers

public enum HermesTextSanitizer {
    /// Makes server-provided error text safe and readable to show: redacts
    /// bearer tokens, key/secret assignments and long opaque strings,
    /// collapses whitespace and caps the length.
    public static func sanitize(_ text: String, maxLength: Int = 400) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer •••"),
            (#"(?i)\b([A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]*)\s*[=:]\s*\S+"#, "$1=•••"),
            (#"\b(sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9_\-]{8,}"#, "•••"),
            (#"\b[A-Za-z0-9_\-]{40,}\b"#, "•••")
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if result.count > maxLength { result = String(result.prefix(maxLength)) + "…" }
        return result
    }
}

public enum HermesDates {
    /// Parses Hermes' ISO-8601 timestamps (with or without fractional
    /// seconds; with an offset, or naive = UTC).
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        // Naive timestamps: treat as UTC, trimming fractions beyond milliseconds.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        // Offsets with microseconds (Python isoformat): drop extra fraction digits.
        if let regex = try? NSRegularExpression(pattern: #"(\.\d{3})\d+"#) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            let shortened = regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "$1")
            if shortened != trimmed { return parse(shortened) }
        }
        return nil
    }
}

// MARK: - Client helpers (read-only GETs)

extension HermesAPIClient {
    /// Runs of one job, newest first, from `GET /api/sessions?source=cron`
    /// (paged). If that filter finds nothing for the job, falls back to an
    /// unfiltered scan in case this Hermes stores cron sessions under another
    /// source label; only ids/titles that match the job are kept.
    public func cronRuns(for job: HermesJob, pageSize: Int = 100, maxPages: Int = 3) async throws -> [CronRun] {
        func scan(source: String?) async throws -> [HermesSession] {
            var collected: [HermesSession] = []
            var offset = 0
            for _ in 0..<maxPages {
                let page = try await sessions(limit: pageSize, offset: offset, source: source)
                collected += page.sessions
                guard page.hasMore, !page.sessions.isEmpty else { break }
                offset += page.sessions.count
            }
            return collected
        }
        let filtered = CronRunMatcher.runs(for: job, in: try await scan(source: "cron"))
        if !filtered.isEmpty { return filtered }
        return CronRunMatcher.runs(for: job, in: try await scan(source: nil))
    }

    /// The final reply of one run (read-only).
    public func cronRunResult(sessionID: String) async throws -> (result: CronRunResult, messages: [HermesMessage]) {
        let page = try await messages(sessionID: sessionID, limit: 200, order: "latest")
        return (CronRunResult.from(messages: page.messages), page.messages)
    }
}
