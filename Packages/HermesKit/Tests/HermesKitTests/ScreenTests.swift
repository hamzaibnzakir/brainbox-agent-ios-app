import BrainboxCore
import Foundation
@testable import HermesKit
import XCTest

/// An in-memory server end for `TunnelWebSocket`: answers the handshake, lets the test push
/// frames to the client and records (unmasked) what the client sent.
final class FakeWebSocketServer: ByteDuplex, TunnelDialer, @unchecked Sendable {
    let events: AsyncThrowingStream<SSHStreamEvent, Error>
    private let input: AsyncThrowingStream<SSHStreamEvent, Error>.Continuation
    private let lock = NSLock()
    private var handshakeDone = false
    private var inbound = Data()
    private(set) var received: [(opcode: UInt8, payload: Data)] = []
    private(set) var requestHead = ""
    private(set) var closed = false

    init() {
        (events, input) = AsyncThrowingStream.makeStream(of: SSHStreamEvent.self)
    }

    func dial() async throws -> ByteDuplex { self }

    func write(_ data: Data) async throws {
        let reply: Data? = lock.withLock {
            if !handshakeDone {
                handshakeDone = true
                requestHead = String(decoding: data, as: UTF8.self)
                let key = requestHead.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                    .dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) ?? ""
                return Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: \(TunnelWebSocket.acceptValue(for: key))\r\n\r\n").utf8)
            }
            inbound.append(data)
            parseFrames()
            return nil
        }
        if let reply { input.yield(.data(reply)) }
    }

    /// Decodes complete client frames (always masked) from `inbound`.
    private func parseFrames() {
        while inbound.count >= 2 {
            let bytes = [UInt8](inbound)
            let opcode = bytes[0] & 0x0F
            var length = Int(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }; offset = 10
            }
            guard bytes.count >= offset + 4 + length else { return }
            let mask = Array(bytes[offset..<offset + 4])
            let payload = Data(bytes[(offset + 4)..<(offset + 4 + length)].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            received.append((opcode, payload))
            inbound.removeFirst(offset + 4 + length)
        }
    }

    /// Sends one unmasked server frame.
    func push(opcode: UInt8, _ payload: Data, fin: Bool = true) {
        var frame = Data([(fin ? 0x80 : 0) | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else { frame.append(126); frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) }
        frame.append(payload)
        input.yield(.data(frame))
    }

    func close() {
        lock.withLock { closed = true }
        input.finish()
    }

    var frames: [(opcode: UInt8, payload: Data)] { lock.withLock { received } }
}

final class ScreenTests: XCTestCase {
    func testStatusAndLeaseParse() {
        let json: JSONValue = [
            "profile": "default", "profile_key": "abc", "supported": true, "installed": false,
            "missing": ["Xvnc", "xfwm4"], "running": false, "geometry": "1440x900",
            "install_command": "apt-get install -y tigervnc-standalone-server", "placement": "gateway",
            "lease": ["holder": "human", "viewer_hash": "h1", "since": 1_700_000_000, "epoch": 3, "reason": "captcha"],
        ]
        let status = ScreenStatus(json: json)
        XCTAssertEqual(status.profileKey, "abc")
        XCTAssertFalse(status.installed)
        XCTAssertEqual(status.missing, ["Xvnc", "xfwm4"])
        XCTAssertEqual(status.size?.width, 1440)
        XCTAssertEqual(status.size?.height, 900)
        XCTAssertEqual(status.lease.holder, .human)
        XCTAssertEqual(status.lease.epoch, 3)
        XCTAssertEqual(status.lease.viewerHash, "h1")

        let event = GatewayEvent(type: "display.lease", payload: ["profile_key": "abc", "lease": ["holder": "agent", "epoch": 4, "since": 0]])
        XCTAssertEqual(ScreenEvent(event), .lease(profileKey: "abc", ScreenLease(holder: .agent, since: Date(timeIntervalSince1970: 0), epoch: 4)))
        XCTAssertNil(ScreenEvent(GatewayEvent(type: "message.delta")))
    }

    func testTicketPathAndErrors() {
        let ticket = ScreenTicket(ticket: "aB-_9+/=", path: "/api/display/ws", viewerID: "v", status: ScreenStatus())
        XCTAssertEqual(ticket.socketPath, "/api/display/ws?display_ticket=aB-_9%2B%2F%3D")

        XCTAssertNil(ScreenError.fromClose(code: 1000, reason: ""))
        XCTAssertEqual(ScreenError.fromClose(code: 4000, reason: "control-taken"), .controlTaken)
        XCTAssertEqual(ScreenError.fromClose(code: 4001, reason: ""), .screenGone)
        XCTAssertEqual(ScreenError.fromClose(code: 4401, reason: ""), .ticketRejected)

        XCTAssertEqual(ScreenError.from(RPCError(code: -32601, message: "unknown method")) as? ScreenError, .unsupportedHermes)
        XCTAssertEqual(ScreenError.from(RPCError(code: 5300, message: "x", data: ["code": "viewer_mismatch"])) as? ScreenError, .staleViewer)
        XCTAssertEqual(ScreenError.from(RPCError(code: 5300, message: "this profile's Bot Desktop is not running; call display.start first")) as? ScreenError, .notRunning)

        XCTAssertTrue(ScreenStatus.isScreenTool("browser_navigate"))
        XCTAssertTrue(ScreenStatus.isScreenTool("computer_use"))
        XCTAssertFalse(ScreenStatus.isScreenTool("terminal"))
    }

    func testBinaryFramesOrderedSendsAndCleanClose() async throws {
        let server = FakeWebSocketServer()
        let socket = try await TunnelWebSocket.connect(dialer: server, path: "/api/display/ws?display_ticket=t")
        XCTAssertTrue(server.requestHead.hasPrefix("GET /api/display/ws?display_ticket=t HTTP/1.1\r\n"))

        // Server → client: one whole binary frame, one fragmented binary message, one text frame.
        server.push(opcode: 0x2, Data("RFB 003.008\n".utf8))
        server.push(opcode: 0x2, Data([1, 2]), fin: false)
        server.push(opcode: 0x0, Data([3]), fin: true)
        server.push(opcode: 0x1, Data("hi".utf8))
        var iterator = socket.frames.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let third = try await iterator.next()
        XCTAssertEqual(first, .binary(Data("RFB 003.008\n".utf8)))
        XCTAssertEqual(second, .binary(Data([1, 2, 3])))
        XCTAssertEqual(third, .text("hi"))

        // Client → server: queued input arrives in order, then a clean close frame (1000).
        for i in 0..<200 { XCTAssertTrue(socket.enqueue(binary: Data([UInt8(i % 256), 0xAA]))) }
        await socket.close(code: 1000, reason: "bye")
        let sent = server.frames
        XCTAssertEqual(sent.count, 201)
        XCTAssertEqual(sent.prefix(200).map { $0.payload.first ?? 0 }, (0..<200).map { UInt8($0 % 256) })
        XCTAssertTrue(sent.prefix(200).allSatisfy { $0.opcode == 0x2 })
        XCTAssertEqual(sent.last?.opcode, 0x8)
        XCTAssertEqual(sent.last?.payload, TunnelWebSocket.closePayload(code: 1000, reason: "bye"))
        XCTAssertEqual(Array(TunnelWebSocket.closePayload(code: 1000, reason: "").prefix(2)), [0x03, 0xE8])
        XCTAssertTrue(server.closed)
        XCTAssertFalse(socket.isOpen)
        XCTAssertFalse(socket.enqueue(binary: Data([1])), "nothing is sent after close")
    }
}
