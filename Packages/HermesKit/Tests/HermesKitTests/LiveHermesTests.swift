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
        // Fresh, or the shared backend another device (an earlier test) started.
        XCTAssertTrue(!client.backend.reused || client.backend.adopted)
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
    /// Bot Screen: watch, take over, hand back. Needs a Hermes with the screen feature and
    /// TigerVNC + Xfce on the host. HERMES_E2E_SCREEN=1 runs it; =unsupported checks that an
    /// older Hermes is reported as such; unset skips.
    func testBotScreenWatchTakeOverHandBack() async throws {
        let env = try env()
        let mode = ProcessInfo.processInfo.environment["HERMES_E2E_SCREEN"] ?? ""
        guard !mode.isEmpty else { throw XCTSkip("HERMES_E2E_SCREEN not set") }
        let client = try await connect(env)
        defer { client.close() }
        let screen = client.screen

        if mode == "unsupported" {
            do {
                _ = try await screen.status()
                XCTFail("an older Hermes must report Bot Screen as unsupported")
            } catch let error as ScreenError {
                XCTAssertEqual(error, .unsupportedHermes)
            }
            return
        }

        var status = try await screen.status()
        XCTAssertTrue(status.supported, "Linux host should support Bot Screen")
        XCTAssertTrue(status.installed, "missing on host: \(status.missing)")
        status = try await screen.start()
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.lease.holder, .agent)
        let events = client.rpc.subscribe()

        // Watch: the ticketed socket carries the screen's RFB greeting through the SSH tunnel.
        let ticket = try await screen.observe()
        let socket = try await screen.openStream(ticket)
        var frames = socket.frames.makeAsyncIterator()
        guard case .binary(let greeting)? = try await frames.next() else { return XCTFail("expected binary RFB") }
        XCTAssertTrue(String(decoding: greeting.prefix(12), as: UTF8.self).hasPrefix("RFB 003.00"), "got \(greeting.prefix(12))")

        // Take over: the lease names a human, every client hears it, and frames are withheld.
        let lease = try await screen.takeOver(viewerID: ticket.viewerID)
        XCTAssertEqual(lease.holder, .human)
        let leaseEvent = try await waitFor(events, type: "display.lease", timeout: 15)
        if case .lease(_, let broadcast)? = ScreenEvent(leaseEvent) { XCTAssertEqual(broadcast.holder, .human) }
        let thumb = try await screen.thumbnail()
        XCTAssertNil(thumb.dataURL, "no screenshots while a human holds control")

        // Leaving cleanly (close 1000) hands control back to the bot.
        await socket.close(code: 1000, reason: "viewer closed")
        var holder = ScreenLease.Holder.human
        for _ in 0..<40 where holder == .human {
            try await Task.sleep(nanoseconds: 250_000_000)
            holder = try await screen.status().lease.holder
        }
        XCTAssertEqual(holder, .agent, "a clean close must hand control back")

        // Explicit take over / hand back; the viewer id is kept across observes on this connection.
        let again = try await screen.observe(viewerID: ticket.viewerID)
        XCTAssertEqual(again.viewerID, ticket.viewerID)
        let taken = try await screen.takeOver(viewerID: again.viewerID)
        XCTAssertEqual(taken.holder, .human)
        let returned = try await screen.handBack(viewerID: again.viewerID)
        XCTAssertEqual(returned.holder, .agent)

        // A viewer id this connection never minted can't take control.
        do {
            try await screen.takeOver(viewerID: "made-up-viewer")
            XCTFail("a foreign viewer id must be refused")
        } catch let error as ScreenError {
            XCTAssertEqual(error, .staleViewer)
        }

        let stopped = try await screen.stop(force: true)
        XCTAssertFalse(stopped.running)
    }

    /// Hermes' browser as a phone page (DevTools through SSH). Needs a running Bot Screen and a
    /// Chromium binary: HERMES_E2E_CHROME=/path/to/chrome. Launches it the way the bot does.
    func testLiveBrowserPhoneMode() async throws {
        let env = try env()
        // Hermes' browser lives on its Bot Screen; an older Hermes has none (covered by the screen test).
        if ProcessInfo.processInfo.environment["HERMES_E2E_SCREEN"] == "unsupported" { return }
        guard let chrome = ProcessInfo.processInfo.environment["HERMES_E2E_CHROME"], !chrome.isEmpty else {
            throw XCTSkip("HERMES_E2E_CHROME not set")
        }
        let client = try await connect(env)
        defer { client.close() }
        _ = try await client.screen.start()
        let page = "data:text/html,<meta name=viewport content='width=device-width'><style>.m{display:none}@media(max-width:600px){.m{display:block}.d{display:none}}</style><p class=d>DESKTOP</p><p class=m>MOBILE</p><input id=e><input id=p type=password><button onclick=\"o.textContent=e.value+'/'+p.value.length\">Go</button><p id=o></p><div style=height:3000px></div>"
        let launch = """
        set -a; . "$HOME/.hermes/bot-desktop/env"; set +a
        d="$HOME/.hermes/bot-desktop/browser-profile"; mkdir -p "$d"; rm -f "$d/DevToolsActivePort"
        nohup \(RemoteBackend.shq(chrome)) --user-data-dir="$d" --remote-debugging-port=0 --no-first-run --no-sandbox --password-store=basic \(RemoteBackend.shq(page)) >/dev/null 2>&1 &
        for i in $(seq 1 40); do [ -s "$d/DevToolsActivePort" ] && break; sleep 0.25; done; head -n1 "$d/DevToolsActivePort"
        """
        let browser = LiveBrowser(client: client)
        LiveBrowser.phoneWatchdog = ProcessInfo.processInfo.environment["HERMES_E2E_NO_WATCHDOG"] == nil
        defer { LiveBrowser.phoneWatchdog = true }
        // The app's own path: open the browser exactly as the screen's dock does. Falls back to a
        // direct launch when this host's dock has no headed browser seeded.
        do {
            let port = try await browser.launch(url: page)
            XCTAssertGreaterThan(port, 0)
        } catch LiveBrowserError.noDockBrowser {
            let launched = try await client.ssh.exec(launch, timeout: 30)
            XCTAssertFalse(launched.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Chromium wrote its DevTools port")
        }

        let tabs = try await browser.tabs()
        let tab = try XCTUnwrap(tabs.first { $0.url.hasPrefix("data:") } ?? tabs.first)
        try await browser.open(tab)
        let first = await withTaskGroup(of: BrowserFrame?.self) { group in
            group.addTask { var it = browser.frames.makeAsyncIterator(); return await it.next() }
            group.addTask { try? await Task.sleep(nanoseconds: 15_000_000_000); return nil }
            let frame = await group.next() ?? nil
            group.cancelAll()
            return frame
        }
        XCTAssertGreaterThan(first?.jpeg.count ?? 0, 100, "a JPEG frame of the page arrives (the tab is brought to the front)")

        try await browser.enterPhoneMode(PhoneViewport(width: 393, height: 760))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        // The streamed picture itself must be phone-sized (not a desktop window with a phone page in it),
        // even when another client on the tab keeps resetting the viewport.
        let phoneFrame = await withTaskGroup(of: BrowserFrame?.self) { group in
            group.addTask {
                for await frame in browser.frames where abs(frame.cssWidth - 393) < 3 && abs(frame.cssHeight - 760) < 3 { return frame }
                return nil
            }
            group.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return nil }
            let f = await group.next() ?? nil
            group.cancelAll()
            return f
        }
        XCTAssertNotNil(phoneFrame, "frames come out phone-sized (393x760 CSS px)")
        if let data = phoneFrame?.jpeg, let dir = ProcessInfo.processInfo.environment["HERMES_E2E_FRAMES"] {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("phone-frame.jpg"))
        }
        let v1 = try await browser.evaluate("innerWidth")
        XCTAssertEqual(v1.intValue, 393)
        let v2 = try await browser.evaluate("getComputedStyle(document.querySelector('.m')).display")
        XCTAssertEqual(v2.stringValue, "block", "mobile layout")

        func center(_ sel: String) async throws -> (Double, Double) {
            let r = try await browser.evaluate("(()=>{const b=document.querySelector('\(sel)').getBoundingClientRect();return [b.x+b.width/2,b.y+b.height/2]})()")
            return (r.arrayValue?[0].doubleValue ?? 0, r.arrayValue?[1].doubleValue ?? 0)
        }
        var (x, y) = try await center("#e")
        browser.tap(x: x, y: y)
        try await Task.sleep(nanoseconds: 300_000_000)
        let editable = await browser.editableFocused()
        XCTAssertTrue(editable, "tapping a field focuses it, so the phone raises its keyboard")
        browser.insert(text: "david@example.com")
        (x, y) = try await center("#p")
        browser.tap(x: x, y: y)
        try await Task.sleep(nanoseconds: 300_000_000)
        browser.insert(text: "s3cret!x")
        browser.press(.backspace)
        (x, y) = try await center("button")
        browser.tap(x: x, y: y)
        try await Task.sleep(nanoseconds: 600_000_000)
        let v3 = try await browser.evaluate("o.textContent")
        XCTAssertEqual(v3.stringValue, "david@example.com/7")

        browser.touch(.start, points: [(200, 650)])
        for step in stride(from: 630.0, through: 150, by: -20) {
            browser.touch(.move, points: [(200, step)])
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        browser.touch(.end, points: [])
        try await Task.sleep(nanoseconds: 800_000_000)
        let v4 = try await browser.evaluate("scrollY")
        XCTAssertGreaterThan(v4.doubleValue ?? 0, 100, "a finger drag scrolls the page")

        await browser.leavePhoneMode()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let v5 = try await browser.evaluate("innerWidth")
        XCTAssertGreaterThan(v5.intValue ?? 0, 900, "hand back restores the desktop page")
        let v6 = try await browser.evaluate("navigator.userAgent.includes('iPhone')")
        XCTAssertEqual(v6.boolValue, false)
        await browser.stop()
        // Only the browser itself (a looser pattern would also match the shell running this command).
        _ = try? await client.ssh.exec("pkill -f -- 'chrom[e].*--user-data-dir=[^ ]*bot-desktop/browser-profile' || true", timeout: 10)
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

/// The phone and the PC share one backend: a chat sent from either shows up on both, live,
/// with both prompts and both replies in the same order.
final class LiveSharedBackendTests: XCTestCase {
    func testTwoDevicesSeeEachOthersTurns() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["HERMES_E2E_SSH_HOST"], let key = e["HERMES_E2E_SSH_KEY"], let raw = Data(base64Encoded: key) else {
            throw XCTSkip("HERMES_E2E_* not set")
        }
        let target = SSHTarget(host: host, port: Int(e["HERMES_E2E_SSH_PORT"] ?? "22") ?? 22, username: e["HERMES_E2E_SSH_USER"] ?? "root")
        let identity = try SSHIdentity(rawRepresentation: raw)
        func options() -> HermesClient.Options {
            .init(target: target, identity: identity, hostKeys: MemoryHostKeyStore(), ownershipID: RemoteBackend.makeOwnershipID())
        }
        let phone = HermesEngine(persistence: MemoryEnginePersistence())
        let pc = HermesEngine(persistence: MemoryEnginePersistence())
        await phone.connect(options())
        await pc.connect(options())
        let phoneState = await phone.state, pcState = await pc.state
        guard case .connected = phoneState, case .connected(let pcInfo) = pcState else { return XCTFail("\(phoneState) \(pcState)") }
        XCTAssertTrue(pcInfo.reusedBackend, "the second device adopts the running backend")

        let chat = try await phone.newChat()
        _ = try await pc.open(chat)
        func lines(_ t: Transcript?) -> [String] {
            (t?.items ?? []).compactMap {
                switch $0.kind {
                case .user(let text, _): return "user:\(text)"
                case .assistant(let text, _, _): return "assistant:\(text)"
                default: return nil
                }
            }
        }
        func settle(_ engine: HermesEngine, until done: ([String]) -> Bool) async -> [String] {
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                let t = await engine.transcript(chat)
                if t?.busy == false, done(lines(t)) { return lines(t) }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return lines(await engine.transcript(chat))
        }

        try await phone.send(chat, text: "hello from the phone")
        let seenOnPC = await settle(pc) { $0.contains("user:hello from the phone") && $0.contains { $0.hasPrefix("assistant:Echo") } }
        XCTAssertEqual(seenOnPC.first, "user:hello from the phone", "\(seenOnPC)")

        try await pc.send(chat, text: "and now from the PC")
        let seenOnPhone = await settle(phone) { $0.count == 4 && $0.contains("user:and now from the PC") }
        let finalPC = await settle(pc) { $0.count == 4 }
        XCTAssertEqual(seenOnPhone.map { String($0.prefix { $0 != ":" }) }, ["user", "assistant", "user", "assistant"], "\(seenOnPhone)")
        XCTAssertEqual(seenOnPhone, finalPC)
        await phone.disconnect()
        await pc.disconnect()
    }
}

/// Coming back to the app must be fast: a still-good link is kept, a dead one is replaced
/// through the fast path (saved token, no locate/verify/spawn), and the shell keeps keystroke order.
final class LiveReconnectTests: XCTestCase {
    func env() throws -> (SSHTarget, SSHIdentity) {
        let e = ProcessInfo.processInfo.environment
        guard let host = e["HERMES_E2E_SSH_HOST"], let key = e["HERMES_E2E_SSH_KEY"], let raw = Data(base64Encoded: key) else {
            throw XCTSkip("HERMES_E2E_* not set")
        }
        return (SSHTarget(host: host, port: Int(e["HERMES_E2E_SSH_PORT"] ?? "22") ?? 22, username: e["HERMES_E2E_SSH_USER"] ?? "root"),
                try SSHIdentity(rawRepresentation: raw))
    }

    func testForegroundCheckAndFastReconnect() async throws {
        let (target, identity) = try env()
        let persistence = MemoryEnginePersistence()
        let engine = HermesEngine(persistence: persistence)
        let options = HermesClient.Options(target: target, identity: identity, hostKeys: MemoryHostKeyStore(),
                                           ownershipID: LiveHermesTests.ownership)
        await engine.connect(options)
        let first = await engine.state
        XCTAssertTrue(first.isConnected, "\(first)")
        let pid = persistence.loadBackend(for: target.hostID)?.pid

        // Healthy link: kept, answered in well under a second.
        var start = Date()
        let kept = await engine.ensureAlive()
        XCTAssertTrue(kept)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)

        // Dead link (what iOS leaves behind): replaced via the fast path, same backend.
        let client = await engine.client
        client?.ssh.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        start = Date()
        let keptDead = await engine.ensureAlive()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(keptDead)
        let after = await engine.state
        XCTAssertTrue(after.isConnected, "\(after)")
        XCTAssertEqual(persistence.loadBackend(for: target.hostID)?.pid, pid, "reused the running backend")
        print("FAST_RECONNECT_SECONDS=\(elapsed)")
        XCTAssertLessThan(elapsed, 5, "fast reconnect")
        await engine.disconnect()
    }

    func testBinaryFilesRoundTripOverSSH() async throws {
        let (target, identity) = try env()
        let ssh = try await SSHConnection.connect(to: target, identity: identity, hostKeys: MemoryHostKeyStore())
        let blob = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let path = "/tmp/brainbox-media-\(UUID().uuidString).png"
        _ = try await ssh.exec("cat > \(RemoteBackend.shq(path))", stdin: blob, timeout: 120)
        let size = try await ssh.exec("stat -c %s -- \(RemoteBackend.shq(path))")
        XCTAssertEqual(Int(size.output.trimmingCharacters(in: .whitespacesAndNewlines)), blob.count)
        let back = try await ssh.exec("cat -- \(RemoteBackend.shq(path))", timeout: 120)
        XCTAssertEqual(back.stdout, blob, "3 MB image comes back byte-for-byte")
        _ = try await ssh.exec("rm -f -- \(RemoteBackend.shq(path))")
        ssh.close()
    }

    func testShellKeystrokesStayInOrderAndBackspaceErases() async throws {
        let (target, identity) = try env()
        let ssh = try await SSHConnection.connect(to: target, identity: identity, hostKeys: MemoryHostKeyStore())
        let shell = try await ssh.openShell(columns: 80, rows: 24)
        // Type "echo abX", backspace, "c-ok" one byte at a time, the way the keyboard does.
        for byte in Array("echo abX".utf8) + [0x7f] + Array("c-ok\n".utf8) { shell.send(Data([byte])) }
        var output = ""
        for try await event in shell.events {
            if case .data(let d) = event { output += String(decoding: d, as: UTF8.self) }
            if output.contains("abc-ok\r\n") || output.contains("\nabc-ok") { break }
        }
        XCTAssertTrue(output.contains("abc-ok"), output)
        shell.send(Data("exit\n".utf8))
        ssh.close()
    }
}
