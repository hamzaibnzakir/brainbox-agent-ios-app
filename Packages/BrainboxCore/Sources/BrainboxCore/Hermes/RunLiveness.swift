import Foundation

// Truthful run progress.
//
// Everything shown here is derived from real signals only:
// * Hermes run events (message.delta, tool.started/completed, approval.*, run.*) — the only
//   things that count as agent activity (`lastEventAt`).
// * Transport signals (relay heartbeats, Hermes keepalives, reconnects) — they prove the
//   connection is alive, never that the agent made progress.
// The UI labels these as status indicators, never as model reasoning.

/// What the run is doing, as far as real events tell us.
public enum RunPhase: String, Codable, Hashable, Sendable {
    /// Sending the request / opening the event stream.
    case connecting
    /// Hermes accepted the run; no agent event has arrived yet.
    case started
    /// Hermes is holding the run before starting it (newer Hermes `run.queued`).
    case queued
    /// Text is streaming.
    case responding
    /// A tool reported start and hasn't reported completion.
    case runningTool
    /// Between steps (a tool finished, nothing new yet).
    case working
    case waitingForApproval
    case stopping
    case completed
    case failed
    case interrupted
}

/// The link between the app and the run's events.
public enum RunTransport: String, Codable, Hashable, Sendable {
    /// Receiving the live event stream.
    case live
    /// The stream dropped; reconnecting (relay resumes without loss).
    case reconnecting
    /// Following the run by polling its status (no live tokens).
    case polling
    /// No contact with the server right now.
    case disconnected
}

public struct RunLiveness: Codable, Hashable, Sendable {
    public var phase: RunPhase
    public var transport: RunTransport
    public var toolName: String?
    public var startedAt: Date
    /// Last real Hermes event (never a heartbeat).
    public var lastEventAt: Date?
    /// Set once no Hermes event has arrived for the silence threshold.
    public var silentSince: Date?
    public var reconnectAttempt: Int
    /// Hermes' own run status from the latest relay heartbeat or status poll.
    public var serverStatus: String?
    /// The relay lost Hermes' live stream and follows the run by status.
    public var upstreamNote: String?

    public init(phase: RunPhase, transport: RunTransport = .live, toolName: String? = nil, startedAt: Date,
                lastEventAt: Date? = nil, silentSince: Date? = nil, reconnectAttempt: Int = 0,
                serverStatus: String? = nil, upstreamNote: String? = nil) {
        self.phase = phase
        self.transport = transport
        self.toolName = toolName
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.silentSince = silentSince
        self.reconnectAttempt = reconnectAttempt
        self.serverStatus = serverStatus
        self.upstreamNote = upstreamNote
    }

    public var isTerminal: Bool { [.completed, .failed, .interrupted].contains(phase) }

    /// Short status-indicator label (not model output).
    public var label: String {
        switch phase {
        case .connecting: return "Connecting"
        case .started: return "Started · waiting for the agent"
        case .queued: return "Queued by Hermes" + (serverStatus.map { " · \($0)" } ?? "")
        case .responding: return "Responding"
        case .runningTool: return "Running \(toolName.map { RunLiveness.toolTitle($0) } ?? "a tool")"
        case .working: return "Working"
        case .waitingForApproval: return "Waiting for your approval"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        }
    }

    public var transportLabel: String? {
        switch transport {
        case .live: return nil
        case .reconnecting: return reconnectAttempt > 1 ? "Reconnecting (attempt \(reconnectAttempt))" : "Reconnecting"
        case .polling: return "Following by status — live text paused"
        case .disconnected: return "Disconnected"
        }
    }

    /// The silence warning, worded by what is actually known. Nil while events flow.
    public func silenceWarning(now: Date) -> String? {
        guard let since = silentSince, !isTerminal else { return nil }
        let reference = lastEventAt ?? startedAt
        let minutes = max(Int(now.timeIntervalSince(reference) / 60), Int(since.timeIntervalSince(reference) / 60))
        let span = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        switch transport {
        case .disconnected, .reconnecting:
            return "No response received for \(span), and the connection to the server is down. Brainbox is reconnecting — this is not a confirmed failure."
        case .polling:
            return "No response received for \(span). Brainbox is following the run by status; Hermes still reports it as \(serverStatus ?? "running")."
        case .live:
            if phase == .runningTool, let toolName {
                return "No response received for \(span) while \(RunLiveness.toolTitle(toolName)) runs. The connection is fine — the tool may just be slow, or stuck."
            }
            if phase == .waitingForApproval { return nil }
            return "No response received for \(span). The connection is fine — Hermes may still be working, or it may be stuck."
        }
    }

    static func toolTitle(_ name: String) -> String { "`\(name)`" }
}

/// Wall clock + sleep, injectable so silence detection is tested with a controllable clock.
public protocol RunClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemRunClock: RunClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

/// Relay transport heartbeat (`brainbox.heartbeat`). Liveness of the link only.
public struct RelayHeartbeat: Hashable, Sendable {
    public var lastSeq: Int?
    public var upstream: String?
    public var hermesStatus: String?
    public init(lastSeq: Int? = nil, upstream: String? = nil, hermesStatus: String? = nil) {
        self.lastSeq = lastSeq
        self.upstream = upstream
        self.hermesStatus = hermesStatus
    }
}

/// Pure state machine behind `RunLiveness`. Every mutation returns whether the
/// visible liveness changed, so callers only emit real transitions.
public struct RunTracker: Sendable {
    public var silenceThreshold: TimeInterval
    public private(set) var liveness: RunLiveness
    private var runningTools: [String] = []
    public private(set) var lastFrameAt: Date

    public init(startedAt: Date, silenceThreshold: TimeInterval = 180) {
        self.silenceThreshold = silenceThreshold
        liveness = RunLiveness(phase: .connecting, startedAt: startedAt)
        lastFrameAt = startedAt
    }

    private mutating func change(_ body: (inout RunLiveness) -> Void) -> Bool {
        let before = liveness
        body(&liveness)
        return liveness != before
    }

    public mutating func accepted(at date: Date) -> Bool {
        lastFrameAt = date
        return change { $0.phase = .started; $0.transport = .live }
    }

    /// Any frame from the stream (event or heartbeat): the link is alive.
    public mutating func frameReceived(at date: Date) -> Bool {
        lastFrameAt = date
        return change {
            if $0.transport != .polling { $0.transport = .live }
            $0.reconnectAttempt = 0
        }
    }

    /// A real Hermes event. Clears any silence warning.
    public mutating func observe(_ event: HermesRunEvent, at date: Date) -> Bool {
        lastFrameAt = date
        if case .unknown = event { return false }
        var l = liveness
        l.lastEventAt = date
        l.silentSince = nil
        switch event {
        case .messageDelta, .interim:
            if l.phase != .stopping { l.phase = .responding }
        case .queued(let message):
            l.phase = .queued
            if let message, !message.isEmpty { l.serverStatus = message }
        case .toolStarted(let tool, _):
            runningTools.append(tool)
            if l.phase != .stopping { l.phase = .runningTool; l.toolName = tool }
        case .toolCompleted(let tool, _, _):
            if let index = runningTools.firstIndex(of: tool) { runningTools.remove(at: index) }
            if l.phase != .stopping {
                if let next = runningTools.last { l.phase = .runningTool; l.toolName = next } else { l.phase = .working; l.toolName = nil }
            }
        case .approvalRequest:
            l.phase = .waitingForApproval
        case .approvalResponded, .steered, .reasoning, .subagentStarted, .subagentCompleted:
            if l.phase == .waitingForApproval || l.phase == .started { l.phase = .working }
        case .stopping:
            l.phase = .stopping
        case .completed:
            l.phase = .completed; l.toolName = nil
        case .failed:
            l.phase = .failed; l.toolName = nil
        case .cancelled, .interrupted:
            l.phase = .interrupted; l.toolName = nil
        case .unknown:
            break
        }
        let changed = l != liveness
        liveness = l
        return changed
    }

    public mutating func heartbeat(_ beat: RelayHeartbeat, at date: Date) -> Bool {
        lastFrameAt = date
        return change {
            if $0.transport != .polling { $0.transport = .live }
            $0.reconnectAttempt = 0
            if let status = beat.hermesStatus, !status.isEmpty { $0.serverStatus = status }
        }
    }

    /// The relay reports its link to Hermes (`brainbox.upstream`).
    public mutating func upstream(state: String, detail: String?, at date: Date) -> Bool {
        lastFrameAt = date
        return change {
            switch state {
            case "polling", "lost": $0.upstreamNote = detail ?? "Hermes' live stream ended early; following the run by status."
            case "gone": $0.upstreamNote = detail ?? "Hermes no longer tracks this run."
            case "live": $0.upstreamNote = nil
            default: break
            }
        }
    }

    public mutating func reconnecting(attempt: Int) -> Bool {
        change { $0.transport = .reconnecting; $0.reconnectAttempt = attempt }
    }

    public mutating func disconnected() -> Bool {
        change { $0.transport = .disconnected }
    }

    /// Following by status. `changedOnServer` is true when Hermes' own status shows new
    /// activity since the previous poll (its `updated_at`/`last_event` moved).
    public mutating func polled(status: String?, changedOnServer: Bool, at date: Date) -> Bool {
        lastFrameAt = date
        return change {
            $0.transport = .polling
            $0.reconnectAttempt = 0
            if let status, !status.isEmpty { $0.serverStatus = status }
            if changedOnServer { $0.lastEventAt = date; $0.silentSince = nil }
            if status == "waiting_for_approval" { $0.phase = .waitingForApproval }
            else if status == "stopping" { $0.phase = .stopping }
        }
    }

    /// Re-evaluates silence at `now`.
    public mutating func tick(now: Date) -> Bool {
        guard !liveness.isTerminal else { return false }
        let reference = liveness.lastEventAt ?? liveness.startedAt
        let silent = now.timeIntervalSince(reference) >= silenceThreshold && liveness.phase != .waitingForApproval
        return change {
            if silent, $0.silentSince == nil { $0.silentSince = now }
            if !silent { $0.silentSince = nil }
        }
    }

    /// Seconds since anything (event or heartbeat) arrived on the stream.
    public func streamIdle(now: Date) -> TimeInterval { now.timeIntervalSince(lastFrameAt) }
}

/// Hermes gives API-server sessions a platform hint that says "assume plain text, no
/// markdown, keep responses brief" (agent/prompt_builder.py, `api_server`), while Telegram's
/// hint says Markdown renders. This client renders Markdown, so every run carries this
/// note in `instructions` (Hermes' ephemeral, never-persisted, cache-safe system prompt
/// slot). It describes the client truthfully; it doesn't change the model or persona.
public enum HermesClientNote {
    public static let text = """
    Client: Brainbox Agent, a native iOS app talking to you through the Hermes API. It renders standard \
    Markdown (headings, bold, italics, lists, tables, code blocks, links), so the API-server guidance to use \
    plain text and keep replies brief does not apply here: format and size your answers as you would on \
    Telegram. This client does not deliver MEDIA: tags; give file paths as plain text instead.
    """

    /// The note followed by any preset instructions.
    public static func compose(_ instructions: String?) -> String {
        guard let own = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty else { return text }
        return text + "\n\n" + own
    }
}
