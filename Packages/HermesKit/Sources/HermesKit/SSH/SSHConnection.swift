import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Where to SSH to.
public struct SSHTarget: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String = "root") {
        self.host = host
        self.port = port
        self.username = username
    }

    /// Stable key for host-key pinning: `[host]:port`, like OpenSSH's known_hosts.
    public var hostID: String { port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)" }
    public var display: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

public enum SSHError: Error, Equatable, Sendable, LocalizedError {
    case connectFailed(String)
    case timedOut(String)
    case authenticationFailed
    /// The server's host key differs from the one pinned on first connect. Fails closed.
    case hostKeyChanged(expected: String, got: String)
    case channelFailed(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let why): return "Couldn't reach the server: \(why)"
        case .timedOut(let what): return "Timed out \(what)."
        case .authenticationFailed:
            return "The server refused this phone's SSH key. Add the key shown in Connection to ~/.ssh/authorized_keys on the server."
        case .hostKeyChanged(let expected, let got):
            return "The server's identity changed (expected \(expected), got \(got)). This can mean someone is intercepting the connection, or the server was reinstalled. Brainbox won't connect until you reset the trusted key in Connection."
        case .channelFailed(let why): return "SSH channel error: \(why)"
        case .closed: return "The SSH connection closed."
        }
    }
}

/// Pins each server's host key on first use (OpenSSH `accept-new`) and refuses a changed one.
public protocol HostKeyStore: AnyObject, Sendable {
    func pinnedKey(for hostID: String) -> String?
    func pin(_ openSSHKey: String, for hostID: String)
}

/// In-memory store (tests; the app persists pins itself).
public final class MemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]
    public init(_ keys: [String: String] = [:]) { self.keys = keys }
    public func pinnedKey(for hostID: String) -> String? { lock.lock(); defer { lock.unlock() }; return keys[hostID] }
    public func pin(_ openSSHKey: String, for hostID: String) { lock.lock(); keys[hostID] = openSSHKey; lock.unlock() }
}

// MARK: - Delegates

private final class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: NIOSSHPrivateKey
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

private final class PinningHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let hostID: String
    let store: HostKeyStore
    var seen: String?

    init(hostID: String, store: HostKeyStore) {
        self.hostID = hostID
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        seen = presented
        if let pinned = store.pinnedKey(for: hostID) {
            if pinned == presented {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHError.hostKeyChanged(
                    expected: SSHFingerprint.of(openSSHKey: pinned), got: SSHFingerprint.of(openSSHKey: presented)))
            }
        } else {
            store.pin(presented, for: hostID)
            validationCompletePromise.succeed(())
        }
    }
}

/// Completes once user auth succeeds; fails on any handshake error.
private final class HandshakeWatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    private var promise: EventLoopPromise<Void>?

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, let promise {
            self.promise = nil
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let promise {
            self.promise = nil
            promise.fail(error)
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let promise {
            self.promise = nil
            promise.fail(SSHError.closed)
        }
        context.fireChannelInactive()
    }
}

// MARK: - Connection

/// One authenticated SSH connection. Opens exec, shell and direct-tcpip channels.
public final class SSHConnection: @unchecked Sendable {
    public let target: SSHTarget
    /// The host key the server presented (OpenSSH format).
    public let hostKey: String
    let channel: Channel

    private init(target: SSHTarget, hostKey: String, channel: Channel) {
        self.target = target
        self.hostKey = hostKey
        self.channel = channel
    }

    public var isActive: Bool { channel.isActive }
    public var hostKeyFingerprint: String { SSHFingerprint.of(openSSHKey: hostKey) }

    /// Resolves when the connection closes for any reason.
    public func waitUntilClosed() async {
        try? await channel.closeFuture.get()
    }

    public static func connect(to target: SSHTarget, identity: SSHIdentity, hostKeys: HostKeyStore,
                               timeout: TimeAmount = .seconds(20),
                               group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> SSHConnection {
        let hostDelegate = PinningHostKeyDelegate(hostID: target.hostID, store: hostKeys)
        let authDelegate = KeyAuthDelegate(username: target.username, key: identity.nioPrivateKey)
        let loop = group.next()
        let handshake = loop.makePromise(of: Void.self)

        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostDelegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(HandshakeWatcher(promise: handshake))
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: target.host, port: target.port).get()
        } catch {
            handshake.fail(error)
            throw SSHError.connectFailed(Self.describe(error))
        }

        let timer = loop.scheduleTask(in: timeout) { handshake.fail(SSHError.timedOut("waiting for the SSH handshake")) }
        do {
            try await handshake.futureResult.get()
            timer.cancel()
        } catch {
            timer.cancel()
            channel.close(promise: nil)
            if let ssh = error as? SSHError { throw ssh }
            if let nio = error as? NIOSSHError, nio.type == .keyExchangeNegotiationFailure {
                throw SSHError.connectFailed("no common SSH algorithms with the server")
            }
            throw SSHError.connectFailed(Self.describe(error))
        }
        return SSHConnection(target: target, hostKey: hostDelegate.seen ?? "", channel: channel)
    }

    static func describe(_ error: Error) -> String {
        if let ssh = error as? SSHError { return ssh.localizedDescription }
        let text = String(describing: error)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    public func close() {
        channel.close(promise: nil)
    }

    // MARK: Channels

    func openChannel(_ type: SSHChannelType) async throws -> SSHByteStream {
        guard channel.isActive else { throw SSHError.closed }
        let (events, continuation) = AsyncThrowingStream.makeStream(of: SSHStreamEvent.self)
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let parent = channel
        parent.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: type) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(SSHStreamHandler(continuation: continuation))
                    }
                }
            } catch {
                promise.fail(error)
            }
        }
        do {
            let child = try await promise.futureResult.get()
            return SSHByteStream(channel: child, events: events)
        } catch {
            continuation.finish(throwing: error)
            throw SSHError.channelFailed(Self.describe(error))
        }
    }

    /// Runs a command and collects its output (non-interactive, no PTY).
    /// `stdin`, when given, is written and then closed — the way to hand secrets to a
    /// remote command without putting them on its command line.
    public func exec(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 60) async throws -> SSHExecResult {
        let stream = try await openChannel(.session)
        try await stream.channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)).get()
        if let stdin {
            try await stream.write(stdin)
        }
        try? await stream.channel.close(mode: .output).get()
        return try await withThrowingTaskGroup(of: SSHExecResult.self) { group in
            group.addTask {
                var out = Data(), err = Data(), status: Int?
                for try await event in stream.events {
                    switch event {
                    case .data(let d): out.append(d)
                    case .stderr(let d): err.append(d)
                    case .exit(let code): status = code
                    case .eof: break
                    }
                }
                return SSHExecResult(stdout: out, stderr: err, exitStatus: status)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                stream.close()
                throw SSHError.timedOut("running a command on the server")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// A TCP stream to `host:port` as seen from the server (`ssh -L`'s building block).
    public func openDirectTCPIP(host: String = "127.0.0.1", port: Int) async throws -> SSHByteStream {
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await openChannel(.directTCPIP(.init(targetHost: host, targetPort: port, originatorAddress: origin)))
    }

    /// An interactive login shell on a PTY.
    public func openShell(term: String = "xterm-256color", columns: Int, rows: Int) async throws -> SSHByteStream {
        let stream = try await openChannel(.session)
        try await stream.channel.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false, term: term, terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))).get()
        try await stream.channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false)).get()
        return stream
    }
}

public struct SSHExecResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitStatus: Int?
    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitStatus == 0 }
}

public enum SSHStreamEvent: Sendable {
    case data(Data)
    case stderr(Data)
    case exit(Int)
    case eof
}

/// One SSH child channel as an async byte stream.
public final class SSHByteStream: @unchecked Sendable {
    let channel: Channel
    public let events: AsyncThrowingStream<SSHStreamEvent, Error>

    init(channel: Channel, events: AsyncThrowingStream<SSHStreamEvent, Error>) {
        self.channel = channel
        self.events = events
    }

    public var isActive: Bool { channel.isActive }

    public func write(_ data: Data) async throws {
        guard channel.isActive else { throw SSHError.closed }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    public func write(_ text: String) async throws { try await write(Data(text.utf8)) }

    /// Tells the PTY the terminal changed size.
    public func resize(columns: Int, rows: Int) {
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0),
            promise: nil)
    }

    public func close() {
        channel.close(promise: nil)
    }
}

final class SSHStreamHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let continuation: AsyncThrowingStream<SSHStreamEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<SSHStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        let payload = Data(bytes.readableBytesView)
        switch message.type {
        case .channel: continuation.yield(.data(payload))
        case .stdErr: continuation.yield(.stderr(payload))
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            continuation.yield(.exit(exit.exitStatus))
        } else if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            // The server closes the channel after EOF (and after the exit status for exec).
            continuation.yield(.eof)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: SSHError.channelFailed(SSHConnection.describe(error)))
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}
