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

public struct Message: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var createdAt: Date
    public var state: MessageState
    public var toolCalls: [ToolCall]
    /// The request that produced (assistant) or carried (user) this message.
    public var requestID: UUID?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        createdAt: Date = Date(),
        state: MessageState = .complete,
        toolCalls: [ToolCall] = [],
        requestID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.state = state
        self.toolCalls = toolCalls
        self.requestID = requestID
    }
}

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var providerKind: ProviderKind
    public var messages: [Message]

    public init(
        id: UUID = UUID(),
        title: String = Conversation.untitled,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerKind: ProviderKind,
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerKind = providerKind
        self.messages = messages
    }

    public static let untitled = "New conversation"

    public var preview: String {
        messages.last(where: { $0.role != .system })?.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces) ?? ""
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

    public init(requestID: UUID = UUID(), conversationID: UUID, responseMessageID: UUID = UUID(), content: String) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.responseMessageID = responseMessageID
        self.content = content
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
    case completed
    case failed(AgentError)
}
