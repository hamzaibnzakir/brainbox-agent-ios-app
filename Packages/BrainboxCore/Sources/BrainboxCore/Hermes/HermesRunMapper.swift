import Foundation

/// Translates Hermes run events into the provider-neutral `AgentEvent`s
/// the chat UI already understands. Pure and stateful per run, so it is
/// unit tested without any networking.
///
/// Hermes' `tool.started` / `tool.completed` events carry a tool name but no
/// call id, so calls are matched first-in-first-out per tool name.
public struct HermesRunMapper: Sendable {
    public let runID: String
    public private(set) var streamedText = ""
    public private(set) var finished = false
    public private(set) var pendingApproval: AgentApproval?
    private var runningTools: [String: [String]] = [:] // tool name → call ids (FIFO)
    private var toolCounter = 0
    private var sentStreaming = false
    private var now: @Sendable () -> Date

    public init(runID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runID = runID
        self.now = now
    }

    public mutating func map(_ event: HermesRunEvent) -> [AgentEvent] {
        guard !finished else { return [] }
        switch event {
        case .messageDelta(let delta):
            guard !delta.isEmpty else { return [] }
            streamedText += delta
            var out: [AgentEvent] = []
            if !sentStreaming {
                sentStreaming = true
                out.append(.status(.streaming))
            }
            out.append(.textDelta(delta))
            return out

        case .toolStarted(let tool, let preview):
            toolCounter += 1
            let id = "\(runID)-tool-\(toolCounter)"
            runningTools[tool, default: []].append(id)
            sentStreaming = false
            let kind = Self.kind(forTool: tool)
            let call = ToolCall(id: id, kind: kind, name: tool, title: Self.title(forTool: tool, kind: kind),
                                input: preview ?? "", status: .running, startedAt: now())
            return [.status(.runningTool(name: tool)), .toolStarted(call)]

        case .toolCompleted(let tool, let duration, let isError):
            guard var queue = runningTools[tool], !queue.isEmpty else { return [] }
            let id = queue.removeFirst()
            runningTools[tool] = queue
            var detail = isError ? "The tool reported an error." : "Done"
            if let duration { detail += String(format: " · %.1fs", duration) }
            let result = ToolResult(output: detail, exitCode: nil, isError: isError)
            let stillRunning = runningTools.values.contains { !$0.isEmpty }
            var out: [AgentEvent] = [.toolFinished(toolCallID: id, result: result, status: isError ? .failed : .succeeded)]
            if !stillRunning { out.append(.status(.thinking)) }
            return out

        case .reasoning(let text):
            return text.isEmpty ? [] : [.reasoning(text)]

        case .approvalRequest(let request):
            let approval = AgentApproval(runID: runID, command: request.command, description: request.description,
                                         choices: request.choices, requestID: request.requestID, requestedAt: now())
            pendingApproval = approval
            return [.approvalRequested(approval)]

        case .approvalResponded(let choice):
            pendingApproval = nil
            return [.approvalResolved(choice: choice), .status(.thinking)]

        case .steered:
            return [.notice("Steering accepted")]

        case .subagentStarted(let goal):
            return [.notice(goal.map { "Delegated: \($0)" } ?? "Delegated a subtask")]

        case .subagentCompleted(let status, _):
            return [.notice("Subtask \(status ?? "finished")")]

        case .stopping:
            return [.stopAcknowledged]

        case .completed(let output, _, let pendingSteer):
            finished = true
            var out: [AgentEvent] = []
            if let remainder = Self.remainder(of: output, after: streamedText) {
                streamedText += remainder
                out.append(.textDelta(remainder))
            }
            if let pendingSteer, !pendingSteer.isEmpty {
                out.append(.notice("Your steering note arrived after the reply finished: \(pendingSteer)"))
            }
            out.append(.completed)
            return out

        case .failed(let error):
            finished = true
            return [.failed(.remote(code: "run_failed", message: error ?? "The agent run failed."))]

        case .cancelled:
            finished = true
            return [.failed(.cancelled)]

        case .interrupted(let error):
            finished = true
            return [.failed(.remote(code: "run_interrupted", message: error ?? "Hermes restarted before this run finished."))]

        case .unknown:
            return []
        }
    }

    /// Reconciles a polled run status (used after a dropped stream or a
    /// relaunch). Emits only what the user hasn't seen yet.
    public mutating func reconcile(_ status: HermesRunStatus) -> [AgentEvent] {
        guard !finished else { return [] }
        switch status.status {
        case .completed:
            return map(.completed(output: status.output, usage: status.usage, pendingSteer: status.pendingSteer))
        case .failed:
            return map(.failed(error: status.error))
        case .cancelled:
            return map(.cancelled)
        case .interrupted:
            return map(.interrupted(error: status.error))
        case .waitingForApproval:
            if let approval = status.approval, pendingApproval?.command != approval.command {
                return map(.approvalRequest(approval))
            }
            return []
        case .stopping:
            return [.stopAcknowledged]
        case .running, .queued, .unknown:
            if pendingApproval != nil {
                pendingApproval = nil
                return [.approvalResolved(choice: "resolved elsewhere"), .status(.thinking)]
            }
            return []
        }
    }

    /// Text the final output has beyond what was already streamed.
    static func remainder(of output: String?, after streamed: String) -> String? {
        guard let output, !output.isEmpty else { return nil }
        if streamed.isEmpty { return output }
        if output.hasPrefix(streamed) {
            let rest = String(output.dropFirst(streamed.count))
            return rest.isEmpty ? nil : rest
        }
        return nil // streamed text is authoritative when they diverge
    }

    public static func kind(forTool name: String) -> ToolKind {
        let n = name.lowercased()
        if n == "terminal" || n.contains("shell") || n.contains("process") || n == "bash" { return .terminal }
        if n.hasPrefix("browser") { return .browser }
        if n.contains("search") { return .search }
        if n.contains("file") || n.contains("patch") || n.contains("read") || n.contains("write") { return .file }
        if n.contains("code") || n.contains("python") { return .code }
        if n.contains("git") { return .git }
        if n.contains("web") || n.contains("http") || n.contains("fetch") { return .network }
        if n.contains("cron") || n.contains("schedule") || n.contains("delegate") || n.contains("memory") || n.contains("skill") { return .system }
        return .other
    }

    public static func title(forTool name: String, kind: ToolKind) -> String {
        switch kind {
        case .terminal: return "Running a command"
        case .browser: return "Using the browser on the VPS"
        case .search: return "Searching"
        case .file: return "Working with files"
        case .code: return "Running code"
        case .git: return "Using git"
        case .network: return "Fetching from the web"
        case .system: return "Using \(name.replacingOccurrences(of: "_", with: " "))"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Compatibility

/// What the connected Hermes server can do, derived from `/v1/capabilities`.
public struct HermesCompatibilityReport: Hashable, Sendable {
    public enum Feature: String, CaseIterable, Hashable, Sendable {
        case runs, runEvents, runStatus, stop, steer, approvals, sessions, sessionMessages, sessionFork, sessionChat, skills, toolsets, models

        public var title: String {
            switch self {
            case .runs: return "Agent runs"
            case .runEvents: return "Live run events"
            case .runStatus: return "Run status / recovery"
            case .stop: return "Stop a run"
            case .steer: return "Steer a running agent"
            case .approvals: return "Approvals"
            case .sessions: return "Session history"
            case .sessionMessages: return "Transcripts"
            case .sessionFork: return "Fork app sessions"
            case .sessionChat: return "Session chat"
            case .skills: return "Skills list"
            case .toolsets: return "Toolsets list"
            case .models: return "Models"
            }
        }
    }

    public var isCompatible: Bool
    public var supported: Set<Feature>
    public var problems: [String]
    public var model: String?

    public func supports(_ feature: Feature) -> Bool { supported.contains(feature) }

    public static let required: Set<Feature> = [.runs, .runEvents, .runStatus, .sessions]

    public static func evaluate(_ caps: HermesCapabilities) -> HermesCompatibilityReport {
        var problems: [String] = []
        if let object = caps.object, object != "hermes.api_server.capabilities" {
            problems.append("The server identified itself as “\(object)”, not a Hermes API Server.")
        }
        func either(_ flag: String, _ endpoint: String) -> Bool { caps.supports(flag) || caps.hasEndpoint(endpoint) }
        var supported = Set<Feature>()
        if either("run_submission", "runs") { supported.insert(.runs) }
        if either("run_events_sse", "run_events") { supported.insert(.runEvents) }
        if either("run_status", "run_status") { supported.insert(.runStatus) }
        if either("run_stop", "run_stop") { supported.insert(.stop) }
        if either("run_steer", "run_steer") { supported.insert(.steer) }
        if caps.supports("run_approval_response") || caps.supports("approval_events") || caps.hasEndpoint("run_approval") { supported.insert(.approvals) }
        if caps.supports("session_resources") || caps.hasEndpoint("sessions") { supported.insert(.sessions) }
        if caps.hasEndpoint("session_messages") || caps.supports("session_resources") { supported.insert(.sessionMessages) }
        if either("session_fork", "session_fork") { supported.insert(.sessionFork) }
        if either("session_chat", "session_chat") { supported.insert(.sessionChat) }
        if either("skills_api", "skills") { supported.insert(.skills) }
        if caps.hasEndpoint("toolsets") { supported.insert(.toolsets) }
        if caps.hasEndpoint("models") || caps.model != nil { supported.insert(.models) }

        let missing = required.subtracting(supported)
        for feature in Feature.allCases where missing.contains(feature) {
            problems.append("Missing required feature: \(feature.title).")
        }
        if caps.authRequired == false {
            problems.append("Warning: this server does not require authentication.")
        }
        let compatible = missing.isEmpty && (caps.object == nil || caps.object == "hermes.api_server.capabilities")
        return HermesCompatibilityReport(isCompatible: compatible, supported: supported, problems: problems, model: caps.model)
    }
}
