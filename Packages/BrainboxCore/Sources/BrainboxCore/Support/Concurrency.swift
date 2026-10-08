import Foundation

/// Minimal lock-protected box used by providers that must expose
/// synchronous, nonisolated APIs (stream factories) over mutable state.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

/// Multicasts values to any number of `AsyncStream` subscribers and
/// replays the latest value to new subscribers.
public final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var latest: Value
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    private let state: Locked<State>

    public init(initial: Value) {
        state = Locked(State(latest: initial))
    }

    public var value: Value { state.withLock { $0.latest } }

    public func send(_ value: Value) {
        let targets = state.withLock { s -> [AsyncStream<Value>.Continuation] in
            s.latest = value
            return Array(s.continuations.values)
        }
        for continuation in targets { continuation.yield(value) }
    }

    public func subscribe() -> AsyncStream<Value> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let current = self.state.withLock { s -> Value in
                s.continuations[id] = continuation
                return s.latest
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func finishAll() {
        let targets = state.withLock { s -> [AsyncStream<Value>.Continuation] in
            let all = Array(s.continuations.values)
            s.continuations.removeAll()
            return all
        }
        targets.forEach { $0.finish() }
    }
}

/// Exponential backoff with full jitter, capped.
public struct ReconnectPolicy: Sendable, Hashable {
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    public var maxAttempts: Int?
    /// 0 = no jitter, 1 = full jitter.
    public var jitter: Double

    public init(initialDelay: TimeInterval = 0.5, multiplier: Double = 2, maxDelay: TimeInterval = 30, maxAttempts: Int? = nil, jitter: Double = 0.25) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitter = jitter
    }

    public static let standard = ReconnectPolicy()

    /// Delay before `attempt` (1-based). Returns nil once attempts are exhausted.
    public func delay(forAttempt attempt: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval? {
        if let maxAttempts, attempt > maxAttempts { return nil }
        let exponent = Double(max(attempt - 1, 0))
        let base = min(initialDelay * pow(multiplier, exponent), maxDelay)
        let spread = base * jitter
        let value = base - spread + (2 * spread * min(max(random, 0), 1))
        return min(max(value, 0), maxDelay)
    }
}

public enum Timeout {
    /// Runs `operation`, throwing `AgentError.timedOut` after `seconds`.
    public static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw AgentError.timedOut
            }
            guard let first = try await group.next() else { throw AgentError.timedOut }
            group.cancelAll()
            return first
        }
    }
}
