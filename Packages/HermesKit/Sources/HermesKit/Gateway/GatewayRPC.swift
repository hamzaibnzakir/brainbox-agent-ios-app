import BrainboxCore
import Foundation

/// One event from Hermes' gateway (`{"method":"event","params":{type, session_id, seq, payload}}`).
public struct GatewayEvent: Sendable, Hashable {
    public var type: String
    public var sessionID: String?
    public var seq: Int?
    public var payload: JSONValue

    public init(type: String, sessionID: String? = nil, seq: Int? = nil, payload: JSONValue = .null) {
        self.type = type
        self.sessionID = sessionID
        self.seq = seq
        self.payload = payload
    }

    public init?(json: JSONValue) {
        guard let type = json["type"]?.stringValue else { return nil }
        self.type = type
        let sid = json["session_id"]?.stringValue
        sessionID = (sid?.isEmpty ?? true) ? nil : sid
        seq = json["seq"]?.intValue
        payload = json["payload"] ?? .null
    }
}

public struct RPCError: Error, LocalizedError, Equatable, Sendable {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message.isEmpty ? "Hermes error \(code)" : message }

    public static let timedOut = RPCError(code: -32000, message: "Hermes didn't answer in time.")
    public static let disconnected = RPCError(code: -32001, message: "Lost the live connection to Hermes.")
}

/// Hermes' JSON-RPC 2.0 gateway (`tui_gateway`) over a WebSocket.
public final class GatewayRPC: @unchecked Sendable {
    private let socket: TunnelWebSocket
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    private var readyEvent: GatewayEvent?
    private var readyWaiters: [CheckedContinuation<GatewayEvent?, Never>] = []
    private var reader: Task<Void, Never>?
    public private(set) var closeReason: Error?

    public init(socket: TunnelWebSocket) {
        self.socket = socket
        reader = Task { [weak self] in await self?.readLoop() }
    }

    public var closed: Bool { lock.withLock { isClosed } }

    /// A fresh stream of every event from now on.
    public func subscribe() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self, bufferingPolicy: .unbounded)
        let alreadyClosed = lock.withLock { () -> Bool in
            if isClosed { return true }
            subscribers[id] = continuation
            return false
        }
        if alreadyClosed { continuation.finish() }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// The gateway's `gateway.ready` event, waiting up to `timeout` for it.
    public func waitForReady(timeout: TimeInterval = 5) async -> GatewayEvent? {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let waiters = self.lock.withLock { () -> [CheckedContinuation<GatewayEvent?, Never>] in
                defer { self.readyWaiters.removeAll() }
                return self.readyWaiters
            }
            for w in waiters { w.resume(returning: nil) }
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<GatewayEvent?, Never>) in
            let ready = lock.withLock { () -> GatewayEvent?? in
                if let readyEvent { return .some(readyEvent) }
                if isClosed { return .some(nil) }
                readyWaiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Suspends until the gateway connection ends.
    public func waitUntilClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock { () -> Bool in
                if isClosed { return true }
                closeWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func readLoop() async {
        do {
            for try await text in socket.messages {
                handle(text)
            }
            finish(RPCError.disconnected)
        } catch {
            finish(error)
        }
    }

    func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let frame = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if let method = frame["method"]?.stringValue {
            if method == "event", let params = frame["params"], let event = GatewayEvent(json: params) {
                if event.type == "gateway.ready" {
                    let waiters = lock.withLock { () -> [CheckedContinuation<GatewayEvent?, Never>] in
                        readyEvent = event
                        defer { readyWaiters.removeAll() }
                        return readyWaiters
                    }
                    for w in waiters { w.resume(returning: event) }
                }
                let targets = lock.withLock { Array(subscribers.values) }
                for target in targets { target.yield(event) }
            } else if let id = frame["id"] {
                // Server→client request this client doesn't implement: answer so nothing hangs.
                let reply: JSONValue = ["jsonrpc": "2.0", "id": id,
                                        "error": ["code": -32601, "message": .string("not supported by Brainbox: \(method)")]]
                Task { try? await self.sendFrame(reply) }
            }
            return
        }
        guard let id = frame["id"]?.intValue else { return }
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        guard let continuation else { return }
        if let error = frame["error"] {
            continuation.resume(throwing: RPCError(code: error["code"]?.intValue ?? -1,
                                                   message: error["message"]?.stringValue ?? "Hermes error"))
        } else {
            continuation.resume(returning: frame["result"] ?? .null)
        }
    }

    private func finish(_ error: Error) {
        let (waiting, subs, closers) = lock.withLock { () -> ([CheckedContinuation<JSONValue, Error>], [AsyncStream<GatewayEvent>.Continuation], [CheckedContinuation<Void, Never>]) in
            if isClosed { return ([], [], []) }
            isClosed = true
            closeReason = error
            let w = Array(pending.values); pending.removeAll()
            let s = Array(subscribers.values); subscribers.removeAll()
            let c = closeWaiters; closeWaiters.removeAll()
            return (w, s, c)
        }
        let readies = lock.withLock { () -> [CheckedContinuation<GatewayEvent?, Never>] in
            defer { readyWaiters.removeAll() }
            return readyWaiters
        }
        for r in readies { r.resume(returning: nil) }
        for w in waiting { w.resume(throwing: RPCError.disconnected) }
        for s in subs { s.finish() }
        for c in closers { c.resume() }
    }

    private func sendFrame(_ frame: JSONValue) async throws {
        let data = try JSONEncoder().encode(frame)
        try await socket.send(text: String(decoding: data, as: UTF8.self))
    }

    /// Calls a gateway method and returns its `result`.
    @discardableResult
    public func call(_ method: String, _ params: [String: JSONValue] = [:], timeout: TimeInterval = 60) async throws -> JSONValue {
        let id: Int = try lock.withLock {
            if isClosed { throw RPCError.disconnected }
            nextID += 1
            return nextID
        }
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params)]
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let c = self.lock.withLock { self.pending.removeValue(forKey: id) }
            c?.resume(throwing: RPCError.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            Task {
                do { try await self.sendFrame(frame) } catch {
                    let c = self.lock.withLock { self.pending.removeValue(forKey: id) }
                    c?.resume(throwing: error)
                }
            }
        }
    }

    public func close() {
        socket.close()
        finish(RPCError.disconnected)
    }
}

public extension JSONValue {
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    /// Best-effort text for any scalar.
    var displayText: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    static func from(any value: Any?) -> JSONValue {
        switch value {
        case nil: return .null
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .number(Double(i))
        case let d as Double: return .number(d)
        case let a as [Any]: return .array(a.map { from(any: $0) })
        case let o as [String: Any]: return .object(o.mapValues { from(any: $0) })
        default: return .null
        }
    }
}
