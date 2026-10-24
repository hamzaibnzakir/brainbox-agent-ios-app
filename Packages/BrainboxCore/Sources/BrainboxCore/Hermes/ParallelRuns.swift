import Foundation

// Concurrent agents: several independent Hermes runs at once.
//
// Each agent is its own `POST /v1/runs` in its own `ios_` session, so it has its
// own run id, context, event stream, stop and result on the server — Hermes runs
// them concurrently (up to `gateway.api_server.max_concurrent_runs`, default 10;
// over the cap it answers 429 + Retry-After). Nothing is simulated: progress is
// what the run streams report, and a cancel is `POST /v1/runs/{id}/stop` for that
// run only. When every agent has settled, an optional synthesis run combines the
// results in a separate session.
//
// Duplicate submissions are prevented with `Idempotency-Key` = the agent's id
// (Hermes replays the original run instead of starting a second one), so a
// retry after a lost response or an app relaunch never runs the same work twice.

public struct ParallelAgent: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case waiting        // not started (waiting for a free slot)
        case starting       // creating the session / run
        case running
        case waitingForApproval
        case stopping       // stop sent, Hermes is interrupting it
        case completed
        case failed
        case cancelled
        case lost           // Hermes no longer knows the run (e.g. it restarted)

        public var isTerminal: Bool { [.completed, .failed, .cancelled, .lost].contains(self) }
    }

    /// A `delegate_task` child reported by Hermes inside this agent's run.
    public struct Subagent: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var goal: String?
        public var status: String?
        public var summary: String?
        public var finished: Bool
    }

    public var id: UUID
    public var title: String
    public var prompt: String
    public var instructions: String?
    public var model: String?
    public var sessionID: String
    public var runID: String?
    public var state: State
    public var output: String
    public var activity: [String]
    public var subagents: [Subagent]
    public var error: String?
    public var attempts: Int
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Stop requested by the user (so a later `cancelled` is expected, and a
    /// run that hasn't started yet is never started).
    public var cancelRequested: Bool
    /// Set by a retry so the new attempt gets its own idempotency key.
    public var retryKey: UUID?

    public init(id: UUID = UUID(), title: String, prompt: String, instructions: String? = nil, model: String? = nil) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.instructions = instructions
        self.model = model
        self.sessionID = HermesAgentProvider.sessionID(for: id)
        self.state = .waiting
        self.output = ""
        self.activity = []
        self.subagents = []
        self.attempts = 0
        self.cancelRequested = false
    }
}

public struct ParallelTask: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var agents: [ParallelAgent]
    /// Combines the agents' results once they've all settled (nil = not wanted).
    public var synthesis: ParallelAgent?
    public var wantsSynthesis: Bool
    /// `/bg`: the chat the result is posted back to when the task settles.
    public var originConversationID: UUID?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), agents: [ParallelAgent], wantsSynthesis: Bool = true,
                originConversationID: UUID? = nil) {
        self.originConversationID = originConversationID
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.agents = agents
        self.wantsSynthesis = wantsSynthesis
    }

    public var agentsSettled: Bool { agents.allSatisfy { $0.state.isTerminal } }
    public var isFinished: Bool { agentsSettled && (synthesis?.state.isTerminal ?? true) && !(wantsSynthesis && synthesis == nil && agents.contains { $0.state == .completed }) }
    public var activeCount: Int { (agents + [synthesis].compactMap { $0 }).filter { !$0.state.isTerminal && $0.state != .waiting }.count }

    /// The synthesis prompt, built only from what the agents actually returned.
    public func synthesisPrompt() -> String {
        var parts = ["Several independent agents worked on parts of one task: \"\(title)\". Combine their results into one clear answer. Point out disagreements, and say plainly which parts are missing because an agent failed or was stopped.", ""]
        for (index, agent) in agents.enumerated() {
            parts.append("### Agent \(index + 1): \(agent.title)")
            parts.append("Task: \(agent.prompt)")
            switch agent.state {
            case .completed: parts.append("Result:\n\(agent.output.isEmpty ? "(no text output)" : agent.output)")
            case .cancelled: parts.append("Result: stopped by the user before finishing." + (agent.output.isEmpty ? "" : " Partial output:\n\(agent.output)"))
            default: parts.append("Result: did not finish (\(agent.error ?? agent.state.rawValue)).")
            }
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }
}

/// Runs parallel tasks against Hermes. Main-actor bound: every state change is
/// applied in order and reported through `onChange`.
@MainActor
public final class ParallelRunEngine {
    public private(set) var tasks: [ParallelTask]
    public var maxConcurrent: Int
    public var onChange: (ParallelTask) -> Void = { _ in }

    private let client: () -> HermesAPIClient?
    private let pause: @Sendable (TimeInterval) async throws -> Void
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var pollInterval: TimeInterval

    public init(tasks: [ParallelTask] = [], maxConcurrent: Int = 3, pollInterval: TimeInterval = 2,
                client: @escaping () -> HermesAPIClient?,
                pause: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.tasks = tasks
        self.maxConcurrent = max(1, min(10, maxConcurrent))
        self.pollInterval = pollInterval
        self.client = client
        self.pause = pause
    }

    // MARK: Public API

    @discardableResult
    public func start(title: String, prompts: [(title: String, prompt: String, instructions: String?, model: String?)],
                      synthesize: Bool = true, originConversationID: UUID? = nil) -> ParallelTask {
        let agents = prompts.map { ParallelAgent(title: $0.title, prompt: $0.prompt, instructions: $0.instructions, model: $0.model) }
        let task = ParallelTask(title: title, agents: agents, wantsSynthesis: synthesize && agents.count > 1,
                                originConversationID: originConversationID)
        tasks.insert(task, at: 0)
        onChange(task)
        schedule()
        return task
    }

    public func task(_ id: UUID) -> ParallelTask? { tasks.first { $0.id == id } }

    /// Stops one agent. Others keep running. Idempotent.
    public func cancel(agent agentID: UUID, in taskID: UUID) {
        guard let agent = agent(agentID, in: taskID), !agent.state.isTerminal, !agent.cancelRequested else { return }
        update(agentID, in: taskID) { $0.cancelRequested = true }
        if agent.state == .waiting {
            update(agentID, in: taskID) { $0.state = .cancelled; $0.finishedAt = Date() }
            settle(taskID)
            return
        }
        guard let runID = agent.runID, let client = client() else { return }   // a starting run is stopped once its id arrives
        update(agentID, in: taskID) { $0.state = .stopping }
        Task { [weak self] in
            do {
                _ = try await client.stopRun(id: runID)
            } catch {
                self?.update(agentID, in: taskID) { a in
                    a.cancelRequested = false
                    if a.state == .stopping { a.state = .running }
                    a.activity.append("Stop failed: \(error.asAgentError.message)")
                }
            }
        }
    }

    public func cancelAll(in taskID: UUID) {
        guard let task = task(taskID) else { return }
        for agent in task.agents where !agent.state.isTerminal { cancel(agent: agent.id, in: taskID) }
        if let synthesis = task.synthesis, !synthesis.state.isTerminal { cancel(agent: synthesis.id, in: taskID) }
    }

    /// Runs a failed / lost / cancelled agent again as a fresh run (new idempotency key).
    public func retry(agent agentID: UUID, in taskID: UUID) {
        guard let agent = agent(agentID, in: taskID), agent.state.isTerminal, agent.state != .completed else { return }
        update(agentID, in: taskID) { a in
            let fresh = ParallelAgent(title: a.title, prompt: a.prompt, instructions: a.instructions, model: a.model)
            a.sessionID = fresh.sessionID
            a.runID = nil
            a.state = .waiting
            a.output = ""
            a.error = nil
            a.subagents = []
            a.cancelRequested = false
            a.activity.append("Retrying")
            a.retryKey = UUID()
        }
        if let index = tasks.firstIndex(where: { $0.id == taskID }) { tasks[index].synthesis = nil }
        schedule()
    }

    /// After a relaunch: follow runs that were in flight by polling their status.
    public func resumeAfterRelaunch() {
        for task in tasks {
            for agent in task.agents + [task.synthesis].compactMap({ $0 }) where !agent.state.isTerminal {
                if agent.runID != nil {
                    launch(agent.id, in: task.id, resume: true)
                } else if agent.state == .starting {
                    update(agent.id, in: task.id) { $0.state = .waiting }   // never got a run id: start again (same key)
                }
            }
        }
        schedule()
    }

    public func remove(_ taskID: UUID) {
        guard let task = task(taskID), task.isFinished else { return }
        tasks.removeAll { $0.id == taskID }
    }

    // MARK: Scheduling

    private var running: Int { workers.count }

    private func schedule() {
        for task in tasks {
            for agent in task.agents where agent.state == .waiting && !agent.cancelRequested {
                guard running < maxConcurrent else { return }
                launch(agent.id, in: task.id, resume: false)
            }
        }
    }

    private func launch(_ agentID: UUID, in taskID: UUID, resume: Bool) {
        guard workers[agentID] == nil else { return }
        if !resume { update(agentID, in: taskID) { $0.state = .starting; $0.attempts += 1; $0.startedAt = $0.startedAt ?? Date() } }
        workers[agentID] = Task { [weak self] in
            await self?.work(agentID, in: taskID, resume: resume)
            guard let self else { return }
            self.workers[agentID] = nil
            self.settle(taskID)
            self.schedule()
        }
    }

    private func work(_ agentID: UUID, in taskID: UUID, resume: Bool) async {
        guard let client = client() else {
            update(agentID, in: taskID) { $0.state = .failed; $0.error = "Not connected to Hermes."; $0.finishedAt = Date() }
            return
        }
        guard var agent = agent(agentID, in: taskID) else { return }
        if !resume {
            do {
                agent = try await create(agent, taskID: taskID, client: client)
            } catch {
                update(agentID, in: taskID) { a in
                    a.state = a.cancelRequested ? .cancelled : .failed
                    a.error = a.cancelRequested ? nil : error.asAgentError.message
                    a.finishedAt = Date()
                }
                return
            }
            if agent.cancelRequested, let runID = agent.runID {
                update(agentID, in: taskID) { $0.state = .stopping }
                _ = try? await client.stopRun(id: runID)
            }
        }
        guard let runID = self.agent(agentID, in: taskID)?.runID else { return }
        await follow(runID: runID, agentID: agentID, taskID: taskID, client: client)
    }

    /// Creates the session + run, waiting out 429s (Hermes' concurrency cap).
    private func create(_ agent: ParallelAgent, taskID: UUID, client: HermesAPIClient) async throws -> ParallelAgent {
        do {
            _ = try await client.createSession(id: agent.sessionID, title: String(agent.title.prefix(80)))
        } catch AgentError.remote(let code, _) where code == "session_exists" || code == "invalid_title" {
        }
        var delay: TimeInterval = 1
        for attempt in 1...8 {
            if self.agent(agent.id, in: taskID)?.cancelRequested == true { throw AgentError.cancelled }
            do {
                let options = HermesAPIClient.RunOptions(sessionID: agent.sessionID, instructions: HermesClientNote.compose(agent.instructions), model: agent.model,
                                                         idempotencyKey: agent.idempotencyKey)
                let accepted = try await client.createRun(input: agent.prompt, options: options)
                update(agent.id, in: taskID) { a in
                    a.runID = accepted.runID
                    if a.state == .starting { a.state = .running }
                    if accepted.replayed { a.activity.append("Hermes already had this run (no duplicate started)") }
                }
                return self.agent(agent.id, in: taskID) ?? agent
            } catch AgentError.remote(let code, _) where code == "rate_limited" || code == "rate_limit_exceeded" {
                update(agent.id, in: taskID) { $0.activity.append("Hermes is at its concurrent-run limit — waiting (\(attempt))") }
                try await pause(delay)
                delay = min(delay * 2, 30)
            }
        }
        throw AgentError.remote(code: "rate_limited", message: "Hermes stayed at its concurrent-run limit. Try again when other runs finish.")
    }

    private func follow(runID: String, agentID: UUID, taskID: UUID, client: HermesAPIClient) async {
        var mapper = HermesRunMapper(runID: runID)
        do {
            for try await event in client.runEvents(id: runID) {
                handle(event, agentID: agentID, taskID: taskID)
                _ = mapper.map(event)
                if mapper.finished { return }
            }
        } catch {
            update(agentID, in: taskID) { $0.activity.append("Live stream dropped — following by status") }
        }
        // Stream ended without a terminal event: poll the run's status.
        var failures = 0
        while true {
            do {
                let status = try await client.runStatus(id: runID)
                failures = 0
                apply(status, agentID: agentID, taskID: taskID)
                if status.status.isTerminal { return }
            } catch AgentError.remote(let code, _) where code == "run_not_found" || code == "not_found" {
                update(agentID, in: taskID) { a in
                    a.state = .lost
                    a.error = "Hermes no longer knows this run (it may have restarted). Its output, if any, is in session \(a.sessionID)."
                    a.finishedAt = Date()
                }
                return
            } catch {
                failures += 1
                if failures >= 30 {
                    update(agentID, in: taskID) { a in
                        a.state = .lost
                        a.error = "Lost contact with this run; it may still be running on the server."
                        a.finishedAt = Date()
                    }
                    return
                }
            }
            do { try await pause(pollInterval) } catch { return }
        }
    }

    private func handle(_ event: HermesRunEvent, agentID: UUID, taskID: UUID) {
        update(agentID, in: taskID) { a in
            switch event {
            case .messageDelta(let delta):
                a.output += delta
                if a.state == .starting || a.state == .waitingForApproval { a.state = .running }
            case .toolStarted(let tool, _):
                a.activity.append("Using \(tool)")
            case .toolCompleted(let tool, _, let isError):
                if isError { a.activity.append("\(tool) reported an error") }
            case .approvalRequest(let request):
                a.state = .waitingForApproval
                a.activity.append("Waiting for approval: \(request.command)")
            case .approvalResponded(let choice):
                a.state = .running
                a.activity.append("Approval: \(choice)")
            case .subagentStarted(let goal, let id):
                a.subagents.append(.init(id: id ?? UUID().uuidString, goal: goal, status: "running", summary: nil, finished: false))
            case .subagentCompleted(let status, let summary, let id):
                if let index = a.subagents.lastIndex(where: { ($0.id == id || id == nil) && !$0.finished }) {
                    a.subagents[index].status = status
                    a.subagents[index].summary = summary
                    a.subagents[index].finished = true
                }
            case .stopping:
                a.state = .stopping
            case .completed(let output, _, _):
                // Hermes' final output is authoritative over the streamed deltas.
                if let output, !output.isEmpty { a.output = output }
                a.state = .completed
                a.finishedAt = Date()
            case .failed(let error):
                a.state = .failed
                a.error = error ?? "The run failed."
                a.finishedAt = Date()
            case .cancelled:
                a.state = .cancelled
                a.finishedAt = Date()
            case .interrupted(let error):
                a.state = .lost
                a.error = error ?? "Hermes restarted before this run finished."
                a.finishedAt = Date()
            case .reasoning, .steered, .unknown:
                break
            }
            if a.activity.count > 50 { a.activity.removeFirst(a.activity.count - 50) }
        }
    }

    private func apply(_ status: HermesRunStatus, agentID: UUID, taskID: UUID) {
        switch status.status {
        case .completed: handle(.completed(output: status.output, usage: status.usage, pendingSteer: nil), agentID: agentID, taskID: taskID)
        case .failed: handle(.failed(error: status.error), agentID: agentID, taskID: taskID)
        case .cancelled: handle(.cancelled, agentID: agentID, taskID: taskID)
        case .interrupted: handle(.interrupted(error: status.error), agentID: agentID, taskID: taskID)
        case .stopping: handle(.stopping, agentID: agentID, taskID: taskID)
        case .waitingForApproval: update(agentID, in: taskID) { $0.state = .waitingForApproval }
        case .running, .queued: update(agentID, in: taskID) { if $0.state == .starting { $0.state = .running } }
        case .unknown: break
        }
    }

    /// When every agent has settled, start the synthesis run (once).
    private func settle(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let task = tasks[index]
        guard task.wantsSynthesis, task.agentsSettled, task.synthesis == nil,
              task.agents.contains(where: { $0.state == .completed }) else { return }
        var synthesis = ParallelAgent(title: "Combined result", prompt: task.synthesisPrompt())
        synthesis.activity.append("Combining \(task.agents.filter { $0.state == .completed }.count) result(s)")
        tasks[index].synthesis = synthesis
        onChange(tasks[index])
        launch(synthesis.id, in: taskID, resume: false)
    }

    // MARK: Mutation

    private func agent(_ id: UUID, in taskID: UUID) -> ParallelAgent? {
        guard let task = task(taskID) else { return nil }
        if task.synthesis?.id == id { return task.synthesis }
        return task.agents.first { $0.id == id }
    }

    private func update(_ id: UUID, in taskID: UUID, _ body: (inout ParallelAgent) -> Void) {
        guard let t = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if tasks[t].synthesis?.id == id {
            body(&tasks[t].synthesis!)
        } else if let a = tasks[t].agents.firstIndex(where: { $0.id == id }) {
            body(&tasks[t].agents[a])
        } else {
            return
        }
        onChange(tasks[t])
    }
}

extension ParallelAgent {
    /// Hermes idempotency key: one per attempt, so a resent request replays
    /// the same run instead of starting a duplicate.
    public var idempotencyKey: String { "bb-par-" + (retryKey ?? id).uuidString.lowercased() }
}
