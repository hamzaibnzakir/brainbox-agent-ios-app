import Foundation

/// SSH that connects when something needs it. In Tailscale mode the chat doesn't use SSH at all;
/// the terminal, file transfers and Hermes' browser open it on first use (over the tailnet) and it
/// reconnects by itself if it dropped. In SSH mode it simply wraps the connection already open.
public final class SSHLink: @unchecked Sendable {
    public let target: SSHTarget
    let identity: SSHIdentity
    let hostKeys: HostKeyStore
    let timeout: TimeInterval
    private let lock = NSLock()
    private var current: SSHConnection?
    private var connecting: Task<SSHConnection, Error>?

    public init(target: SSHTarget, identity: SSHIdentity, hostKeys: HostKeyStore, timeout: TimeInterval = 10,
                connection: SSHConnection? = nil) {
        self.target = target
        self.identity = identity
        self.hostKeys = hostKeys
        self.timeout = timeout
        self.current = connection
    }

    /// An open SSH connection (opened now if there isn't one).
    public func connection() async throws -> SSHConnection {
        let task: Task<SSHConnection, Error> = lock.withLock {
            if let current, current.isActive { return Task { current } }
            if let connecting { return connecting }
            let (target, identity, hostKeys, timeout) = (target, identity, hostKeys, timeout)
            let t = Task {
                try await SSHConnection.connect(to: target, identity: identity, hostKeys: hostKeys,
                                                timeout: .milliseconds(Int64(timeout * 1000)))
            }
            connecting = t
            return t
        }
        do {
            let connection = try await task.value
            lock.withLock { current = connection; connecting = nil }
            return connection
        } catch {
            lock.withLock { connecting = nil }
            throw error
        }
    }

    public var isActive: Bool { lock.withLock { current?.isActive ?? false } }
    public var hostKeyFingerprint: String { lock.withLock { current?.hostKeyFingerprint ?? "" } }

    public func exec(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 60) async throws -> SSHExecResult {
        try await connection().exec(command, stdin: stdin, timeout: timeout)
    }

    public func execToFile(_ command: String, destination: URL, idleTimeout: TimeInterval = 45,
                           progress: (@Sendable (Int64) -> Void)? = nil) async throws -> SSHExecResult {
        try await connection().execToFile(command, destination: destination, idleTimeout: idleTimeout, progress: progress)
    }

    public func openShell(term: String = "xterm-256color", columns: Int, rows: Int, command: String? = nil) async throws -> SSHByteStream {
        try await connection().openShell(term: term, columns: columns, rows: rows, command: command)
    }

    public func openDirectTCPIP(host: String = "127.0.0.1", port: Int) async throws -> SSHByteStream {
        try await connection().openDirectTCPIP(host: host, port: port)
    }

    public func close() {
        let (c, t) = lock.withLock { () -> (SSHConnection?, Task<SSHConnection, Error>?) in
            defer { current = nil; connecting = nil }
            return (current, connecting)
        }
        t?.cancel()
        c?.close()
    }
}
