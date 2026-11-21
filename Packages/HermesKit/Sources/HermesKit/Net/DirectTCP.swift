import Foundation
import NIOCore
import NIOPosix

/// A plain TCP connection to Hermes over the tailnet (Tailscale already encrypts and authenticates
/// every packet with WireGuard, so there is no SSH layer on top). Hermes itself listens only on the
/// server's 127.0.0.1; `tailscale serve --tcp` forwards the tailnet port to it.
public struct DirectDialer: TunnelDialer {
    public let host: String
    public let port: Int
    public var connectTimeout: TimeInterval

    public init(host: String, port: Int, connectTimeout: TimeInterval = 6) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
    }

    public func dial() async throws -> ByteDuplex {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: SSHStreamEvent.self)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.milliseconds(Int64(connectTimeout * 1000)))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), SSHConnection.keepIdleOption), value: 10)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 5)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 3)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(TCPStreamHandler(continuation: continuation))
                }
            }
        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            return TCPByteStream(channel: channel, events: events)
        } catch {
            continuation.finish(throwing: error)
            throw DirectError.unreachable(host: host, port: port, detail: SSHConnection.describe(error))
        }
    }
}

public enum DirectError: Error, LocalizedError, Equatable {
    case unreachable(host: String, port: Int, detail: String)
    case badToken

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host, let port, _):
            return "Can't reach Hermes at \(host):\(port) over Tailscale. Check that Tailscale is switched on (on this device and on the server) and that the Brainbox service is running on the server."
        case .badToken:
            return "Hermes refused the access token. Copy it again from the server (sudo cat /etc/brainbox/token) into Connection settings."
        }
    }
}

/// One TCP connection as the same async byte stream the SSH channels use.
public final class TCPByteStream: ByteDuplex, @unchecked Sendable {
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

    public func close() {
        channel.close(promise: nil)
    }
}

final class TCPStreamHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let continuation: AsyncThrowingStream<SSHStreamEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<SSHStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            continuation.yield(.data(Data(bytes)))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.yield(.eof)
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}
