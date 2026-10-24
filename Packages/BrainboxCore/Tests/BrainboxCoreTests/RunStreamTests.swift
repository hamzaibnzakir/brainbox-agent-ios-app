import XCTest
@testable import BrainboxCore

/// Controllable clock: time moves only when the test says so.
final class ManualClock: RunClock, @unchecked Sendable {
    private struct Sleeper { var deadline: Date; var continuation: CheckedContinuation<Void, Error> }
    private let state = Locked<(now: Date, sleepers: [Sleeper])>((Date(timeIntervalSince1970: 1_000_000), []))

    func now() -> Date { state.withLock { $0.now } }

    func sleep(seconds: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.withLock { $0.sleepers.append(Sleeper(deadline: $0.now.addingTimeInterval(seconds), continuation: continuation)) }
        }
    }

    var sleepers: Int { state.withLock { $0.sleepers.count } }

    deinit {
        for sleeper in state.withLock({ $0.sleepers }) { sleeper.continuation.resume(throwing: CancellationError()) }
    }

    func advance(_ seconds: Double) {
        let due = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            s.now = s.now.addingTimeInterval(seconds)
            let now = s.now
            let ready = s.sleepers.filter { $0.deadline <= now }.map(\.continuation)
            s.sleepers.removeAll { $0.deadline <= now }
            return ready
        }
        due.forEach { $0.resume() }
    }
}

/// A stream that yields `chunks`, then stays open until `release` is set (or finishes/fails).
final class ScriptedStream: @unchecked Sendable {
    let released = Locked<String?>(nil)   // final chunk to send, then close
    let failNow = Locked(false)

    func response(_ chunks: [String], holdOpen: Bool = true) -> HTTPStreamResponse {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
                while holdOpen && !Task.isCancelled {
                    if let last = self.released.current { continuation.yield(Data(last.utf8)); break }
                    if self.failNow.current { continuation.finish(throwing: URLError(.networkConnectionLost)); return }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: stream)
    }
}

private func relay(_ seq: Int, _ json: String) -> String { "id: \(seq)\ndata: \(json)\n\n" }

final class RunStreamTests: XCTestCase {
    private func server(_ runIDs: [String] = ["run_42"]) -> MockHTTPTransport {
        let transport = MockHTTPTransport()
        let counter = Locked(0)
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"session":{"id":"ios_x"}}"#, status: 201) }
        transport.on("POST /hermes/v1/runs") { _ in
            let n = counter.withLock { $0 += 1; return $0 - 1 }
            return MockHTTPTransport.json(#"{"run_id":"\#(runIDs[min(n, runIDs.count - 1)])","status":"started"}"#, status: 202)
        }
        return transport
    }

    private func text(_ events: [AgentEvent]) -> String {
        var message = Message(role: .assistant, content: "", state: .sending)
        for event in events { ChatReducer.apply(event, to: &message) }
        return message.plainText
    }

    // MARK: resume through the relay

    func testRelayResumeAfterDropHasNoGapsOrDuplicates() async throws {
        let transport = server()
        let headers = Locked<[String?]>([])
        transport.onStream("GET /hermes/v1/runs/run_42/events") { request in
            let last = request.headers["Last-Event-ID"]
            let n = headers.withLock { $0.append(last); return $0.count }
            if n == 1 {
                return MockHTTPTransport.sse([
                    relay(1, #"{"event":"brainbox.upstream","run_id":"run_42","state":"live"}"#),
                    relay(2, #"{"event":"message.delta","run_id":"run_42","delta":"Hel"}"#),
                    relay(3, #"{"event":"message.delta","run_id":"run_42","delta":"lo"}"#),
                ], failAtEnd: URLError(.networkConnectionLost))
            }
            // The relay resumes after 3; repeat 3 to prove duplicates are dropped.
            return MockHTTPTransport.sse([
                relay(3, #"{"event":"message.delta","run_id":"run_42","delta":"lo"}"#),
                relay(4, #"{"event":"tool.started","run_id":"run_42","tool":"terminal","preview":"ls"}"#),
                relay(5, #"{"event":"tool.completed","run_id":"run_42","tool":"terminal","duration":0.2,"error":false}"#),
                relay(6, #"{"event":"message.delta","run_id":"run_42","delta":" world"}"#),
                relay(7, #"{"event":"run.completed","run_id":"run_42","output":"Hello world"}"#),
            ])
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "hi")))
        XCTAssertEqual(text(events), "Hello\n\n world")
        XCTAssertEqual(events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }, ["Hel", "lo", " world"])
        XCTAssertEqual(headers.current, [nil, "3"])
        XCTAssertTrue(transport.requests(matching: "GET /hermes/v1/runs/run_42").isEmpty, "resumed live, never fell back to polling")
        guard case .completed? = events.last else { return XCTFail("\(events)") }
    }

    func testEventsForAnotherRunAreDropped() async throws {
        let transport = server()
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            MockHTTPTransport.sse([
                relay(1, #"{"event":"message.delta","run_id":"run_42","delta":"mine"}"#),
                relay(2, #"{"event":"message.delta","run_id":"run_old","delta":" STALE"}"#),
                relay(3, #"{"event":"run.completed","run_id":"run_42","output":"mine"}"#),
            ])
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "hi")))
        XCTAssertEqual(text(events), "mine")
    }

    func testSnapshotDeliversEvictedTextOnce() async throws {
        let transport = server()
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            MockHTTPTransport.sse([
                relay(40, #"{"event":"brainbox.snapshot","run_id":"run_42","seq":40,"text":"Long start "}"#),
                relay(41, #"{"event":"message.delta","run_id":"run_42","delta":"and end"}"#),
                relay(42, #"{"event":"run.completed","run_id":"run_42","output":"Long start and end"}"#),
            ])
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "hi")))
        XCTAssertEqual(text(events), "Long start and end")
    }

    func testResumeAfterRelaunchShowsOnlyUnseenText() async throws {
        let transport = MockHTTPTransport()
        transport.onStream("GET /hermes/v1/runs/run_9/events") { _ in
            MockHTTPTransport.sse([
                relay(1, #"{"event":"message.delta","run_id":"run_9","delta":"Hel"}"#),
                relay(2, #"{"event":"message.delta","run_id":"run_9","delta":"lo"}"#),
                relay(3, #"{"event":"message.delta","run_id":"run_9","delta":" again"}"#),
                relay(4, #"{"event":"run.completed","run_id":"run_9","output":"Hello again"}"#),
            ])
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let events = try await collect(provider.resume(runID: "run_9", alreadyStreamed: "Hello"))
        XCTAssertEqual(events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }, [" again"])
    }

    func testPlainHermesDropFallsBackToStatusWithoutRetryingTheStream() async throws {
        let transport = server()
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            MockHTTPTransport.sse([HermesFixtures.event(#"{"event":"message.delta","delta":"Working"}"#)],
                                  failAtEnd: URLError(.networkConnectionLost))
        }
        transport.on("GET /hermes/v1/runs/run_42") { _ in
            MockHTTPTransport.json(#"{"object":"hermes.run","run_id":"run_42","status":"completed","output":"Working — done"}"#)
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "hi")))
        XCTAssertEqual(transport.requests(matching: "GET /hermes/v1/runs/run_42/events").count, 1,
                       "Hermes deletes the queue on disconnect; re-subscribing can't work")
        XCTAssertEqual(text(events), "Working — done")
        let transports = events.compactMap { if case .liveness(let l) = $0 { return l.transport } else { return nil } }
        XCTAssertTrue(transports.contains(.polling))
    }

    // MARK: silence detection with a controllable clock

    func testSilenceWarningAppearsAfterThreeMinutesWithoutEventsAndHeartbeatsDontReset() async throws {
        let clock = ManualClock()
        let transport = server()
        let script = ScriptedStream()
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            script.response([HermesFixtures.event(#"{"event":"message.delta","run_id":"run_42","delta":"Starting"}"#)])
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in }, clock: clock,
                                           silenceThreshold: 180, watchdogInterval: 5, stallTimeout: 100_000)
        let events = Locked<[AgentEvent]>([])
        let consumer = Task {
            for try await event in provider.send(AgentRequest(conversationID: UUID(), content: "long job")) {
                events.withLock { $0.append(event) }
            }
        }
        func latest() -> RunLiveness? {
            events.current.reversed().lazy.compactMap { if case .liveness(let l) = $0 { return l } else { return nil } }.first
        }
        await pollUntil { latest()?.phase == .responding && clock.sleepers >= 1 }
        XCTAssertNil(latest()?.silentSince)

        for _ in 0..<35 {  // 175 s
            clock.advance(5)
            await pollUntil { clock.sleepers >= 1 }
        }
        XCTAssertNil(latest()?.silentSince, "no warning before 3 minutes")
        clock.advance(5)  // 180 s
        await pollUntil { latest()?.silentSince != nil }
        let warned = try XCTUnwrap(latest())
        XCTAssertNotNil(warned.silentSince)
        let warning = try XCTUnwrap(warned.silenceWarning(now: clock.now()))
        XCTAssertTrue(warning.hasPrefix("No response received for 3 minutes"), warning)
        XCTAssertTrue(warning.contains("connection is fine"), "the link is up; it says so instead of claiming a failure")
        XCTAssertFalse(events.current.contains { if case .failed = $0 { return true } else { return false } })

        script.released.withLock { $0 = HermesFixtures.event(#"{"event":"run.completed","run_id":"run_42","output":"Starting… done"}"#) }
        _ = try await consumer.value
        guard case .completed? = events.current.last else { return XCTFail("\(events.current)") }
    }

    func testStalledRelaySocketIsReopenedFromTheCursor() async throws {
        let clock = ManualClock()
        let transport = server()
        let script = ScriptedStream()
        let lastIDs = Locked<[String?]>([])
        transport.onStream("GET /hermes/v1/runs/run_42/events") { request in
            let n = lastIDs.withLock { $0.append(request.headers["Last-Event-ID"]); return $0.count }
            if n == 1 { return script.response([relay(1, #"{"event":"message.delta","run_id":"run_42","delta":"a"}"#)]) }
            return MockHTTPTransport.sse([relay(2, #"{"event":"run.completed","run_id":"run_42","output":"ab"}"#)])
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in }, clock: clock,
                                           silenceThreshold: 180, watchdogInterval: 5, stallTimeout: 45)
        let consumer = Task { try await self.collect(provider.send(AgentRequest(conversationID: UUID(), content: "x")), timeout: 10) }
        await pollUntil { lastIDs.current.count == 1 && clock.sleepers >= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<10 {   // 50 s of a silent socket: no heartbeat, no event
            clock.advance(5)
            await pollUntil { clock.sleepers >= 1 || lastIDs.current.count > 1 }
        }
        let events = try await consumer.value
        XCTAssertEqual(lastIDs.current, [nil, "1"])
        XCTAssertEqual(text(events), "ab")
    }

    // MARK: isolation

    func testStoppingOneRunDoesNotTouchAnother() async throws {
        let transport = server(["run_a", "run_b"])
        let scripts = ["run_a": ScriptedStream(), "run_b": ScriptedStream()]
        for (id, script) in scripts {
            transport.onStream("GET /hermes/v1/runs/\(id)/events") { _ in
                script.response([relay(1, #"{"event":"message.delta","run_id":"\#(id)","delta":"\#(id)"}"#)])
            }
        }
        transport.on("POST /hermes/v1/runs/run_a/stop") { _ in
            scripts["run_a"]!.released.withLock { $0 = relay(2, #"{"event":"run.cancelled","run_id":"run_a"}"#) }
            return MockHTTPTransport.json(#"{"run_id":"run_a","status":"stopping"}"#)
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let requestA = AgentRequest(conversationID: UUID(), content: "a")
        let a = Task { try await self.collect(provider.send(requestA)) }
        await pollUntil { provider.runID(for: requestA.requestID) != nil }
        let requestB = AgentRequest(conversationID: UUID(), content: "b")
        let b = Task { try await self.collect(provider.send(requestB)) }
        await pollUntil { provider.runID(for: requestB.requestID) != nil }

        _ = await provider.requestStop(requestID: requestA.requestID)
        let eventsA = try await a.value
        guard case .failed(.cancelled)? = eventsA.last else { return XCTFail("\(eventsA)") }
        XCTAssertNotNil(provider.runID(for: requestB.requestID), "run B is still attached")
        XCTAssertTrue(transport.requests(matching: "POST /hermes/v1/runs/run_b/stop").isEmpty)

        scripts["run_b"]!.released.withLock { $0 = relay(2, #"{"event":"run.completed","run_id":"run_b","output":"run_b"}"#) }
        let eventsB = try await b.value
        guard case .completed? = eventsB.last else { return XCTFail("\(eventsB)") }
    }
}

final class RunTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)

    func testPhasesFollowRealEvents() {
        var tracker = RunTracker(startedAt: t0)
        XCTAssertEqual(tracker.liveness.phase, .connecting)
        XCTAssertTrue(tracker.accepted(at: t0))
        XCTAssertEqual(tracker.liveness.phase, .started)
        _ = tracker.observe(.toolStarted(tool: "terminal", preview: nil), at: t0 + 1)
        XCTAssertEqual(tracker.liveness.label, "Running `terminal`")
        _ = tracker.observe(.toolStarted(tool: "web_search", preview: nil), at: t0 + 2)
        _ = tracker.observe(.toolCompleted(tool: "web_search", duration: 1, isError: false), at: t0 + 3)
        XCTAssertEqual(tracker.liveness.toolName, "terminal", "still waiting on the first tool")
        _ = tracker.observe(.toolCompleted(tool: "terminal", duration: 1, isError: false), at: t0 + 4)
        XCTAssertEqual(tracker.liveness.phase, .working)
        _ = tracker.observe(.messageDelta("x"), at: t0 + 5)
        XCTAssertEqual(tracker.liveness.phase, .responding)
        _ = tracker.observe(.approvalRequest(HermesApprovalRequest(command: "rm")), at: t0 + 6)
        XCTAssertEqual(tracker.liveness.phase, .waitingForApproval)
        XCTAssertFalse(tracker.tick(now: t0 + 1_000), "waiting on the user is not silence")
        _ = tracker.observe(.completed(output: nil, usage: nil, pendingSteer: nil), at: t0 + 7)
        XCTAssertEqual(tracker.liveness.phase, .completed)
        XCTAssertFalse(tracker.tick(now: t0 + 10_000))
    }

    func testHeartbeatsProveTheLinkButNotProgress() {
        var tracker = RunTracker(startedAt: t0, silenceThreshold: 180)
        _ = tracker.observe(.messageDelta("a"), at: t0)
        for t in stride(from: 15.0, through: 175, by: 15) {
            _ = tracker.heartbeat(RelayHeartbeat(upstream: "live", hermesStatus: "running"), at: t0 + t)
        }
        XCTAssertEqual(tracker.liveness.lastEventAt, t0, "heartbeats never move lastEventAt")
        XCTAssertFalse(tracker.tick(now: t0 + 179))
        XCTAssertTrue(tracker.tick(now: t0 + 180))
        XCTAssertEqual(tracker.liveness.silentSince, t0 + 180)
        _ = tracker.heartbeat(RelayHeartbeat(), at: t0 + 190)
        XCTAssertNotNil(tracker.liveness.silentSince, "a heartbeat doesn't clear the warning")
        XCTAssertTrue(tracker.observe(.messageDelta("b"), at: t0 + 200))
        XCTAssertNil(tracker.liveness.silentSince, "a real event does")
    }

    func testWarningWordingMatchesWhatIsKnown() {
        var tracker = RunTracker(startedAt: t0, silenceThreshold: 180)
        _ = tracker.observe(.toolStarted(tool: "terminal", preview: nil), at: t0)
        _ = tracker.tick(now: t0 + 240)
        XCTAssertEqual(tracker.liveness.silenceWarning(now: t0 + 240)?.hasPrefix("No response received for 4 minutes while `terminal` runs"), true)
        _ = tracker.disconnected()
        XCTAssertTrue(tracker.liveness.silenceWarning(now: t0 + 240)?.contains("connection to the server is down") ?? false)
        XCTAssertTrue(tracker.liveness.silenceWarning(now: t0 + 240)?.contains("not a confirmed failure") ?? false)
        _ = tracker.reconnecting(attempt: 3)
        XCTAssertEqual(tracker.liveness.transportLabel, "Reconnecting (attempt 3)")
    }

    func testRelayFrameParsing() {
        let beat = HermesRunFrame.parse(SSEEvent(event: "brainbox.heartbeat",
            data: #"{"event":"brainbox.heartbeat","run_id":"r","last_seq":4,"upstream":"live","hermes_status":"running"}"#))
        XCTAssertEqual(beat?.seq, nil)
        XCTAssertEqual(beat?.kind, .heartbeat(RelayHeartbeat(lastSeq: 4, upstream: "live", hermesStatus: "running")))
        let status = HermesRunFrame.parse(SSEEvent(data: #"{"event":"run.completed","run_id":"r","seq":9,"source":"status","output":"x"}"#, id: "9"))
        XCTAssertEqual(status?.seq, 9)
        XCTAssertEqual(status?.fromStatus, true)
        XCTAssertEqual(status?.runID, "r")
    }

    func testReducerIgnoresLivenessAfterTheReplySettles() {
        var message = Message(role: .assistant, content: "", state: .streaming)
        ChatReducer.apply(.liveness(RunLiveness(phase: .responding, startedAt: t0)), to: &message)
        XCTAssertEqual(message.liveness?.phase, .responding)
        ChatReducer.apply(.completed, to: &message)
        XCTAssertNil(message.liveness)
        ChatReducer.apply(.liveness(RunLiveness(phase: .responding, startedAt: t0)), to: &message)
        XCTAssertNil(message.liveness, "a stale status after completion is ignored")
    }

    func testClientNoteTellsHermesTheClientRendersMarkdown() {
        XCTAssertTrue(HermesClientNote.text.contains("renders standard Markdown"))
        XCTAssertEqual(HermesClientNote.compose(nil), HermesClientNote.text)
        XCTAssertEqual(HermesClientNote.compose("Be terse."), HermesClientNote.text + "\n\nBe terse.")
    }

    func testParityReportNamesRemainingDifferences() throws {
        let json = #"{"toolsets":{"telegram":["a"],"api_server":[],"only_telegram":["clarify","tts"],"only_api_server":[],"explicit_telegram":false,"explicit_api_server":false},"model":"m","persona_prompt_chars":40,"provider_routing":true,"prefill_messages":0,"fallback_chain":1,"gateway_prompt_applied":true}"#
        let report = try JSONDecoder().decode(HermesParityReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.remainingDifferences.count, 2)
        XCTAssertTrue(report.remainingDifferences[0].contains("clarify, tts"))
        let features = try JSONDecoder().decode(BrainboxFeatures.self, from: Data(#"{"run_relay":true,"command_exec":true,"parity":true}"#.utf8))
        XCTAssertTrue(features.runRelay && features.commandExec && features.parity)
        XCTAssertFalse(try JSONDecoder().decode(BrainboxFeatures.self, from: Data("{}".utf8)).runRelay, "older proxies")
    }
}
