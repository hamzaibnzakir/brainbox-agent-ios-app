import Crypto
import Foundation

public enum WebSocketError: Error, LocalizedError, Equatable {
    case handshakeFailed(Int, String)
    case protocolError(String)
    case closed(code: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .handshakeFailed(let status, let body):
            return status == 401 || status == 403
                ? "Hermes refused the session token. Reconnecting will start a fresh session."
                : "Couldn't open Hermes' live channel (\(status)) \(body.prefix(120))"
        case .protocolError(let why): return "Live channel error: \(why)"
        case .closed(let code, let reason): return "Live channel closed (\(code)\(reason.isEmpty ? "" : ": \(reason)"))."
        }
    }
}

/// RFC 6455 client over any byte stream (here: an SSH direct-tcpip channel to `hermes serve`).
public final class TunnelWebSocket: @unchecked Sendable {
    public let messages: AsyncThrowingStream<String, Error>
    private let duplex: ByteDuplex
    private let lock = NSLock()
    private var isClosed = false
    private var reader: Task<Void, Never>?

    private init(duplex: ByteDuplex, messages: AsyncThrowingStream<String, Error>) {
        self.duplex = duplex
        self.messages = messages
    }

    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func acceptValue(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
    }

    public static func connect(dialer: TunnelDialer, path: String, headers: [String: String] = [:]) async throws -> TunnelWebSocket {
        let duplex = try await dialer.dial()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        request += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (k, v) in headers { request += "\(k): \(v)\r\n" }
        request += "\r\n"
        let reader = ByteReader(duplex)
        do {
            try await duplex.write(Data(request.utf8))
            guard let head = try await reader.read(until: Data("\r\n\r\n".utf8)) else {
                throw WebSocketError.handshakeFailed(0, "connection closed")
            }
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            let status = Int((lines.first ?? "").split(separator: " ").dropFirst().first ?? "") ?? 0
            var accept = ""
            for line in lines.dropFirst() where line.lowercased().hasPrefix("sec-websocket-accept:") {
                accept = line.dropFirst("sec-websocket-accept:".count).trimmingCharacters(in: .whitespaces)
            }
            guard status == 101 else {
                let body = String(decoding: reader.buffer.prefix(300), as: UTF8.self)
                throw WebSocketError.handshakeFailed(status, body)
            }
            guard accept == acceptValue(for: key) else { throw WebSocketError.protocolError("bad accept key") }
        } catch {
            duplex.close()
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let socket = TunnelWebSocket(duplex: duplex, messages: stream)
        socket.reader = Task { await socket.readLoop(reader, continuation) }
        continuation.onTermination = { _ in socket.close() }
        return socket
    }

    private func readLoop(_ reader: ByteReader, _ continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        var fragments = Data()
        var fragmentOpcode: UInt8 = 0
        do {
            while true {
                let header = try await reader.read(exactly: 2)
                let fin = header[0] & 0x80 != 0
                let opcode = header[0] & 0x0F
                let masked = header[1] & 0x80 != 0
                var length = UInt64(header[1] & 0x7F)
                if length == 126 {
                    let ext = try await reader.read(exactly: 2)
                    length = UInt64(ext[0]) << 8 | UInt64(ext[1])
                } else if length == 127 {
                    let ext = try await reader.read(exactly: 8)
                    length = ext.reduce(0) { $0 << 8 | UInt64($1) }
                }
                guard length < 256 << 20 else { throw WebSocketError.protocolError("frame too large") }
                let mask = masked ? Array(try await reader.read(exactly: 4)) : []
                var payload = try await reader.read(exactly: Int(length))
                if masked {
                    payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
                }
                switch opcode {
                case 0x0:
                    fragments.append(payload)
                    if fin {
                        if fragmentOpcode == 0x1 { continuation.yield(String(decoding: fragments, as: UTF8.self)) }
                        fragments.removeAll()
                    }
                case 0x1, 0x2:
                    if fin {
                        if opcode == 0x1 { continuation.yield(String(decoding: payload, as: UTF8.self)) }
                    } else {
                        fragmentOpcode = opcode
                        fragments = payload
                    }
                case 0x8:
                    let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : 1005
                    let reason = payload.count > 2 ? String(decoding: payload.dropFirst(2), as: UTF8.self) : ""
                    try? await sendFrame(opcode: 0x8, payload: payload.prefix(2))
                    close()
                    continuation.finish(throwing: code == 1000 ? nil : WebSocketError.closed(code: code, reason: reason))
                    return
                case 0x9:
                    try await sendFrame(opcode: 0xA, payload: payload)
                default:
                    break
                }
            }
        } catch {
            close()
            continuation.finish(throwing: error)
        }
    }

    static func frame(opcode: UInt8, payload: Data, mask: [UInt8]) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8(UInt64(count) >> (UInt64($0) * 8) & 0xFF) })
        }
        frame.append(contentsOf: mask)
        frame.append(Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
        return frame
    }

    private func sendFrame(opcode: UInt8, payload: Data) async throws {
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        try await duplex.write(Self.frame(opcode: opcode, payload: payload, mask: mask))
    }

    public func send(text: String) async throws {
        if lock.withLock({ isClosed }) { throw WebSocketError.closed(code: 1006, reason: "") }
        try await sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    public func close() {
        let alreadyClosed = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return isClosed
        }
        guard !alreadyClosed else { return }
        duplex.close()
    }
}
