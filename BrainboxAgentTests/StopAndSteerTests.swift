import XCTest
import BrainboxCore
@testable import BrainboxAgent

/// Stop and steering against a scripted Hermes whose event stream the test
/// drives by hand, so every race (stop before/after completion, failed stop,
/// silent server, queue/interrupt ordering) is deterministic. Synthetic data;
/// no network.
@MainActor
final class StopAndSteerTests: XCTestCase {
    /// An SSE stream the test feeds event by event.
    final class ScriptedStream: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        private var buffered: [String] = []

        func response() -> HTTPStreamResponse {
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                self.lock.lock()
                self.continuation = continuation
                let pending = self.buffered
                self.buffered = []
                self.lock.unlock()
                for chunk in pending { continuation.yield(Data(chunk.utf8)) }
            }
            return HTTPStreamResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: stream)
        }

        func send(_ event: String) {
            let chunk = "data: \(event)\n\n"
            lock.lock()
            if let continuation { lock.unlock(); continuation.yield(Data(chunk.utf8)) } else { buffered.append(chunk); lock.unlock() }
        }

        func end() {
            lock.lock(); let c = continuation; lock.unlock()
            c?.finish()
        }
    }

    private struct Harness {
        let store: ChatStore
        let transport: MockHTTPTransport
        let streams: Locked<[String: ScriptedStream]>
        let runInputs: Locked<[String]>
    }

    private func makeHarness(stopStatus: Int = 200, stopBody: String = #"{"run_id":"x","status":"stopping"}"#) -> Harness {
        let transport = MockHTTPTransport()
        let counter = Locked(0)
        let streams = Locked<[String: ScriptedStream]>([:])
        let inputs = Locked<[String]>([])
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"session":{"id":"ios_x","source":"api_server"}}"#, status: 201) }
        transport.on("POST /hermes/v1/runs") { request in
            let n = counter.withLock { $0 += 1; return $0 }
            let id = "run_\(n)"
            streams.withLock { $0[id] = ScriptedStream() }
            let body = (try? JSONDecoder().decode(JSONValue.self, from: request.body ?? Data()))?["input"]?.stringValue ?? ""
            inputs.withLock { $0.append(body) }
            return MockHTTPTransport.json(#"{"run_id":"\#(id)","status":"started"}"#, status: 202)
        }
        for n in 1...4 {
            let id = "run_\(n)"
            transport.onStream("GET /hermes/v1/runs/\(id)/events") { _ in
                streams.withLock { $0[id] }!.response()
            }
            transport.on("POST /hermes/v1/runs/\(id)/stop") { _ in MockHTTPTransport.json(stopBody, status: stopStatus) }
            transport.on("GET /hermes/v1/runs/\(id)") { _ in MockHTTPTransport.json(#"{"run_id":"\#(id)","status":"running"}"#) }
        }
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!, pollInterval: 0.01),
                                     transport: transport, tokenProvider: { "device-token-0123456789" })
        let provider = HermesAgentProvider(client: client, pause: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        let store = ChatStore(store: InMemoryConversationStore(), provider: { provider }, isOnline: { true })
        return Harness(store: store, transport: transport, streams: streams, runInputs: inputs)
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func reply(_ h: Harness) -> Message? { h.store.current?.messages.last }
    private func stream(_ h: Harness, _ id: String) -> ScriptedStream? { h.streams.withLock { $0[id] } }

    private func startRun(_ h: Harness, text: String = "do the long thing") async throws {
        h.store.send(text)
        try await until("run started") { reply(h)?.runID != nil }
        stream(h, reply(h)!.runID!)?.send(#"{"event":"message.delta","delta":"Working"}"#)
        try await until("first delta") { reply(h)?.plainText == "Working" }
    }

    // MARK: Stop

    func testStopIsOnlyShownAfterTheServerConfirms() async throws {
        let h = makeHarness()
        try await startRun(h)
        h.store.stop()
        h.store.stop()   // double tap
        XCTAssertNotEqual(reply(h)?.state, .cancelled, "never claims stopped before the server says so")
        try await until("server acknowledged") { reply(h)?.stop == .acknowledged }
        XCTAssertEqual(reply(h)?.state, .streaming)
        XCTAssertTrue(h.store.isStreaming, "still following the run")
        stream(h, "run_1")?.send(#"{"event":"run.stopping"}"#)
        stream(h, "run_1")?.send(#"{"event":"run.cancelled"}"#)
        try await until("cancelled") { reply(h)?.state == .cancelled }
        XCTAssertNil(reply(h)?.stop, "confirmed cancellation settles the stop")
        XCTAssertFalse(h.store.isStreaming)
        XCTAssertEqual(h.transport.requests(matching: "POST /hermes/v1/runs/run_1/stop").count, 1, "stop is idempotent")
    }

    func testRunThatFinishesBeforeTheStopSaysSo() async throws {
        let h = makeHarness()
        try await startRun(h)
        h.store.stop()
        try await until("ack") { reply(h)?.stop == .acknowledged }
        stream(h, "run_1")?.send(#"{"event":"run.completed","output":"Working — done."}"#)
        try await until("complete") { reply(h)?.state == .complete }
        XCTAssertEqual(reply(h)?.stop, .finishedFirst)
        XCTAssertEqual(reply(h)?.plainText, "Working — done.")
    }

    func testFailedStopRequestIsReportedAndCanBeRetried() async throws {
        let h = makeHarness(stopStatus: 409, stopBody: #"{"error":{"message":"Run is not active in this gateway process","code":"run_not_active"}}"#)
        try await startRun(h)
        h.store.stop()
        try await until("unconfirmed") { if case .unconfirmed? = reply(h)?.stop { return true } else { return false } }
        guard case .unconfirmed(let reason)? = reply(h)?.stop else { return XCTFail() }
        XCTAssertTrue(reason.contains("may still be going"))
        XCTAssertEqual(reply(h)?.state, .streaming, "a failed stop isn't a stop")
        h.store.stop()   // retry is allowed after an unconfirmed stop
        try await until("second stop") { h.transport.requests(matching: "POST /hermes/v1/runs/run_1/stop").count == 2 }
        stream(h, "run_1")?.send(#"{"event":"run.completed","output":"Working"}"#)
        try await until("complete") { reply(h)?.state == .complete }
    }

    func testSilentServerLeadsToUnconfirmedThenExplicitDetach() async throws {
        let h = makeHarness()
        h.store.stopConfirmationTimeout = 0.2
        try await startRun(h)
        h.store.stop()
        try await until("unconfirmed after timeout") { if case .unconfirmed? = reply(h)?.stop { return true } else { return false } }
        XCTAssertTrue(h.store.isStreaming, "keeps following instead of pretending")
        h.store.stopFollowing()
        guard case .failed(let error)? = reply(h)?.state, case .remote(let code, let message) = error else { return XCTFail("\(String(describing: reply(h)?.state))") }
        XCTAssertEqual(code, "detached")
        XCTAssertTrue(message.contains("never confirmed"))
        XCTAssertFalse(h.store.isStreaming)
    }

    func testLateEventsCannotRewriteASettledReply() async throws {
        let h = makeHarness()
        try await startRun(h)
        stream(h, "run_1")?.send(#"{"event":"run.completed","output":"Working"}"#)
        try await until("complete") { reply(h)?.state == .complete }
        stream(h, "run_1")?.send(#"{"event":"message.delta","delta":" LATE"}"#)
        stream(h, "run_1")?.send(#"{"event":"run.failed","error":"late"}"#)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(reply(h)?.plainText, "Working")
        XCTAssertEqual(reply(h)?.state, .complete)
    }

    // MARK: Steering

    func testQueuedInstructionIsSentAfterTheReplyEnds() async throws {
        let h = makeHarness()
        try await startRun(h)
        try await h.store.steer("and then summarise it", mode: .queue)
        XCTAssertEqual(h.store.queuedInstructions[h.store.currentID!]?.map(\.text), ["and then summarise it"])
        XCTAssertEqual(h.runInputs.current.count, 1, "nothing sent while the first reply runs")
        stream(h, "run_1")?.send(#"{"event":"run.completed","output":"Working"}"#)
        try await until("second run") { h.runInputs.current.count == 2 }
        XCTAssertEqual(h.runInputs.current.last, "and then summarise it")
        XCTAssertNil(h.store.queuedInstructions[h.store.currentID!])
    }

    func testInterruptStopsConfirmsThenSends() async throws {
        let h = makeHarness()
        try await startRun(h)
        try await h.store.steer("actually, do X instead", mode: .interrupt)
        try await until("stop sent") { h.transport.requests(matching: "POST /hermes/v1/runs/run_1/stop").count == 1 }
        XCTAssertEqual(h.runInputs.current.count, 1, "waits for the confirmed stop")
        stream(h, "run_1")?.send(#"{"event":"run.cancelled"}"#)
        try await until("follow-up run") { h.runInputs.current.count == 2 }
        XCTAssertEqual(h.runInputs.current.last, "actually, do X instead")
        let states = h.store.current!.messages.filter { $0.role == .assistant }.map(\.state)
        XCTAssertEqual(states.first, .cancelled)
    }

    func testQueuedInstructionWaitsAfterAFailure() async throws {
        let h = makeHarness()
        try await startRun(h)
        try await h.store.steer("next step", mode: .queue)
        stream(h, "run_1")?.send(#"{"event":"run.failed","error":"provider error"}"#)
        try await until("failed") { if case .failed? = reply(h)?.state { return true } else { return false } }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.runInputs.current.count, 1, "a failed reply doesn't trigger the queue")
        let conversation = h.store.currentID!
        let item = try XCTUnwrap(h.store.queuedInstructions[conversation]?.first)
        h.store.sendQueuedNow(item.id, in: conversation)
        try await until("sent by hand") { h.runInputs.current.count == 2 }
    }

    func testInjectUsesHermesSteerAndExplainsRefusals() async throws {
        let h = makeHarness()
        h.transport.on("POST /hermes/v1/runs/run_1/steer") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"Run is not currently accepting steer input: run_1","code":"run_not_accepting_steer"}}"#, status: 409)
        }
        try await startRun(h)
        do {
            try await h.store.steer("focus on errors", mode: .inject)
            XCTFail("refusal must surface")
        } catch AgentError.remote(_, let message) {
            XCTAssertTrue(message.contains("Send after this"))
        }
        XCTAssertEqual(h.transport.requests(matching: "POST /hermes/v1/runs/run_1/steer").count, 1)
    }

    func testSwitchingChatsDoesNotStopTheReply() async throws {
        let h = makeHarness()
        try await startRun(h)
        let running = h.store.currentID!
        h.store.newConversation()
        XCTAssertNotEqual(h.store.currentID, running)
        XCTAssertTrue(h.store.isStreaming)
        XCTAssertTrue(h.transport.requests(matching: "POST /hermes/v1/runs/run_1/stop").isEmpty)
        stream(h, "run_1")?.send(#"{"event":"message.delta","delta":" more"}"#)
        stream(h, "run_1")?.send(#"{"event":"run.completed","output":"Working more"}"#)
        try await until("finished in its own chat") {
            h.store.conversations.first { $0.id == running }?.messages.last?.state == .complete
        }
        XCTAssertEqual(h.store.conversations.first { $0.id == running }?.messages.last?.plainText, "Working more")
    }
}
