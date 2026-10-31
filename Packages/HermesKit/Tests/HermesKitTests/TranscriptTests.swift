import BrainboxCore
@testable import HermesKit
import XCTest

final class TranscriptTests: XCTestCase {
    func ev(_ type: String, _ seq: Int? = nil, _ payload: JSONValue = .null) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "s1", seq: seq, payload: payload)
    }

    func texts(_ t: Transcript) -> [String] {
        t.items.compactMap { if case .assistant(let text, _, _) = $0.kind { return text }; return nil }
    }

    func testStreamsDeltasAndFinalTextWins() {
        var t = Transcript()
        t.addUser("hi")
        t.apply(ev("message.start", 1))
        t.apply(ev("message.delta", 2, ["text": "Hel"]))
        t.apply(ev("message.delta", 3, ["text": "lo"]))
        XCTAssertTrue(t.busy)
        guard case .assistant(_, _, let streaming) = t.items.last!.kind else { return XCTFail() }
        XCTAssertTrue(streaming)
        t.apply(ev("message.complete", 4, ["text": "Hello!", "usage": ["input": 10, "output": 3, "context_percent": 7]]))
        XCTAssertEqual(texts(t), ["Hello!"])
        XCTAssertFalse(t.busy)
        XCTAssertEqual(t.usage?.contextPercent, 7)
        XCTAssertEqual(t.petMood, .done)
    }

    func testDuplicateSeqIsIgnored() {
        var t = Transcript()
        t.apply(ev("message.start", 1))
        XCTAssertTrue(t.apply(ev("message.delta", 2, ["text": "a"])))
        XCTAssertFalse(t.apply(ev("message.delta", 2, ["text": "a"])), "replayed event skipped")
        t.apply(ev("message.delta", 3, ["text": "b"]))
        XCTAssertEqual(texts(t), ["ab"])
        XCTAssertEqual(t.lastSeq, 3)
    }

    func testToolLifecycleAndApproval() {
        var t = Transcript()
        t.apply(ev("message.start", 1))
        t.apply(ev("message.delta", 2, ["text": "Let me check."]))
        t.apply(ev("tool.start", 3, ["tool_id": "c1", "name": "terminal", "context": "ls", "args": ["command": "ls"]]))
        t.apply(ev("approval.request", 4, ["request_id": "r1", "command": "rm -rf x", "description": "delete", "choices": ["once", "deny"]]))
        XCTAssertEqual(t.pendingRequests.count, 1)
        XCTAssertEqual(t.petMood, .waiting)
        t.resolve(requestID: "r1", as: "Approved (once)")
        XCTAssertTrue(t.pendingRequests.isEmpty)
        t.apply(ev("tool.complete", 5, ["tool_id": "c1", "name": "terminal", "duration_s": .number(1.5),
                                        "result": ["output": "oops", "exit_code": 2, "error": .null]]))
        guard case .tool(let tool) = t.items.first(where: { $0.id == "tool-c1" })!.kind else { return XCTFail() }
        XCTAssertEqual(tool.status, .failed)
        XCTAssertEqual(tool.output, "oops")
        t.apply(ev("message.delta", 6, ["text": "Done."]))
        t.apply(ev("message.complete", 7, ["text": "Done."]))
        XCTAssertEqual(texts(t), ["Let me check.", "Done."], "segments stay in order around the tool")
    }

    func testClarifyAndSecretRequests() {
        var t = Transcript()
        t.apply(ev("clarify.request", 1, ["request_id": "q", "question": "Which?", "choices": ["a", "b"]]))
        t.apply(ev("secret.request", 2, ["request_id": "s", "prompt": "Key", "env_var": "X_KEY"]))
        XCTAssertEqual(t.pendingRequests.map(\.respondMethod), ["clarify.respond", "secret.respond"])
        XCTAssertTrue(t.pendingRequests[1].isSensitive)
    }

    func testHydrateFromResume() {
        var t = Transcript()
        t.hydrate(messages: [["role": "user", "text": "hello", "row_id": 1],
                             ["role": "tool", "name": "terminal", "context": "ls"],
                             ["role": "assistant", "text": "hi", "row_id": 3]])
        XCTAssertEqual(t.items.count, 3)
        XCTAssertEqual(texts(t), ["hi"])
    }

    func testErrorEndsTurn() {
        var t = Transcript()
        t.addUser("x")
        t.apply(ev("error", 1, ["message": "rate limited"]))
        XCTAssertFalse(t.busy)
        guard case .error(let text) = t.items.last!.kind else { return XCTFail() }
        XCTAssertEqual(text, "rate limited")
    }

    func testBoxDrawingIsStripped() {
        let raw = "+-----+\n|  (^_^)? Available Commands  |\n+-----+\n  /new - start"
        XCTAssertEqual(HermesEngine.stripBoxDrawing(raw), "(^_^)? Available Commands\n  /new - start")
    }

    func testWebSocketFrameRoundTripsLengths() {
        for count in [0, 5, 125, 126, 300, 70_000] {
            let payload = Data((0..<count).map { UInt8($0 % 251) })
            let frame = TunnelWebSocket.frame(opcode: 1, payload: payload, mask: [1, 2, 3, 4])
            XCTAssertEqual(frame[0], 0x81)
            XCTAssertEqual(frame[1] & 0x80, 0x80, "client frames are masked")
            let header = count < 126 ? 2 : count <= 0xFFFF ? 4 : 10
            XCTAssertEqual(frame.count, header + 4 + count)
        }
        XCTAssertEqual(TunnelWebSocket.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testIdentityRoundTripAndAuthorizedKeysLine() throws {
        let id = SSHIdentity.generate()
        let restored = try SSHIdentity(rawRepresentation: id.rawRepresentation)
        XCTAssertEqual(id.authorizedKeysLine(), restored.authorizedKeysLine())
        XCTAssertTrue(id.authorizedKeysLine().hasPrefix("ssh-ed25519 AAAA"))
        XCTAssertTrue(id.authorizedKeysLine(comment: "phone").hasSuffix(" phone"))
        XCTAssertTrue(id.fingerprint.hasPrefix("SHA256:"))
    }

    func testShellQuoting() {
        XCTAssertEqual(RemoteBackend.shq("a'b"), "'a'\\''b'")
    }
}
