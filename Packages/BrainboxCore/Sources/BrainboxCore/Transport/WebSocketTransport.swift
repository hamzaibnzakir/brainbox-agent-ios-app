import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A text-frame WebSocket. Abstracted so the gateway connection can be
/// tested with an in-memory transport and so other transports
/// (e.g. HTTPS long-polling) could be added later.
public protocol WebSocketTransport: AnyObject, Sendable {
    func open(url: URL, headers: [String: String]) async throws
    func send(_ text: String) async throws
    /// Waits for the next text frame. Throws when the socket closes.
    func receive() async throws -> String
    func close()
}

public typealias TransportFactory = @Sendable () -> WebSocketTransport

/// Production transport backed by `URLSessionWebSocketTask`.
public final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, @unchecked Sendable {
    private let session: URLSession
    private let task = Locked<URLSessionWebSocketTask?>(nil)
    private let connectTimeout: TimeInterval

    public init(connectTimeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = connectTimeout
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
        self.connectTimeout = connectTimeout
        super.init()
    }

    public func open(url: URL, headers: [String: String]) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws" else {
            throw AgentError.unableToConnect(detail: "The backend URL must start with wss:// (or ws:// on a private Tailscale network).")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = connectTimeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let newTask = session.webSocketTask(with: request)
        newTask.maximumMessageSize = 8 * 1024 * 1024
        task.withLock { existing in
            existing?.cancel(with: .goingAway, reason: nil)
            existing = newTask
        }
        newTask.resume()
    }

    public func send(_ text: String) async throws {
        guard let current = task.current else { throw AgentError.webSocketDisconnected }
        do {
            try await current.send(.string(text))
        } catch {
            throw AgentError.webSocketDisconnected
        }
    }

    public func receive() async throws -> String {
        guard let current = task.current else { throw AgentError.webSocketDisconnected }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await current.receive()
        } catch {
            throw error.asAgentError == .cancelled ? AgentError.cancelled : AgentError.webSocketDisconnected
        }
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw AgentError.protocolViolation(detail: "Binary frame is not UTF-8 JSON.")
            }
            return text
        @unknown default:
            throw AgentError.protocolViolation(detail: "Unsupported frame type.")
        }
    }

    public func close() {
        task.withLock { existing in
            existing?.cancel(with: .normalClosure, reason: nil)
            existing = nil
        }
    }
}

/// In-memory transport used by tests and by previews. The "server side"
/// is driven through `serverSend` / `clientFrames`.
public final class InMemoryWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private struct State {
        var isOpen = false
        var inbox: [String] = []
        var waiters: [CheckedContinuation<String, Error>] = []
        var sent: [String] = []
        var sentWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        var failOpenWith: AgentError?
        var openCount = 0
    }

    private let state = Locked(State())
    /// Called on the "server" for every frame the client sends.
    public var onClientFrame: (@Sendable (String) -> Void)?

    public init() {}

    public var openCount: Int { state.withLock { $0.openCount } }
    public var sentFrames: [String] { state.withLock { $0.sent } }
    public var isOpen: Bool { state.withLock { $0.isOpen } }

    public func failNextOpen(with error: AgentError?) {
        state.withLock { $0.failOpenWith = error }
    }

    public func open(url: URL, headers: [String: String]) async throws {
        let failure = state.withLock { s -> AgentError? in
            s.openCount += 1
            if let error = s.failOpenWith { s.failOpenWith = nil; return error }
            s.isOpen = true
            s.inbox.removeAll()
            return nil
        }
        if let failure { throw failure }
    }

    public func send(_ text: String) async throws {
        let (open, waiters) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard s.isOpen else { return (false, []) }
            s.sent.append(text)
            let count = s.sent.count
            let ready = s.sentWaiters.filter { $0.0 <= count }.map { $0.1 }
            s.sentWaiters.removeAll { $0.0 <= count }
            return (true, ready)
        }
        guard open else { throw AgentError.webSocketDisconnected }
        waiters.forEach { $0.resume() }
        onClientFrame?(text)
    }

    public func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let action = state.withLock { s -> Result<String, Error>? in
                if !s.inbox.isEmpty { return .success(s.inbox.removeFirst()) }
                if !s.isOpen { return .failure(AgentError.webSocketDisconnected) }
                s.waiters.append(continuation)
                return nil
            }
            if let action { continuation.resume(with: action) }
        }
    }

    public func close() {
        let waiters = state.withLock { s -> [CheckedContinuation<String, Error>] in
            s.isOpen = false
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        waiters.forEach { $0.resume(throwing: AgentError.webSocketDisconnected) }
    }

    // MARK: Server-side controls

    /// Delivers a frame to the client.
    public func serverSend(_ text: String) {
        let waiter = state.withLock { s -> CheckedContinuation<String, Error>? in
            guard s.isOpen else { return nil }
            if !s.waiters.isEmpty { return s.waiters.removeFirst() }
            s.inbox.append(text)
            return nil
        }
        waiter?.resume(returning: text)
    }

    public func serverSend(_ envelope: WireEnvelope) {
        if let text = try? envelope.encodedString() { serverSend(text) }
    }

    /// Simulates the server dropping the connection.
    public func serverDrop() { close() }

    /// Suspends until the client has sent at least `count` frames in total.
    public func waitForSentFrames(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.sent.count >= count { return true }
                s.sentWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
