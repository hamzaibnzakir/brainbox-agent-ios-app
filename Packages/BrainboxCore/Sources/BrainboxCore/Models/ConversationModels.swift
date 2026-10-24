import Foundation

public enum MessageRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
    case system
}

public enum MessageState: Codable, Hashable, Sendable {
    case sending
    case streaming
    case complete
    case cancelled
    case failed(AgentError)

    public var isTerminal: Bool {
        switch self {
        case .complete, .cancelled, .failed: return true
        case .sending, .streaming: return false
        }
    }
}

/// Where a Stop stands for a reply, as reported by the backend. The reply is
/// only shown as stopped once the backend reports the run cancelled.
public enum StopPhase: Codable, Hashable, Sendable {
    /// The user pressed Stop; nothing from the server yet.
    case requested
    /// The server accepted the stop and is interrupting the run.
    case acknowledged
    /// The run finished on its own before the stop took effect.
    case finishedFirst
    /// No confirmation (yet): the request failed or the server never answered.
    case unconfirmed(String)

    public var isPending: Bool { self == .requested || self == .acknowledged }
}

/// A photo or file sent with a user message. Its status only advances on a
/// server answer: uploaded = the proxy stored it; sent = Hermes accepted the
/// run that carries it.
public struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, file }
    public enum Status: Codable, Hashable, Sendable {
        case preparing
        case uploading(Double)
        /// Stored in the Brainbox workspace at `serverPath` (files).
        case uploaded
        /// Hermes accepted the run that includes it (inline image or file path).
        case sent
        case failed(String)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var byteCount: Int64
    public var serverPath: String?
    public var status: Status
    /// Small JPEG preview kept on the device (never sent separately).
    public var thumbnail: Data?

    public init(id: UUID = UUID(), name: String, kind: Kind, byteCount: Int64, serverPath: String? = nil,
                status: Status = .preparing, thumbnail: Data? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.byteCount = byteCount
        self.serverPath = serverPath
        self.status = status
        self.thumbnail = thumbnail
    }
}

public struct Message: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var createdAt: Date
    public var state: MessageState
    public var toolCalls: [ToolCall]
    /// The request that produced (assistant) or carried (user) this message.
    public var requestID: UUID?
    /// Server-side run that produced this reply (Hermes `run_id`), so an
    /// interrupted reply can be recovered after reconnecting or relaunching.
    public var runID: String?
    /// An approval the agent is waiting on right now.
    public var pendingApproval: AgentApproval?
    /// Approvals already answered during this reply (audit trail in the UI).
    public var resolvedApprovals: [ResolvedApproval]?
    /// Reasoning summary the backend chose to expose, if any.
    public var reasoning: String?
    /// Stop progress for this reply (nil when Stop wasn't pressed).
    public var stop: StopPhase?
    /// Photos / files sent with this (user) message.
    public var attachments: [MessageAttachment]?
    /// What was actually sent when it differs from what's shown — e.g. the
    /// skill message Hermes built for `/skill …`, or file paths appended.
    public var sentContent: String?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        createdAt: Date = Date(),
        state: MessageState = .complete,
        toolCalls: [ToolCall] = [],
        requestID: UUID? = nil,
        runID: String? = nil,
        pendingApproval: AgentApproval? = nil,
        resolvedApprovals: [ResolvedApproval]? = nil,
        reasoning: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.state = state
        self.toolCalls = toolCalls
        self.requestID = requestID
        self.runID = runID
        self.pendingApproval = pendingApproval
        self.resolvedApprovals = resolvedApprovals
        self.reasoning = reasoning
    }
}

/// A human decision the agent is blocked on (e.g. a dangerous command).
public struct AgentApproval: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var runID: String
    /// The exact action, as reported (and redacted) by the backend.
    public var command: String
    public var description: String?
    /// Choices the backend accepts, e.g. ["once", "session", "always", "deny"].
    public var choices: [String]
    public var requestID: String?
    public var requestedAt: Date

    public init(id: String = UUID().uuidString, runID: String, command: String, description: String? = nil,
                choices: [String], requestID: String? = nil, requestedAt: Date = Date()) {
        self.id = id
        self.runID = runID
        self.command = command
        self.description = description
        self.choices = choices
        self.requestID = requestID
        self.requestedAt = requestedAt
    }
}

public struct ResolvedApproval: Codable, Hashable, Sendable {
    public var command: String
    public var choice: String
    public var resolvedAt: Date

    public init(command: String, choice: String, resolvedAt: Date = Date()) {
        self.command = command
        self.choice = choice
        self.resolvedAt = resolvedAt
    }
}

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var providerKind: ProviderKind
    public var messages: [Message]
    /// Backend session this conversation is bound to (Hermes `session_id`).
    public var backendSessionID: String?
    /// The AI teammate this conversation belongs to.
    public var teammateID: UUID?
    /// Where the conversation started (e.g. "ios", or "telegram" for a copy
    /// of a Telegram conversation). Purely informational.
    public var origin: String?
    /// Stored flag behind `carriesHistory`. Optional so conversations saved
    /// by older builds (which lack the key) still decode.
    public var carriedHistory: Bool?
    /// When the conversation was archived (nil = in the main list). Optional so
    /// conversations saved by older builds still decode.
    public var archivedAt: Date?
    /// Model chosen for this chat with /model (nil = the preset's model).
    public var modelOverride: String?

    public var isArchived: Bool { archivedAt != nil }

    /// True for a copy of a conversation from another source (e.g. Telegram).
    /// Hermes never stores caller-supplied history, so every run for such a
    /// conversation re-sends its transcript as `conversation_history`; the
    /// original session is only ever read.
    public var carriesHistory: Bool {
        get { carriedHistory ?? false }
        set { carriedHistory = newValue ? true : nil }
    }

    public init(
        id: UUID = UUID(),
        title: String = Conversation.untitled,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerKind: ProviderKind,
        messages: [Message] = [],
        backendSessionID: String? = nil,
        teammateID: UUID? = nil,
        origin: String? = nil,
        carriesHistory: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerKind = providerKind
        self.messages = messages
        self.backendSessionID = backendSessionID
        self.teammateID = teammateID
        self.origin = origin
        self.carriedHistory = carriesHistory ? true : nil
    }

    public static let untitled = "New conversation"

    public var preview: String {
        guard let last = messages.last(where: { $0.role != .system }) else { return "" }
        return MessageSegment.plainText(last.content)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A short, deterministic title derived from the first user message.
    /// Providers may later replace it with `AgentEvent.conversationTitle`.
    public static func suggestedTitle(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return untitled }
        let words = cleaned.split(separator: " ").prefix(6).joined(separator: " ")
        let trimmed = words.count > 42 ? String(words.prefix(42)) + "…" : words
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

/// Lightweight listing entry returned by `conversationHistory()`.
public struct ConversationSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date
    public var preview: String

    public init(id: UUID, title: String, updatedAt: Date, preview: String) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.preview = preview
    }
}

// MARK: - Tools

public enum ToolKind: String, Codable, Sendable, CaseIterable, Hashable {
    case terminal, file, search, browser, code, system, service, git, network, other

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .file: return "File"
        case .search: return "Search"
        case .browser: return "Browser"
        case .code: return "Code"
        case .system: return "System"
        case .service: return "Service"
        case .git: return "Git"
        case .network: return "Network"
        case .other: return "Tool"
        }
    }

    /// SF Symbol used by the UI. Kept in core so every surface agrees.
    public var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .file: return "doc.text"
        case .search: return "magnifyingglass"
        case .browser: return "globe"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .system: return "cpu"
        case .service: return "gearshape.2"
        case .git: return "arrow.triangle.branch"
        case .network: return "network"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

public enum ToolStatus: String, Codable, Sendable, Hashable {
    case pending, running, succeeded, failed, cancelled

    public var isFinished: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public var output: String
    public var exitCode: Int?
    public var isError: Bool
    public var truncated: Bool

    public init(output: String, exitCode: Int? = nil, isError: Bool = false, truncated: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.isError = isError
        self.truncated = truncated
    }
}

public struct ToolCall: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: ToolKind
    /// Machine name, e.g. `terminal.run`.
    public var name: String
    /// Human sentence, e.g. "Checking server status".
    public var title: String
    /// The primary input shown in the card, e.g. the command line or path.
    public var input: String
    public var status: ToolStatus
    /// Streaming output collected while the tool runs.
    public var liveOutput: String
    public var result: ToolResult?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: ToolKind,
        name: String,
        title: String,
        input: String,
        status: ToolStatus = .running,
        liveOutput: String = "",
        result: ToolResult? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.title = title
        self.input = input
        self.status = status
        self.liveOutput = liveOutput
        self.result = result
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

/// A direct tool invocation requested by the UI (not by the model).
public struct ToolInvocation: Codable, Hashable, Sendable {
    public var kind: ToolKind
    public var name: String
    public var arguments: [String: String]
    /// Destructive invocations require biometric confirmation in the UI
    /// and must never be replayed automatically after reconnecting.
    public var isDestructive: Bool

    public init(kind: ToolKind, name: String, arguments: [String: String] = [:], isDestructive: Bool = false) {
        self.kind = kind
        self.name = name
        self.arguments = arguments
        self.isDestructive = isDestructive
    }
}

// MARK: - Requests & events

public struct AgentRequest: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var conversationID: UUID
    /// Client-side id for the assistant message the response streams into.
    public var responseMessageID: UUID
    public var content: String
    /// Backend-specific routing (session, teammate instructions, model).
    public var options: AgentRequestOptions?
    /// Images sent inline to the model as `data:image/…;base64,…` URLs.
    public var imageDataURLs: [String]?

    public init(requestID: UUID = UUID(), conversationID: UUID, responseMessageID: UUID = UUID(), content: String, options: AgentRequestOptions? = nil) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.responseMessageID = responseMessageID
        self.content = content
        self.options = options
    }
}

/// One prior turn sent with a request when the backend must not load the
/// history itself (see `Conversation.carriesHistory`).
public struct HistoryTurn: Codable, Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AgentRequestOptions: Codable, Hashable, Sendable {
    /// Existing backend session to continue. For Hermes this is always one
    /// of the app's own `ios_` sessions; other sessions are never written to.
    public var sessionID: String?
    /// Extra instructions layered on top of the agent's own system prompt.
    public var instructions: String?
    public var model: String?
    public var provider: String?
    public var teammateID: UUID?
    public var title: String?
    /// Hermes profile to run on (`/p/<profile>/`); nil = the default profile.
    public var profile: String?
    /// Prior turns to send with the run instead of letting the backend load
    /// its own history (copied conversations only).
    public var conversationHistory: [HistoryTurn]?

    public init(sessionID: String? = nil, instructions: String? = nil, model: String? = nil, provider: String? = nil, teammateID: UUID? = nil, title: String? = nil, profile: String? = nil, conversationHistory: [HistoryTurn]? = nil) {
        self.sessionID = sessionID
        self.instructions = instructions
        self.model = model
        self.provider = provider
        self.teammateID = teammateID
        self.title = title
        self.profile = profile
        self.conversationHistory = conversationHistory
    }
}

/// The provider-independent stream of things that happen while an agent
/// answers. Every provider (mock, remote gateway, future Hermes) emits
/// exactly these events, so the UI never changes when backends change.
public enum AgentEvent: Hashable, Sendable {
    case accepted(requestID: UUID)
    case status(AgentStatus)
    case textDelta(String)
    case toolStarted(ToolCall)
    case toolOutput(toolCallID: String, chunk: String)
    case toolFinished(toolCallID: String, result: ToolResult, status: ToolStatus)
    case conversationTitle(String)
    /// The backend accepted the turn as a server-side run.
    case runStarted(runID: String, sessionID: String?)
    /// Reasoning text the backend chose to expose.
    case reasoning(String)
    /// The agent is blocked until a human decides.
    case approvalRequested(AgentApproval)
    case approvalResolved(choice: String)
    /// A short informational line (e.g. "Steering accepted").
    case notice(String)
    /// Stop lifecycle, from the user's press to the backend's acknowledgement.
    case stopRequested
    case stopAcknowledged
    case stopUnconfirmed(String)
    case completed
    case failed(AgentError)
}
