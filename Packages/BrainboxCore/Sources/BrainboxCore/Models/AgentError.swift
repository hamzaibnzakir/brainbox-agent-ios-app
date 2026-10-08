import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every failure the app can show to the user. Nothing fails silently:
/// providers translate transport/backend problems into one of these.
public enum AgentError: Error, Codable, Hashable, Sendable {
    case unableToConnect(detail: String)
    case authenticationFailed(detail: String)
    case agentUnavailable
    case serverUnavailable
    case webSocketDisconnected
    case timedOut
    case permissionDenied(detail: String)
    case fileUnavailable(path: String)
    case fileConflict(path: String)
    case commandFailed(exitCode: Int, detail: String)
    case providerUnavailable(detail: String)
    case notImplemented(detail: String)
    case protocolViolation(detail: String)
    case offline
    case cancelled
    case remote(code: String, message: String)

    public var title: String {
        switch self {
        case .unableToConnect: return "Unable to connect"
        case .authenticationFailed: return "Authentication failed"
        case .agentUnavailable: return "Agent unavailable"
        case .serverUnavailable: return "Server unavailable"
        case .webSocketDisconnected: return "Connection lost"
        case .timedOut: return "Request timed out"
        case .permissionDenied: return "Permission denied"
        case .fileUnavailable: return "File unavailable"
        case .fileConflict: return "File changed on server"
        case .commandFailed: return "Command failed"
        case .providerUnavailable: return "Provider unavailable"
        case .notImplemented: return "Not available yet"
        case .protocolViolation: return "Unexpected response"
        case .offline: return "You're offline"
        case .cancelled: return "Cancelled"
        case .remote: return "Agent error"
        }
    }

    public var message: String {
        switch self {
        case .unableToConnect(let detail): return detail
        case .authenticationFailed(let detail): return detail
        case .agentUnavailable: return "The agent is not responding right now."
        case .serverUnavailable: return "The server could not be reached."
        case .webSocketDisconnected: return "The live connection dropped. Brainbox will reconnect automatically."
        case .timedOut: return "The backend took too long to answer."
        case .permissionDenied(let detail): return detail
        case .fileUnavailable(let path): return "\(path) could not be opened."
        case .fileConflict(let path): return "\(path) was modified elsewhere. Reload before saving."
        case .commandFailed(let code, let detail): return "Exit code \(code). \(detail)"
        case .providerUnavailable(let detail): return detail
        case .notImplemented(let detail): return detail
        case .protocolViolation(let detail): return detail
        case .offline: return "Showing cached data. Actions resume when you're back online."
        case .cancelled: return "The request was cancelled."
        case .remote(let code, let message): return "\(message) (\(code))"
        }
    }

    /// Whether automatic retry (with backoff) makes sense.
    public var isRetryable: Bool {
        switch self {
        case .unableToConnect, .agentUnavailable, .serverUnavailable, .webSocketDisconnected, .timedOut, .offline:
            return true
        default:
            return false
        }
    }
}

extension AgentError: LocalizedError {
    public var errorDescription: String? { "\(title): \(message)" }
}

public extension Error {
    /// Normalises any error into an `AgentError` for display.
    var asAgentError: AgentError {
        if let agentError = self as? AgentError { return agentError }
        if self is CancellationError { return .cancelled }
        let ns = self as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .offline
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return .unableToConnect(detail: "The gateway host could not be reached. Check Tailscale and the backend URL.")
            case NSURLErrorUserAuthenticationRequired: return .authenticationFailed(detail: "The gateway rejected the credentials.")
            default: break
            }
        }
        return .unableToConnect(detail: ns.localizedDescription)
    }
}
