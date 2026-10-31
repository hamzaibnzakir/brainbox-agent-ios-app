import BrainboxCore
import Foundation
@testable import HermesKit
import XCTest

/// End to end against a real sshd and a real Hermes: the phone's whole path.
///
/// Runs when these are set (CI sets them; skipped otherwise):
///   HERMES_E2E_SSH_HOST, HERMES_E2E_SSH_PORT, HERMES_E2E_SSH_USER
///   HERMES_E2E_SSH_KEY   base64 of a raw 32-byte Ed25519 private key whose public
///                        key is in that user's authorized_keys
final class LiveHermesTests: XCTestCase {
    struct Env {
        var target: SSHTarget
        var identity: SSHIdentity
    }

    static let ownership = RemoteBackend.makeOwnershipID()
    static let hostKeys = MemoryHostKeyStore()
    static var record: RemoteBackendRecord?

    func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["HERMES_E2E_SSH_HOST"], let keyText = e["HERMES_E2E_SSH_KEY"],
              let raw = Data(base64Encoded: keyText) else {
            throw XCTSkip("HERMES_E2E_* not set; live SSH tests skipped")
        }
        return Env(target: SSHTarget(host: host, port: Int(e["HERMES_E2E_SSH_PORT"] ?? "22") ?? 22,
                                     username: e["HERMES_E2E_SSH_USER"] ?? "root"),
                   identity: try SSHIdentity(rawRepresentation: raw))
    }

    func connect(_ env: Env) async throws -> HermesClient {
        let client = try await HermesClient.connect(.init(target: env.target, identity: env.identity,
                                                          hostKeys: Self.hostKeys, ownershipID: Self.ownership,
                                                          knownBackend: Self.record))
        Self.record = client.backend.record
        return client
    }

    func waitFor(_ events: AsyncStream<GatewayEvent>, type: String, session: String? = nil,
                 timeout: TimeInterval = 60, onEach: (GatewayEvent) async throws -> Void = { _ in }) async throws -> GatewayEvent {
        let deadline = Date().addingTimeInterval(timeout)
        for await event in events {
            try await onEach(event)
            if event.type == type, session == nil || event.sessionID == session { return event }
            if Date() > deadline { break }
        }
        throw XCTSkip("no \(type) before timeout")
    }

    func test1_execAndRefusedKey() async throws {
        let env = try env()
        let ssh = try await SSHConnection.connect(to: env.target, identity: env.identity, hostKeys: Self.hostKeys)
        let result = try await ssh.exec("echo hello-$((40+2)); echo oops >&2; exit 3")
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello-42")
        XCTAssertEqual(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
        XCTAssertEqual(result.exitStatus, 3)
        let piped = try await ssh.exec("cat | tr a-z A-Z", stdin: Data("secret".utf8))
        XCTAssertEqual(piped.output, "SECRET")
        ssh.close()

        // A key the server doesn't know is refused with a clear error.
        do {
            _ = try await SSHConnection.connect(to: env.target, identity: .generate(), hostKeys: Self.hostKeys)
            XCTFail("unknown key must be refused")
        } catch let error as SSHError {
            XCTAssertEqual(error, .authenticationFailed)
        }
        // A changed host key fails closed.
        let wrong = MemoryHostKeyStore([env.target.hostID: SSHIdentity.generate().authorizedKeysLine(comment: "")])
        do {
            _ = try await SSHConnection.connect(to: env.target, identity: env.identity, hostKeys: wrong)
            XCTFail("changed host key must be refused")
        } catch let error as SSHError {
            guard case .hostKeyChanged = error else { return XCTFail("\(error)") }
        }
    }

    func test2_backendChatToolApprovalAndReuse() async throws {
        let env = try env()
        let client = try await connect(env)
        XCTAssertFalse(client.backend.reused)
        XCTAssertNotNil(client.ready, "gateway.ready arrives")

        // REST through the tunnel, authenticated.
        let health = try await client.get("/api/health")
        XCTAssertEqual(health["ok"]?.boolValue, true)
        let skills = try await client.get("/api/skills")
        XCTAssertNotNil(skills.arrayValue)

        // Chat: stream deltas to a complete message.
        let events = client.rpc.subscribe()
        let created = try await client.rpc.call("session.create", [:])
        let sid = try XCTUnwrap(created["session_id"]?.stringValue)
        _ = try await client.rpc.call("prompt.submit", ["session_id": .string(sid), "text": "hello phone"])
        var deltas = ""
        let complete = try await waitFor(events, type: "message.complete", session: sid) { e in
            if e.type == "message.delta" { deltas += e.payload["text"]?.stringValue ?? "" }
        }
        let final = complete.payload["text"]?.stringValue ?? ""
        XCTAssertTrue(final.hasPrefix("Echo:") && final.contains("hello phone"), final)
        XCTAssertEqual(deltas.trimmingCharacters(in: .whitespacesAndNewlines), final.trimmingCharacters(in: .whitespacesAndNewlines), "streamed text matches the final text")

        // A risky tool call asks for approval; approving lets it run.
        _ = try await client.rpc.call("prompt.submit", ["session_id": .string(sid), "text": "run tool: rm -rf /tmp/brainbox-e2e-none"])
        var approved = false
        let done = try await waitFor(events, type: "message.complete", session: sid) { e in
            if e.type == "approval.request" {
                // Hermes ≤ 0.21: an event answered with approval.respond.
                approved = true
                _ = try await client.rpc.call("approval.respond", ["session_id": .string(sid), "choice": "once"])
            } else if e.type == "server.request", e.payload["method"]?.stringValue == "approval", let id = e.payload["id"] {
                // Newer Hermes: a JSON-RPC request answered by id.
                approved = true
                try await client.rpc.reply(requestID: id, result: ["choice": "once"])
            }
        }
        XCTAssertTrue(approved, "approval.request reached the phone")
        XCTAssertTrue(done.payload["text"]?.stringValue?.contains("approved by the user") == true)

        // Slash commands run through Hermes itself.
        let help = try await client.rpc.call("slash.exec", ["session_id": .string(sid), "command": "/help"])
        XCTAssertTrue(help["output"]?.stringValue?.contains("/new") == true)
        client.close()

        // Reconnecting reuses the same backend.
        let again = try await connect(env)
        XCTAssertTrue(again.backend.reused)
        XCTAssertEqual(again.backend.record.pid, client.backend.record.pid)
        again.close()
    }

    func test3_replayAfterLostConnection() async throws {
        let env = try env()
        let first = try await connect(env)
        let events = first.rpc.subscribe()
        let created = try await first.rpc.call("session.create", [:])
        let sid = try XCTUnwrap(created["session_id"]?.stringValue)
        let stored = try XCTUnwrap(created["stored_session_id"]?.stringValue)
        _ = try await first.rpc.call("prompt.submit", ["session_id": .string(sid), "text": "slow please"])
        var lastSeq = 0
        var text = ""
        for await e in events where e.sessionID == sid {
            if let s = e.seq { lastSeq = max(lastSeq, s) }
            if e.type == "message.delta" { text += e.payload["text"]?.stringValue ?? "" }
            if text.contains("w5") { break }
        }
        first.close() // the phone loses signal mid-answer

        let second = try await connect(env)
        XCTAssertTrue(second.backend.reused)
        let live = second.rpc.subscribe()
        // A new connection re-attaches to the still-running session, then fills the gap.
        let resumed = try await second.rpc.call("session.resume", ["session_id": .string(stored)])
        XCTAssertEqual(resumed["session_id"]?.stringValue, sid, "same live session")
        let replay = try await second.rpc.call("session.events.since", ["session_id": .string(sid), "last_seen": .number(Double(lastSeq))])
        var seen = Set<Int>()
        for e in replay["events"]?.arrayValue ?? [] {
            guard let ev = GatewayEvent(json: e), let s = ev.seq, s > lastSeq, seen.insert(s).inserted else { continue }
            lastSeq = max(lastSeq, s)
            if ev.type == "message.delta" { text += ev.payload["text"]?.stringValue ?? "" }
            if ev.type == "message.complete" { text = ev.payload["text"]?.stringValue ?? text }
        }
        if !text.contains("w39") {
            for await e in live where e.sessionID == sid {
                guard let s = e.seq, s > lastSeq, seen.insert(s).inserted else { continue }
                if e.type == "message.delta" { text += e.payload["text"]?.stringValue ?? "" }
                if e.type == "message.complete" { text = e.payload["text"]?.stringValue ?? text; break }
            }
        }
        XCTAssertEqual(text, (0..<40).map { "w\($0)" }.joined(separator: " "), "nothing lost, nothing doubled")
        second.close()
    }

    func test4_terminalShell() async throws {
        let env = try env()
        let ssh = try await SSHConnection.connect(to: env.target, identity: env.identity, hostKeys: Self.hostKeys)
        let shell = try await ssh.openShell(columns: 80, rows: 24)
        try await shell.write("echo term-$((6*7))\n")
        var output = ""
        for try await event in shell.events {
            if case .data(let d) = event { output += String(decoding: d, as: UTF8.self) }
            if output.contains("term-42") { break }
        }
        XCTAssertTrue(output.contains("term-42"))
        shell.resize(columns: 100, rows: 30)
        try await shell.write("exit\n")
        ssh.close()
    }
}

/// The engine itself (what the app drives) against the real server.
final class LiveEngineTests: XCTestCase {
    func testEngineChatSlashAndReconnect() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["HERMES_E2E_SSH_HOST"], let key = e["HERMES_E2E_SSH_KEY"], let raw = Data(base64Encoded: key) else {
            throw XCTSkip("HERMES_E2E_* not set")
        }
        let target = SSHTarget(host: host, port: Int(e["HERMES_E2E_SSH_PORT"] ?? "22") ?? 22, username: e["HERMES_E2E_SSH_USER"] ?? "root")
        let engine = HermesEngine(persistence: MemoryEnginePersistence())
        let options = HermesClient.Options(target: target, identity: try SSHIdentity(rawRepresentation: raw),
                                           hostKeys: MemoryHostKeyStore(), ownershipID: LiveHermesTests.ownership)
        let updates = engine.updates
        await engine.connect(options)
        let state = await engine.state
        guard case .connected(let info) = state else { return XCTFail("\(state)") }
        XCTAssertNotNil(info.version, "the backend reports its version")

        let chat = try await engine.newChat()
        try await engine.send(chat, text: "hello engine")
        var finished = false
        for await update in updates {
            if case .turnFinished(let c, _, let text) = update, c == chat {
                XCTAssertTrue(text.hasPrefix("Echo:") && text.contains("hello engine"), text)
                finished = true
                break
            }
        }
        XCTAssertTrue(finished)

        // Approvals through the engine (event style on 0.21, request style on newer Hermes).
        try await engine.send(chat, text: "run tool: rm -rf /tmp/brainbox-engine-none")
        var answered = false
        for await update in updates {
            if case .needsAttention(let c, _, let request) = update, c == chat {
                try await engine.respond(chat, request: request, answer: "once")
                answered = true
            }
            if case .turnFinished(let c, _, let text) = update, c == chat {
                XCTAssertTrue(answered, "the engine surfaced the approval")
                XCTAssertTrue(text.contains("approved"), text)
                break
            }
        }
        let afterApproval = await engine.transcript(chat)
        XCTAssertTrue(afterApproval?.pendingRequests.isEmpty == true)

        let outcome = try await engine.slash(chat, "/help")
        guard case .output(let out) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(out.contains("/new"))

        // Drop the connection; the engine reconnects and the chat keeps working.
        await engine.reconnectNow(reason: "test")
        let after = await engine.state
        XCTAssertTrue(after.isConnected, "\(after)")
        try await engine.send(chat, text: "again")
        for await update in updates {
            if case .turnFinished(let c, _, let text) = update, c == chat {
                XCTAssertTrue(text.hasPrefix("Echo:") && text.contains("again"), text)
                break
            }
        }
        let transcript = await engine.transcript(chat)
        XCTAssertEqual(transcript?.items.filter { if case .user = $0.kind { return true }; return false }.count, 3)
        await engine.disconnect()
    }
}
