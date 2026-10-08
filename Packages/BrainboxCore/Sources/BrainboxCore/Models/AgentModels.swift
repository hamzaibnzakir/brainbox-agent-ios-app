import Foundation

// MARK: - Provider identity

/// The kind of backend a provider talks to. New providers (OpenAI,
/// Anthropic, local agents...) are added here and get their own
/// `AgentProvider` implementation; the UI never switches on concrete types.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// In-process simulated agent for development. Never a real backend.
    case mock
    /// Any backend that speaks the Brainbox Agent Protocol through a gateway.
    case remote
    /// Hermes adapter. Pending integration — see docs/HERMES_INTEGRATION.md.
    case hermes

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mock: return "Mock (Development)"
        case .remote: return "Remote Agent"
        case .hermes: return "Hermes (Pending)"
        }
    }

    public var isAvailable: Bool { self != .hermes }
}

/// Describes the agent behind a provider.
public struct AgentDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var version: String?
    public var summary: String

    public init(id: String, name: String, kind: ProviderKind, version: String? = nil, summary: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.version = version
        self.summary = summary
    }
}

/// Features a provider can advertise. The UI enables/disables surfaces
/// based on these, instead of assuming every backend can do everything.
public enum ProviderCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case streaming
    case cancellation
    case toolExecution
    case conversationHistory
    case terminal
    case fileSystem
    case serverMetrics
    case serviceControl
    case logs
}

// MARK: - Status

public enum AgentStatus: Codable, Hashable, Sendable {
    case ready
    case thinking
    case streaming
    case runningTool(name: String)
    case offline
    case unavailable(reason: String)

    public var label: String {
        switch self {
        case .ready: return "Ready"
        case .thinking: return "Thinking"
        case .streaming: return "Responding"
        case .runningTool(let name): return "Running \(name)"
        case .offline: return "Offline"
        case .unavailable: return "Unavailable"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .thinking, .streaming, .runningTool: return true
        default: return false
        }
    }
}

public enum ConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, retryIn: TimeInterval)
    case failed(AgentError)

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting(let attempt, _): return "Reconnecting (\(attempt))"
        case .failed(let error): return error.title
        }
    }

    public var isConnected: Bool { self == .connected }
}

public enum AuthenticationState: Hashable, Sendable {
    case unauthenticated
    case authenticating
    case authenticated(subject: String?)
    case failed(reason: String)
}
