import Foundation

/// Follows one Hermes run from acceptance to its terminal event and turns it into
/// chat events — reliably and truthfully.
///
/// * Through the Brainbox relay, frames carry sequence numbers: a dropped stream (phone
///   asleep, network switch, a stalled socket) is re-opened with `Last-Event-ID`, so no
///   token is lost, duplicated or re-ordered. Frames for another run are discarded.
/// * Straight from Hermes (no relay) a dropped stream can't be resumed — Hermes deletes the
///   run's queue when its consumer disconnects — so the run is followed by status.
/// * Liveness (`AgentEvent.liveness`) is emitted only on real transitions. Heartbeats prove
///   the link is up; only Hermes events move `lastEventAt`. After `silenceThreshold`
///   seconds without an event a silence warning is raised — never a fabricated failure.
final class HermesRunFollower: @unchecked Sendable {
    struct Config: Sendable {
        var silenceThreshold: TimeInterval = 180
        var watchdogInterval: TimeInterval = 5
        /// No frame at all (not even a heartbeat) for this long on a relay stream → reconnect.
        var stallTimeout: TimeInterval = 45
        /// Relay reconnects before falling back to status polling.
        var maxReconnects = 12
        var maxBackoff: TimeInterval = 15
    }

    let runID: String
    private let client: HermesAPIClient
    private let clock: RunClock
    private let pause: @Sendable (TimeInterval) async throws -> Void
    private let config: Config
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let publish: @Sendable (HermesRunEvent?, HermesRunState?) -> Void
    private let onStatus: @Sendable (AgentStatus) -> Void
    private let state: Locked<State>

    private struct State {
        var mapper: HermesRunMapper
        var tracker: RunTracker
        var cursor: Int?
        var relayBacked = false
        var framesThisConnection = 0
        var stream: Task<Void, Error>?
        var nudges = 0
        var stalledRestart = false
        var lastPolledMarker: String?
    }

    init(runID: String, client: HermesAPIClient, clock: RunClock, config: Config = Config(), alreadyShown: String = "",
         pause: @escaping @Sendable (TimeInterval) async throws -> Void,
         continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
         publish: @escaping @Sendable (HermesRunEvent?, HermesRunState?) -> Void,
         onStatus: @escaping @Sendable (AgentStatus) -> Void = { _ in }) {
        self.onStatus = onStatus
        self.runID = runID
        self.client = client
        self.clock = clock
        self.pause = pause
        self.config = config
        self.continuation = continuation
        self.publish = publish
        var tracker = RunTracker(startedAt: clock.now(), silenceThreshold: config.silenceThreshold)
        _ = tracker.accepted(at: clock.now())
        state = Locked(State(mapper: HermesRunMapper(runID: runID, alreadyShown: alreadyShown), tracker: tracker))
    }

    var finished: Bool { state.withLock { $0.mapper.finished } }

    // MARK: Emission (always under the lock, so ordering is total)

    private func emitLiveness(_ s: inout State) {
        continuation.yield(.liveness(s.tracker.liveness))
    }

    /// Foreground / "Reconnect" button: re-open the stream right away.
    func nudge() {
        let stream = state.withLock { s -> Task<Void, Error>? in
            s.nudges += 1
            return s.relayBacked ? s.stream : nil
        }
        stream?.cancel()
    }

    // MARK: Main loop

    func run() async {
        state.withLock { emitLiveness(&$0) }
        let watchdog = Task { [weak self] in await self?.watch() }
        defer { watchdog.cancel() }

        var attempt = 0
        while !finished {
            if Task.isCancelled { return }
            let cursor = state.withLock { s -> Int? in s.framesThisConnection = 0; return s.cursor }
            let streamTask = Task { [weak self] in
                guard let self else { return }
                for try await frame in self.client.runFrames(id: self.runID, lastEventID: cursor) {
                    if self.handle(frame) { return }
                }
            }
            state.withLock { $0.stream = streamTask }
            var notFound = false
            do {
                try await withTaskCancellationHandler {
                    try await streamTask.value
                } onCancel: {
                    streamTask.cancel()
                }
            } catch AgentError.remote(let code, _) where code == "run_not_found" || code == "not_found" {
                notFound = true
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            if finished { return }

            let (relayBacked, framesSeen, nudged) = state.withLock { s -> (Bool, Int, Bool) in
                let nudged = s.stalledRestart || s.nudges > 0
                s.stalledRestart = false
                s.nudges = 0
                return (s.relayBacked, s.framesThisConnection, nudged)
            }
            // Plain Hermes can't resume a stream; neither can a relay that no longer has the run.
            if notFound || (!relayBacked && (framesSeen > 0 || attempt >= 1)) { break }
            if framesSeen > 0 { attempt = 0 }
            attempt += 1
            if attempt > config.maxReconnects { break }
            state.withLock { s in if s.tracker.reconnecting(attempt: attempt) { emitLiveness(&s) } }
            if !nudged {
                let delay = min(config.maxBackoff, pow(2, Double(attempt - 1)) * 0.5)
                do { try await waitOrNudge(delay) } catch { return }
            }
        }
        if !finished { await followByStatus() }
    }

    /// Sleeps up to `seconds`, returning early on `nudge()`.
    private func waitOrNudge(_ seconds: TimeInterval) async throws {
        let slices = max(1, Int((seconds / 0.25).rounded(.up)))
        for _ in 0..<slices {
            try await pause(min(0.25, seconds))
            if Task.isCancelled { throw CancellationError() }
            if state.withLock({ $0.nudges > 0 }) { state.withLock { $0.nudges = 0 }; return }
        }
    }

    /// Returns true when the run reached its terminal event.
    private func handle(_ frame: HermesRunFrame) -> Bool {
        let now = clock.now()
        return state.withLock { s -> Bool in
            if let other = frame.runID, other != runID { return false } // stale / foreign event
            if let seq = frame.seq {
                s.relayBacked = true
                if let cursor = s.cursor, seq <= cursor { return false } // duplicate after resume
                s.cursor = seq
            }
            s.framesThisConnection += 1
            switch frame.kind {
            case .heartbeat(let beat):
                if s.tracker.heartbeat(beat, at: now) { emitLiveness(&s) }
                return false
            case .upstream(let upstreamState, let detail):
                if s.tracker.upstream(state: upstreamState, detail: detail, at: now) { emitLiveness(&s) }
                return false
            case .snapshot(let text):
                _ = s.tracker.frameReceived(at: now)
                for mapped in s.mapper.applySnapshot(text) { continuation.yield(mapped) }
                return false
            case .event(let event):
                if s.mapper.finished { return true }
                _ = s.tracker.frameReceived(at: now)
                // Status first: the reply's terminal event must be the last thing emitted.
                if s.tracker.observe(event, at: now) { emitLiveness(&s) }
                publish(event, HermesAgentProvider.state(after: event))
                for mapped in s.mapper.map(event) {
                    if case .status(let agentStatus) = mapped { onStatus(agentStatus) }
                    continuation.yield(mapped)
                }
                return s.mapper.finished
            }
        }
    }

    // MARK: Watchdog: silence + stalled sockets

    private func watch() async {
        while !Task.isCancelled {
            do { try await clock.sleep(seconds: config.watchdogInterval) } catch { return }
            let now = clock.now()
            let stalled = state.withLock { s -> Task<Void, Error>? in
                if s.mapper.finished { return nil }
                if s.tracker.tick(now: now) { emitLiveness(&s) }
                // A relay stream sends a heartbeat at least every 15 s; silence on the socket
                // itself means it's dead (common after iOS suspends the app).
                if s.relayBacked, s.tracker.liveness.transport == .live,
                   s.tracker.streamIdle(now: now) >= config.stallTimeout, let stream = s.stream {
                    s.stalledRestart = true
                    if s.tracker.disconnected() { emitLiveness(&s) }
                    return stream
                }
                return nil
            }
            stalled?.cancel()
        }
    }

    // MARK: Status fallback

    private func followByStatus() async {
        var failures = 0
        while !finished {
            if Task.isCancelled { continuation.yield(.failed(.cancelled)); return }
            do {
                let status = try await client.runStatus(id: runID)
                failures = 0
                let now = clock.now()
                state.withLock { s in
                    let marker = "\(status.updatedAt ?? 0)|\(status.lastEvent ?? "")"
                    let moved = s.lastPolledMarker != nil && s.lastPolledMarker != marker
                    s.lastPolledMarker = marker
                    var changed = s.tracker.polled(status: status.status.rawValue, changedOnServer: moved, at: now)
                    let terminal: HermesRunEvent? = {
                        switch status.status {
                        case .completed: return .completed(output: status.output, usage: status.usage, pendingSteer: status.pendingSteer)
                        case .failed: return .failed(error: status.error)
                        case .cancelled: return .cancelled
                        case .interrupted: return .interrupted(error: status.error)
                        default: return nil
                        }
                    }()
                    if let terminal, s.tracker.observe(terminal, at: now) { changed = true }
                    if changed { emitLiveness(&s) }
                    for mapped in s.mapper.reconcile(status) { continuation.yield(mapped) }
                }
                publish(nil, status.status)
                if finished { return }
            } catch AgentError.remote(let code, _) where code == "run_not_found" {
                continuation.yield(.failed(.remote(code: "run_expired", message: "Hermes no longer tracks this run (status is kept only briefly after it ends). Its reply is in the session history.")))
                return
            } catch {
                failures += 1
                state.withLock { s in if s.tracker.disconnected() { emitLiveness(&s) } }
                if failures >= 20 {
                    continuation.yield(.failed(.remote(code: "run_detached", message: "Lost contact with this run. It may still be running on the VPS — check Tasks.")))
                    return
                }
            }
            do { try await pause(min(client.configuration.pollInterval * Double(max(failures, 1)), 15)) } catch {
                continuation.yield(.failed(.cancelled)); return
            }
        }
    }
}
