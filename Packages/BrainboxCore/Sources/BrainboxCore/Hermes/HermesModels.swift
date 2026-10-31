import Foundation

// Models for the Hermes Agent API Server, verified against
// NousResearch/hermes-agent v0.21.2 (commit 284d220):
//   gateway/platforms/api_server.py       (capabilities, sessions, jobs)
//   gateway/platforms/api_server_runs.py  (runs, events, approval, steer, stop)
// Decoding is deliberately lenient: unknown fields are ignored and most
// fields are optional, so additive server changes never break the app.

// MARK: - Capabilities

public struct HermesCapabilities: Decodable, Hashable, Sendable {
    public struct Endpoint: Decodable, Hashable, Sendable {
        public var method: String
        public var path: String
    }

    public var object: String?
    public var platform: String?
    public var model: String?
    public var authType: String?
    public var authRequired: Bool?
    /// Raw feature flags. Values are usually booleans, sometimes objects.
    public var features: [String: JSONValue]
    public var endpoints: [String: Endpoint]

    enum CodingKeys: String, CodingKey { case object, platform, model, auth, features, endpoints }
    enum AuthKeys: String, CodingKey { case type, required }

    public init(object: String? = "hermes.api_server.capabilities", platform: String? = "hermes-agent", model: String? = nil,
                authType: String? = "bearer", authRequired: Bool? = true,
                features: [String: JSONValue] = [:], endpoints: [String: Endpoint] = [:]) {
        self.object = object
        self.platform = platform
        self.model = model
        self.authType = authType
        self.authRequired = authRequired
        self.features = features
        self.endpoints = endpoints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        object = try c.decodeIfPresent(String.self, forKey: .object)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        if let auth = try? c.nestedContainer(keyedBy: AuthKeys.self, forKey: .auth) {
            authType = try auth.decodeIfPresent(String.self, forKey: .type)
            authRequired = try auth.decodeIfPresent(Bool.self, forKey: .required)
        }
        features = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .features)) ?? [:]
        endpoints = (try? c.decodeIfPresent([String: Endpoint].self, forKey: .endpoints)) ?? [:]
    }

    /// True when the feature flag is literally `true`, or an object whose
    /// `enabled`/`supported` field is true.
    public func supports(_ feature: String) -> Bool {
        switch features[feature] {
        case .bool(let value): return value
        case .object(let object):
            return object["enabled"]?.boolValue ?? object["supported"]?.boolValue ?? false
        default: return false
        }
    }

    public func hasEndpoint(_ name: String) -> Bool { endpoints[name] != nil }
}

// MARK: - Sessions

/// Where a Hermes session came from. Derived from the session's `source`
/// column (and, for sessions this app created, its `ios_` id prefix).
public enum HermesSessionSource: String, Codable, Hashable, Sendable, CaseIterable {
    case ios
    case telegram
    case api
    case cli
    case discord
    case slack
    case desktop
    case dashboard
    case browser
    case other

    public static let appSessionPrefix = "ios_"

    public static func classify(source: String?, sessionID: String) -> HermesSessionSource {
        let normalized = (source ?? "").lowercased()
        switch normalized {
        case "telegram": return .telegram
        case "cli": return .cli
        case "discord": return .discord
        case "slack": return .slack
        case "desktop": return .desktop
        case "dashboard": return .dashboard
        case "browser", "hermes_browser": return .browser
        case "api_server", "":
            return sessionID.hasPrefix(appSessionPrefix) ? .ios : .api
        default:
            return .other
        }
    }

    public var displayName: String {
        switch self {
        case .ios: return "iOS"
        case .telegram: return "Telegram"
        case .api: return "API"
        case .cli: return "CLI"
        case .discord: return "Discord"
        case .slack: return "Slack"
        case .desktop: return "Desktop"
        case .dashboard: return "Dashboard"
        case .browser: return "Browser"
        case .other: return "Other"
        }
    }

    /// Sessions owned by an external chat platform. The app shows them
    /// read-only; continuing one makes a local copy that carries the
    /// transcript with each run (`CarriedHistory`). They are never forked.
    public var isExternalPlatform: Bool {
        switch self {
        case .telegram, .discord, .slack: return true
        default: return false
        }
    }
}

public struct HermesSession: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var source: String?
    public var model: String?
    public var title: String?
    public var startedAt: Double?
    public var endedAt: Double?
    public var endReason: String?
    public var messageCount: Int?
    public var toolCallCount: Int?
    public var lastActive: Double?
    public var preview: String?
    public var parentSessionID: String?
    public var pinned: Bool?
    public var archived: Bool?
    /// Hermes lists a compressed conversation under its newest continuation
    /// ("tip") id and reports the original id here (`_lineage_root_id`).
    public var lineageRootID: String?
    // Token accounting Hermes keeps per session (what Telegram's /status and /usage show).
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var reasoningTokens: Int?
    public var apiCallCount: Int?
    public var estimatedCostUSD: Double?
    public var actualCostUSD: Double?

    enum CodingKeys: String, CodingKey {
        case id, source, model, title, preview, pinned, archived
        case lineageRootID = "_lineage_root_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case reasoningTokens = "reasoning_tokens"
        case apiCallCount = "api_call_count"
        case estimatedCostUSD = "estimated_cost_usd"
        case actualCostUSD = "actual_cost_usd"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
        case messageCount = "message_count"
        case toolCallCount = "tool_call_count"
        case lastActive = "last_active"
        case parentSessionID = "parent_session_id"
    }

    public init(id: String, source: String? = nil, model: String? = nil, title: String? = nil, startedAt: Double? = nil,
                endedAt: Double? = nil, endReason: String? = nil, messageCount: Int? = nil, toolCallCount: Int? = nil,
                lastActive: Double? = nil, preview: String? = nil, parentSessionID: String? = nil,
                pinned: Bool? = nil, archived: Bool? = nil, lineageRootID: String? = nil) {
        self.id = id
        self.source = source
        self.model = model
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.lastActive = lastActive
        self.preview = preview
        self.parentSessionID = parentSessionID
        self.pinned = pinned
        self.archived = archived
        self.lineageRootID = lineageRootID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        startedAt = HermesDecoding.number(c, .startedAt)
        endedAt = HermesDecoding.number(c, .endedAt)
        endReason = try? c.decodeIfPresent(String.self, forKey: .endReason)
        messageCount = HermesDecoding.number(c, .messageCount).map { Int($0) }
        toolCallCount = HermesDecoding.number(c, .toolCallCount).map { Int($0) }
        lastActive = HermesDecoding.number(c, .lastActive)
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        parentSessionID = try? c.decodeIfPresent(String.self, forKey: .parentSessionID)
        pinned = try? c.decodeIfPresent(Bool.self, forKey: .pinned)
        archived = try? c.decodeIfPresent(Bool.self, forKey: .archived)
        lineageRootID = try? c.decodeIfPresent(String.self, forKey: .lineageRootID)
        inputTokens = HermesDecoding.number(c, .inputTokens).map { Int($0) }
        outputTokens = HermesDecoding.number(c, .outputTokens).map { Int($0) }
        cacheReadTokens = HermesDecoding.number(c, .cacheReadTokens).map { Int($0) }
        reasoningTokens = HermesDecoding.number(c, .reasoningTokens).map { Int($0) }
        apiCallCount = HermesDecoding.number(c, .apiCallCount).map { Int($0) }
        estimatedCostUSD = HermesDecoding.number(c, .estimatedCostUSD)
        actualCostUSD = HermesDecoding.number(c, .actualCostUSD)
    }

    /// The id the conversation started with: the lineage root for a compressed
    /// conversation, otherwise the session's own id. App conversations are
    /// identified (and deleted) by this id.
    public var conversationRootID: String {
        if let root = lineageRootID, !root.isEmpty { return root }
        return id
    }

    public var sourceKind: HermesSessionSource { .classify(source: source, sessionID: conversationRootID) }

    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let preview, !preview.isEmpty { return String(preview.prefix(48)) }
        return "Untitled session"
    }

    public var lastActivity: Date? {
        (lastActive ?? endedAt ?? startedAt).map { Date(timeIntervalSince1970: $0) }
    }
}

public struct HermesSessionPage: Decodable, Hashable, Sendable {
    public var sessions: [HermesSession]
    public var limit: Int
    public var offset: Int
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey { case data, limit, offset, hasMore = "has_more" }

    public init(sessions: [HermesSession], limit: Int, offset: Int, hasMore: Bool) {
        self.sessions = sessions
        self.limit = limit
        self.offset = offset
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? c.decode([HermesSession].self, forKey: .data)) ?? []
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? sessions.count
        offset = (try? c.decode(Int.self, forKey: .offset)) ?? 0
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
    }
}

struct HermesSessionEnvelope: Decodable {
    var session: HermesSession
}

public struct HermesMessage: Decodable, Hashable, Sendable, Identifiable {
    public var rawID: String?
    public var sessionID: String?
    public var role: String
    public var content: String
    public var toolName: String?
    public var toolCallID: String?
    public var timestamp: Double?
    public var reasoning: String?
    public var finishReason: String?

    /// Stable identity even when the server omits ids.
    public var id: String { rawID ?? "\(role)-\(timestamp ?? 0)-\(content.hashValue)" }

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, reasoning
        case sessionID = "session_id"
        case toolName = "tool_name"
        case toolCallID = "tool_call_id"
        case finishReason = "finish_reason"
    }

    public init(rawID: String? = nil, sessionID: String? = nil, role: String, content: String, toolName: String? = nil,
                toolCallID: String? = nil, timestamp: Double? = nil, reasoning: String? = nil, finishReason: String? = nil) {
        self.rawID = rawID
        self.sessionID = sessionID
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.finishReason = finishReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { rawID = s }
        else if let n = try? c.decode(Double.self, forKey: .id) { rawID = String(Int(n)) }
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        content = HermesDecoding.text(c, .content)
        toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
        toolCallID = try? c.decodeIfPresent(String.self, forKey: .toolCallID)
        timestamp = HermesDecoding.number(c, .timestamp)
        reasoning = try? c.decodeIfPresent(String.self, forKey: .reasoning)
        finishReason = try? c.decodeIfPresent(String.self, forKey: .finishReason)
    }

    public var date: Date? { timestamp.map { Date(timeIntervalSince1970: $0) } }
    public var isTool: Bool { role == "tool" }
}

public struct HermesMessagePage: Decodable, Hashable, Sendable {
    public var sessionID: String?
    public var messages: [HermesMessage]
    public var returned: Int

    enum CodingKeys: String, CodingKey { case sessionID = "session_id", data, pagination }
    enum PaginationKeys: String, CodingKey { case returned }

    public init(sessionID: String?, messages: [HermesMessage], returned: Int) {
        self.sessionID = sessionID
        self.messages = messages
        self.returned = returned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        messages = (try? c.decode([HermesMessage].self, forKey: .data)) ?? []
        if let p = try? c.nestedContainer(keyedBy: PaginationKeys.self, forKey: .pagination) {
            returned = (try? p.decode(Int.self, forKey: .returned)) ?? messages.count
        } else {
            returned = messages.count
        }
    }
}

// MARK: - Runs

public enum HermesRunState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case waitingForApproval = "waiting_for_approval"
    case stopping
    case completed
    case failed
    case cancelled
    case interrupted
    case unknown

    public init(raw: String?) {
        self = HermesRunState(rawValue: raw ?? "") ?? .unknown
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .waitingForApproval: return "Needs approval"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        case .unknown: return "Unknown"
        }
    }
}

public struct HermesRunAccepted: Decodable, Hashable, Sendable {
    public var runID: String
    public var status: String
    public var replayed: Bool

    enum CodingKeys: String, CodingKey { case runID = "run_id", status, replayed }

    public init(runID: String, status: String, replayed: Bool = false) {
        self.runID = runID
        self.status = status
        self.replayed = replayed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(String.self, forKey: .runID)
        status = (try? c.decode(String.self, forKey: .status)) ?? "started"
        replayed = (try? c.decode(Bool.self, forKey: .replayed)) ?? false
    }
}

public struct HermesUsage: Decodable, Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", outputTokens = "output_tokens", totalTokens = "total_tokens"
    }

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = HermesDecoding.number(c, .inputTokens).map { Int($0) }
        outputTokens = HermesDecoding.number(c, .outputTokens).map { Int($0) }
        totalTokens = HermesDecoding.number(c, .totalTokens).map { Int($0) }
    }
}

/// `GET /v1/runs/{run_id}` — pollable run status.
public struct HermesRunStatus: Decodable, Hashable, Sendable {
    public var runID: String
    public var status: HermesRunState
    public var sessionID: String?
    public var model: String?
    public var output: String?
    public var error: String?
    public var lastEvent: String?
    public var createdAt: Double?
    public var updatedAt: Double?
    public var usage: HermesUsage?
    public var approval: HermesApprovalRequest?
    public var pendingSteer: String?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id", status, model, output, error, usage, approval
        case sessionID = "session_id"
        case lastEvent = "last_event"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pendingSteer = "pending_steer"
    }

    public init(runID: String, status: HermesRunState, sessionID: String? = nil, model: String? = nil, output: String? = nil,
                error: String? = nil, lastEvent: String? = nil, createdAt: Double? = nil, updatedAt: Double? = nil,
                usage: HermesUsage? = nil, approval: HermesApprovalRequest? = nil, pendingSteer: String? = nil) {
        self.runID = runID
        self.status = status
        self.sessionID = sessionID
        self.model = model
        self.output = output
        self.error = error
        self.lastEvent = lastEvent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usage = usage
        self.approval = approval
        self.pendingSteer = pendingSteer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(String.self, forKey: .runID)
        status = HermesRunState(raw: try? c.decode(String.self, forKey: .status))
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        output = try? c.decodeIfPresent(String.self, forKey: .output)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        lastEvent = try? c.decodeIfPresent(String.self, forKey: .lastEvent)
        createdAt = HermesDecoding.number(c, .createdAt)
        updatedAt = HermesDecoding.number(c, .updatedAt)
        usage = try? c.decodeIfPresent(HermesUsage.self, forKey: .usage)
        approval = try? c.decodeIfPresent(HermesApprovalRequest.self, forKey: .approval)
        pendingSteer = try? c.decodeIfPresent(String.self, forKey: .pendingSteer)
    }
}

/// The payload Hermes attaches to an `approval.request` event (and to the
/// run status while it waits). Commands arrive already redacted server-side.
public struct HermesApprovalRequest: Codable, Hashable, Sendable {
    public var command: String
    public var description: String?
    public var patternKey: String?
    public var choices: [String]
    public var requestID: String?
    public var smartDenied: Bool

    enum CodingKeys: String, CodingKey {
        case command, description, choices
        case patternKey = "pattern_key"
        case requestID = "request_id"
        case smartDenied = "smart_denied"
        case allowSession = "allow_session"
        case allowPermanent = "allow_permanent"
    }

    public init(command: String, description: String? = nil, patternKey: String? = nil, choices: [String] = ["once", "deny"],
                requestID: String? = nil, smartDenied: Bool = false) {
        self.command = command
        self.description = description
        self.patternKey = patternKey
        self.choices = choices
        self.requestID = requestID
        self.smartDenied = smartDenied
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = (try? c.decode(String.self, forKey: .command)) ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        patternKey = try? c.decodeIfPresent(String.self, forKey: .patternKey)
        requestID = try? c.decodeIfPresent(String.self, forKey: .requestID)
        smartDenied = (try? c.decodeIfPresent(Bool.self, forKey: .smartDenied)) ?? false
        if let explicit = try? c.decode([String].self, forKey: .choices), !explicit.isEmpty {
            choices = explicit
        } else {
            // Same rule as the server's _approval_event_choices.
            let allowSession = (try? c.decodeIfPresent(Bool.self, forKey: .allowSession)) ?? true
            let allowPermanent = (try? c.decodeIfPresent(Bool.self, forKey: .allowPermanent)) ?? true
            if smartDenied || allowSession == false {
                choices = ["once", "deny"]
            } else {
                choices = allowPermanent ? ["once", "session", "always", "deny"] : ["once", "session", "deny"]
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(patternKey, forKey: .patternKey)
        try c.encode(choices, forKey: .choices)
        try c.encodeIfPresent(requestID, forKey: .requestID)
        try c.encode(smartDenied, forKey: .smartDenied)
    }
}

/// Decisions accepted by `POST /v1/runs/{id}/approval`.
public enum HermesApprovalChoice: String, Codable, Hashable, Sendable, CaseIterable {
    case once
    case session
    case always
    case deny

    public var title: String {
        switch self {
        case .once: return "Allow once"
        case .session: return "Allow for this session"
        case .always: return "Always allow"
        case .deny: return "Deny"
        }
    }

    /// Choices that widen permissions beyond this single action.
    public var widensPermissions: Bool { self == .session || self == .always }
}

/// One structured event from `GET /v1/runs/{run_id}/events`.
public enum HermesRunEvent: Hashable, Sendable {
    case messageDelta(String)
    /// Mid-turn assistant commentary (newer Hermes `message.interim`). `alreadyStreamed`
    /// means the same text already arrived as deltas.
    case interim(text: String, alreadyStreamed: Bool)
    /// Hermes accepted the run but holds it (newer Hermes `run.queued`, e.g. while draining).
    case queued(message: String?)
    case toolStarted(tool: String, preview: String?)
    case toolCompleted(tool: String, duration: Double?, isError: Bool)
    case reasoning(String)
    case approvalRequest(HermesApprovalRequest)
    case approvalResponded(choice: String)
    case steered
    /// Hermes `delegate_task` child agents (they run inside this run; stopping
    /// the run stops them — they can't be stopped one by one over the API).
    case subagentStarted(goal: String?, id: String?)
    case subagentCompleted(status: String?, summary: String?, id: String?)
    case completed(output: String?, usage: HermesUsage?, pendingSteer: String?)
    case failed(error: String?)
    case cancelled
    case stopping
    case interrupted(error: String?)
    case unknown(name: String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        default: return false
        }
    }

    /// Parses one SSE `data:` JSON payload. Returns nil for malformed data.
    public static func parse(data: String) -> HermesRunEvent? {
        guard let bytes = data.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: bytes),
              let name = json["event"]?.stringValue else { return nil }
        func string(_ key: String) -> String? { json[key]?.stringValue }
        switch name {
        case "message.delta":
            return .messageDelta(string("delta") ?? "")
        case "message.interim":
            return .interim(text: string("text") ?? "", alreadyStreamed: json["already_streamed"]?.boolValue ?? false)
        case "run.queued":
            return .queued(message: string("message"))
        case "tool.started":
            return .toolStarted(tool: string("tool") ?? "tool", preview: string("preview"))
        case "tool.completed":
            return .toolCompleted(tool: string("tool") ?? "tool", duration: json["duration"]?.doubleValue,
                                  isError: json["error"]?.boolValue ?? false)
        case "reasoning.available":
            return .reasoning(string("text") ?? "")
        case "approval.request":
            let approval = (try? JSONDecoder().decode(HermesApprovalRequest.self, from: bytes))
                ?? HermesApprovalRequest(command: string("command") ?? "")
            return .approvalRequest(approval)
        case "approval.responded":
            return .approvalResponded(choice: string("choice") ?? "")
        case "run.steered":
            return .steered
        case "subagent.start":
            return .subagentStarted(goal: string("goal"), id: string("subagent_id") ?? string("delegation_id"))
        case "subagent.complete":
            return .subagentCompleted(status: string("status"), summary: string("summary"),
                                      id: string("subagent_id") ?? string("delegation_id"))
        case "run.completed":
            let usage = json["usage"].flatMap { value -> HermesUsage? in
                guard let data = try? JSONEncoder().encode(value) else { return nil }
                return try? JSONDecoder().decode(HermesUsage.self, from: data)
            }
            return .completed(output: string("output"), usage: usage, pendingSteer: string("pending_steer"))
        case "run.failed":
            return .failed(error: string("error"))
        case "run.cancelled":
            return .cancelled
        case "run.stopping":
            return .stopping
        case "run.interrupted":
            return .interrupted(error: string("error"))
        default:
            return .unknown(name: name)
        }
    }
}

// MARK: - Jobs, skills, toolsets, models

/// A Hermes cron job. The server returns the scheduler's own dictionary, so
/// only well-known fields are typed; everything is kept in `raw`.
public struct HermesJob: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var prompt: String
    public var schedule: String
    public var deliver: String?
    public var enabled: Bool
    public var paused: Bool
    public var nextRun: String?
    public var lastRun: String?
    public var lastStatus: String?
    /// Hermes' operator-facing state: scheduled, paused, completed (retired one-shot) or error.
    public var state: String?
    public var lastError: String?
    public var lastDeliveryError: String?
    /// Consecutive failed runs (delivery failures don't count).
    public var failureStreak: Int
    /// Set by "run now" until that run finishes (`trigger_job` → `mark_job_run`).
    public var manualRunAt: String?
    /// Newest attempt from Hermes' execution ledger (`cron/executions.db`).
    /// Only `GET /api/jobs` (the list) includes it, not `GET /api/jobs/{id}`.
    public var latestExecution: HermesJobExecution?
    public var raw: [String: JSONValue]

    public init(id: String, name: String, prompt: String = "", schedule: String = "", deliver: String? = nil,
                enabled: Bool = true, paused: Bool = false, nextRun: String? = nil, lastRun: String? = nil,
                lastStatus: String? = nil, state: String? = nil, lastError: String? = nil, lastDeliveryError: String? = nil,
                failureStreak: Int = 0, manualRunAt: String? = nil, latestExecution: HermesJobExecution? = nil,
                raw: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.deliver = deliver
        self.enabled = enabled
        self.paused = paused
        self.nextRun = nextRun
        self.lastRun = lastRun
        self.lastStatus = lastStatus
        self.state = state
        self.lastError = lastError
        self.lastDeliveryError = lastDeliveryError
        self.failureStreak = failureStreak
        self.manualRunAt = manualRunAt
        self.latestExecution = latestExecution
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        self.raw = raw
        func text(_ keys: String...) -> String? {
            for key in keys {
                switch raw[key] {
                case .string(let s): return s
                case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
                case .object(let o):
                    // schedule may be {"display": "...", "expr": "..."}
                    if let s = o["display"]?.stringValue ?? o["expr"]?.stringValue ?? o["value"]?.stringValue { return s }
                default: continue
                }
            }
            return nil
        }
        id = text("id", "job_id") ?? UUID().uuidString
        name = text("name") ?? "Untitled job"
        prompt = text("prompt") ?? ""
        schedule = text("schedule_display", "schedule", "cron") ?? ""
        deliver = text("deliver", "delivery")
        enabled = raw["enabled"]?.boolValue ?? true
        state = raw["state"]?.stringValue
        paused = raw["paused"]?.boolValue ?? (state == "paused")
        nextRun = text("next_run_at", "next_run")
        lastRun = text("last_run_at", "last_run")
        lastStatus = text("last_status", "last_result")
        lastError = raw["last_error"]?.stringValue
        lastDeliveryError = raw["last_delivery_error"]?.stringValue
        failureStreak = raw["failure_streak"]?.intValue ?? 0
        manualRunAt = raw["manual_run_at"]?.stringValue
        if case .object(let execution)? = raw["latest_execution"] {
            latestExecution = HermesJobExecution(raw: execution)
        } else {
            latestExecution = nil
        }
    }
}

/// One attempt from Hermes' cron execution ledger. Statuses (Hermes 284d220,
/// `cron/executions.py`): claimed → running → completed | failed | unknown
/// (`unknown` = the worker vanished before recording an end). Terminal
/// states are immutable on the server.
public struct HermesJobExecution: Hashable, Sendable, Identifiable {
    public enum Status: String, Sendable {
        case claimed, running, completed, failed, unknown
    }

    public var id: String
    public var jobID: String?
    public var status: Status
    public var rawStatus: String
    public var claimedAt: String?
    public var startedAt: String?
    public var finishedAt: String?
    public var error: String?
    public var deliveryOutcome: String?

    public init(id: String, jobID: String? = nil, status: String, claimedAt: String? = nil, startedAt: String? = nil,
                finishedAt: String? = nil, error: String? = nil, deliveryOutcome: String? = nil) {
        self.id = id
        self.jobID = jobID
        self.rawStatus = status
        self.status = Status(rawValue: status) ?? .unknown
        self.claimedAt = claimedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.deliveryOutcome = deliveryOutcome
    }

    init?(raw: [String: JSONValue]) {
        guard let id = raw["id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(id: id, jobID: raw["job_id"]?.stringValue, status: raw["status"]?.stringValue ?? "unknown",
                  claimedAt: raw["claimed_at"]?.stringValue, startedAt: raw["started_at"]?.stringValue,
                  finishedAt: raw["finished_at"]?.stringValue, error: raw["error"]?.stringValue,
                  deliveryOutcome: raw["delivery_outcome"]?.stringValue)
    }

    public var isTerminal: Bool { status == .completed || status == .failed || status == .unknown }
}

public struct HermesJobDraft: Encodable, Hashable, Sendable {
    public var name: String
    public var schedule: String
    public var prompt: String
    public var deliver: String
    public var skills: [String]?
    public var repeatCount: Int?

    enum CodingKeys: String, CodingKey { case name, schedule, prompt, deliver, skills, repeatCount = "repeat" }

    public init(name: String, schedule: String, prompt: String, deliver: String = "local", skills: [String]? = nil, repeatCount: Int? = nil) {
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.deliver = deliver
        self.skills = skills
        self.repeatCount = repeatCount
    }
}

public struct HermesSkill: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String?
    public var category: String?
    public var id: String { name }
}

public struct HermesToolset: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var label: String?
    public var description: String?
    public var enabled: Bool
    public var configured: Bool
    public var tools: [String]
    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, label, description, enabled, configured, tools }

    public init(name: String, label: String? = nil, description: String? = nil, enabled: Bool = true, configured: Bool = true, tools: [String] = []) {
        self.name = name
        self.label = label
        self.description = description
        self.enabled = enabled
        self.configured = configured
        self.tools = tools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        configured = (try? c.decode(Bool.self, forKey: .configured)) ?? false
        tools = (try? c.decode([String].self, forKey: .tools)) ?? []
    }
}

public struct HermesModelInfo: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ownedBy: String?
    enum CodingKeys: String, CodingKey { case id, ownedBy = "owned_by" }
}

struct HermesListEnvelope<T: Decodable>: Decodable {
    var data: [T]
}

struct HermesJobsEnvelope: Decodable {
    var jobs: [HermesJob]
}

struct HermesJobEnvelope: Decodable {
    var job: HermesJob
}

// MARK: - Decoding helpers

enum HermesDecoding {
    /// Accepts JSON numbers and numeric strings.
    static func number<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    /// Message content can be a string, null, or an OpenAI-style array of parts.
    static func text<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let parts = try? c.decodeIfPresent([JSONValue].self, forKey: key) {
            return parts.compactMap { part -> String? in
                if let s = part.stringValue { return s }
                return part["text"]?.stringValue
            }.joined(separator: "\n")
        }
        return ""
    }
}
