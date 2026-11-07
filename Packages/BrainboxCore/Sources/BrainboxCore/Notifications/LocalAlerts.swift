import Foundation

// Local notifications (UserNotifications), posted by the app itself.
//
// Free Apple developer accounts can't use APNs, so nothing is pushed from the
// server. Instead the app notices events — from live run streams while it runs,
// from polling while it's open, and from iOS background refresh when iOS grants
// it — and posts a local notification. This file holds the platform-neutral part:
// what counts as a new event, preferences, and dedupe (an event never alerts twice,
// across launches too). Alerts carry titles and short neutral text plus a
// `brainbox://` link — never prompts, outputs or commands.

public enum LocalAlertKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case taskFinished, taskFailed, approvalNeeded, jobFinished, jobFailed, agentsFinished, connectionLost
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .taskFinished: return "Task finished"
        case .taskFailed: return "Task failed or stopped"
        case .approvalNeeded: return "Approval needed"
        case .jobFinished: return "Scheduled task finished"
        case .jobFailed: return "Scheduled task failed"
        case .agentsFinished: return "Parallel agents finished"
        case .connectionLost: return "Connection lost"
        }
    }
}

public struct LocalAlert: Hashable, Sendable {
    public var kind: LocalAlertKind
    public var title: String
    public var body: String
    public var link: String
    /// Stable id of the underlying event; the same key never alerts twice.
    public var dedupeKey: String

    public init(kind: LocalAlertKind, title: String, body: String, link: String, dedupeKey: String) {
        self.kind = kind
        self.title = title
        self.body = body
        self.link = link
        self.dedupeKey = dedupeKey
    }
}

/// Remembers which events already alerted (bounded; persisted by the app).
public struct AlertLedger: Codable, Hashable, Sendable {
    public private(set) var keys: [String] = []
    public var capacity = 500

    public init() {}

    public func contains(_ key: String) -> Bool { keys.contains(key) }

    /// True the first time a key is seen.
    public mutating func record(_ key: String) -> Bool {
        guard !keys.contains(key) else { return false }
        keys.append(key)
        if keys.count > capacity { keys.removeFirst(keys.count - capacity) }
        return true
    }
}

/// Turns successive `/api/jobs` snapshots into "finished"/"failed" alerts.
/// The first snapshot only records state: existing history never alerts.
public struct JobAlertDetector: Codable, Hashable, Sendable {
    /// job id → "executionID|status" from the last snapshot (nil = not seeded yet).
    public private(set) var seen: [String: String]?

    public init() {}

    public mutating func alerts(for jobs: [HermesJob]) -> [LocalAlert] {
        var current: [String: String] = [:]
        for job in jobs {
            guard let execution = job.latestExecution else { continue }
            current[job.id] = "\(execution.id)|\(execution.rawStatus)"
        }
        defer { seen = current }
        guard let previous = seen else { return [] }
        var out: [LocalAlert] = []
        for job in jobs {
            guard let execution = job.latestExecution, let key = current[job.id], key != previous[job.id] else { continue }
            let status = execution.rawStatus.lowercased()
            if status == "completed" || status == "succeeded" || status == "ok" {
                out.append(LocalAlert(kind: .jobFinished, title: "Scheduled task finished", body: "“\(job.name)” ran. Tap to see the result.",
                                      link: "brainbox://tasks/job/\(job.id)", dedupeKey: "job:\(job.id):\(execution.id):done"))
            } else if ["failed", "error", "timed_out", "interrupted"].contains(status) {
                out.append(LocalAlert(kind: .jobFailed, title: "Scheduled task failed", body: "“\(job.name)” didn't finish. Tap to see what happened.",
                                      link: "brainbox://tasks/job/\(job.id)", dedupeKey: "job:\(job.id):\(execution.id):failed"))
            }
        }
        return out
    }
}

public enum RunAlerts {
    /// Alert for a run (chat reply or task) reaching a state worth telling the user about.
    public static func alert(runID: String, title: String, state: HermesRunState) -> LocalAlert? {
        let name = title.isEmpty ? "Your task" : "“\(String(title.prefix(60)))”"
        switch state {
        case .completed:
            return LocalAlert(kind: .taskFinished, title: "Task finished", body: "\(name) is done.",
                              link: "brainbox://tasks/run/\(runID)", dedupeKey: "run:\(runID):completed")
        case .failed, .interrupted:
            return LocalAlert(kind: .taskFailed, title: "Task didn't finish", body: "\(name) stopped with an error.",
                              link: "brainbox://tasks/run/\(runID)", dedupeKey: "run:\(runID):failed")
        case .waitingForApproval:
            return LocalAlert(kind: .approvalNeeded, title: "Approval needed", body: "\(name) is waiting for your decision.",
                              link: "brainbox://tasks/run/\(runID)", dedupeKey: "run:\(runID):approval")
        default:
            return nil
        }
    }

    public static func alert(for task: ParallelTask) -> LocalAlert? {
        guard task.isFinished else { return nil }
        let done = task.agents.filter { $0.state == .completed }.count
        return LocalAlert(kind: .agentsFinished, title: "Parallel agents finished",
                          body: "\(done) of \(task.agents.count) agents finished “\(String(task.title.prefix(60)))”.",
                          link: "brainbox://agents/\(task.id.uuidString.lowercased())", dedupeKey: "par:\(task.id.uuidString):done")
    }
}
