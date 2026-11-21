import XCTest
@testable import BrainboxCore

/// Concurrent agents against a scripted Hermes: each agent is a real separate
/// run; streams are released by the test so ordering is deterministic.
@MainActor
final class ParallelRunTests: XCTestCase {
    /// Runs whose streams finish only when the test (or a stop) releases them.
    final class FakeHermes: @unchecked Sendable {
        let transport = MockHTTPTransport()
        let created = Locked<[(run: String, input: String, key: String?)]>([])
        let released = Locked<[String: String]>([:])   // run → terminal event json
        let rateLimitFirst = Locked(0)
        let replay = Locked(false)
        let dropStream = Locked<Set<String>>([])

        init() {
            transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"session":{"id":"ios_x"}}"#, status: 201) }
            transport.on("POST /hermes/v1/runs") { [self] request in
                if rateLimitFirst.withLock({ n -> Bool in if n > 0 { n -= 1; return true } else { return false } }) {
                    return MockHTTPTransport.json(#"{"error":{"message":"Too many concurrent runs (max 2)","code":"rate_limit_exceeded"}}"#, status: 429)
                }
                let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
                let id = created.withLock { list -> String in
                    let id = "run_\(list.count + 1)"
                    list.append((id, body["input"]?.stringValue ?? "", request.headers["Idempotency-Key"]))
                    return id
                }
                let replayed = replay.current
                return MockHTTPTransport.json(#"{"run_id":"\#(id)","status":"started","replayed":\#(replayed)}"#, status: 202)
            }
            for n in 1...8 {
                let id = "run_\(n)"
                transport.onStream("GET /hermes/v1/runs/\(id)/events") { [self] _ in
                    let stream = AsyncThrowingStream<Data, Error> { continuation in
                        let task = Task {
                            continuation.yield(Data("data: {\"event\":\"message.delta\",\"delta\":\"output of \(id)\"}\n\n".utf8))
                            if self.dropStream.current.contains(id) { continuation.finish(); return }
                            while !Task.isCancelled {
                                if let terminal = self.released.current[id] {
                                    continuation.yield(Data("data: \(terminal)\n\n".utf8))
                                    break
                                }
                                try? await Task.sleep(nanoseconds: 5_000_000)
                            }
                            continuation.finish()
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                    return HTTPStreamResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: stream)
                }
                transport.on("POST /hermes/v1/runs/\(id)/stop") { [self] _ in
                    released.withLock { $0[id] = #"{"event":"run.cancelled"}"# }
                    return MockHTTPTransport.json(#"{"run_id":"\#(id)","status":"stopping"}"#)
                }
                transport.on("GET /hermes/v1/runs/\(id)") { _ in
                    MockHTTPTransport.json(#"{"run_id":"\#(id)","status":"completed","output":"polled result of \#(id)"}"#)
                }
            }
        }

        func finish(_ run: String, output: String = "done") {
            released.withLock { $0[run] = #"{"event":"run.completed","output":"\#(output)"}"# }
        }

        var client: HermesAPIClient {
            HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!),
                            transport: transport, tokenProvider: { "device-token-0123456789" })
        }
    }

    private func engine(_ fake: FakeHermes, max: Int = 2) -> ParallelRunEngine {
        let client = fake.client
        return ParallelRunEngine(maxConcurrent: max, pollInterval: 0.01, client: { client }, pause: { _ in await Task.yield() })
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testRunsConcurrentlyUpToTheLimitThenSynthesises() async throws {
        let fake = FakeHermes()
        let engine = engine(fake, max: 2)
        let task = engine.start(title: "Server check", prompts: [("Disk", "check disk", nil, nil), ("Logs", "review logs", nil, nil), ("Load", "check load", nil, nil)])
        try await until("two running") { fake.created.current.count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.created.current.count, 2, "never more than the limit at once")
        XCTAssertEqual(Set(fake.created.current.map(\.input)), ["check disk", "review logs"])
        fake.finish("run_1", output: "disk 40% used")
        try await until("third starts") { fake.created.current.count == 3 }
        fake.finish("run_2", output: "no errors in logs")
        fake.finish("run_3", output: "load 0.2")
        try await until("synthesis run") { fake.created.current.count == 4 }
        let synthesisInput = fake.created.current[3].input
        XCTAssertTrue(synthesisInput.contains("disk 40% used") && synthesisInput.contains("no errors in logs") && synthesisInput.contains("load 0.2"))
        fake.finish("run_4", output: "All healthy.")
        try await until("finished") { engine.task(task.id)?.isFinished == true }
        let done = try XCTUnwrap(engine.task(task.id))
        XCTAssertEqual(done.agents.map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(done.synthesis?.output, "All healthy.")
        // Every agent had its own app session and its own run.
        XCTAssertEqual(Set(done.agents.map(\.sessionID)).count, 3)
        XCTAssertTrue(done.agents.allSatisfy { AppSessionID.isValid($0.sessionID) })
        XCTAssertEqual(Set(done.agents.compactMap(\.runID)).count, 3)
    }

    func testCancellingOneAgentLeavesTheOthersRunning() async throws {
        let fake = FakeHermes()
        let engine = engine(fake, max: 3)
        let task = engine.start(title: "Two jobs", prompts: [("A", "task a", nil, nil), ("B", "task b", nil, nil)])
        try await until("both running") { engine.task(task.id)?.agents.allSatisfy { $0.runID != nil } == true }
        let a = engine.task(task.id)!.agents[0]
        engine.cancel(agent: a.id, in: task.id)
        engine.cancel(agent: a.id, in: task.id)   // idempotent
        try await until("A cancelled") { engine.task(task.id)?.agents[0].state == .cancelled }
        XCTAssertEqual(fake.transport.requests(matching: "POST /hermes/v1/runs/\(a.runID!)/stop").count, 1)
        let b = engine.task(task.id)!.agents[1]
        XCTAssertFalse(b.state.isTerminal, "B is untouched")
        XCTAssertTrue(fake.transport.requests(matching: "POST /hermes/v1/runs/\(b.runID!)/stop").isEmpty)
        fake.finish(b.runID!, output: "b result")
        try await until("synthesis") { engine.task(task.id)?.synthesis?.runID != nil }
        XCTAssertTrue(fake.created.current.last!.input.contains("stopped by the user"))
    }

    func testWaitsOutTheConcurrencyCapWithoutDuplicates() async throws {
        let fake = FakeHermes()
        fake.rateLimitFirst.withLock { $0 = 2 }
        let engine = engine(fake, max: 1)
        let task = engine.start(title: "One", prompts: [("Only", "do it", nil, nil)], synthesize: false)
        try await until("created after 429s") { fake.created.current.count == 1 }
        XCTAssertEqual(fake.transport.requests(matching: "POST /hermes/v1/runs").count, 3)
        let keys = Set(fake.transport.requests(matching: "POST /hermes/v1/runs").compactMap { $0.headers["Idempotency-Key"] })
        XCTAssertEqual(keys.count, 1, "every attempt reuses one idempotency key — Hermes can't start it twice")
        XCTAssertTrue(engine.task(task.id)!.agents[0].activity.contains { $0.contains("concurrent-run limit") })
        fake.finish("run_1")
        try await until("done") { engine.task(task.id)?.isFinished == true }
        XCTAssertNil(engine.task(task.id)?.synthesis, "no synthesis for a single agent")
    }

    func testDroppedStreamFallsBackToStatusAndCancelBeforeStartNeverRuns() async throws {
        let fake = FakeHermes()
        fake.dropStream.withLock { $0.insert("run_1") }
        let engine = engine(fake, max: 1)
        let task = engine.start(title: "Two", prompts: [("First", "one", nil, nil), ("Second", "two", nil, nil)], synthesize: false)
        let second = engine.task(task.id)!.agents[1]
        engine.cancel(agent: second.id, in: task.id)   // still waiting for a slot
        XCTAssertEqual(engine.task(task.id)?.agents[1].state, .cancelled)
        try await until("first completes via polling") { engine.task(task.id)?.agents[0].state == .completed }
        XCTAssertEqual(engine.task(task.id)?.agents[0].output, "polled result of run_1")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.created.current.count, 1, "the cancelled agent was never started")
    }

    func testFailureIsIsolatedAndRetryIsAFreshRun() async throws {
        let fake = FakeHermes()
        let engine = engine(fake, max: 2)
        let task = engine.start(title: "Mixed", prompts: [("Bad", "fail", nil, nil), ("Good", "work", nil, nil)], synthesize: false)
        try await until("both started") { engine.task(task.id)?.agents.allSatisfy { $0.runID != nil } == true }
        // The two runs start concurrently, so look up which run id the failing agent got.
        let badRun = engine.task(task.id)!.agents[0].runID!
        fake.released.withLock { $0[badRun] = #"{"event":"run.failed","error":"provider error"}"# }
        try await until("A failed") { engine.task(task.id)?.agents[0].state == .failed }
        XCTAssertEqual(engine.task(task.id)?.agents[0].error, "provider error")
        XCTAssertFalse(engine.task(task.id)!.agents[1].state.isTerminal)
        let firstKey = fake.created.current.first { $0.run == badRun }?.key
        engine.retry(agent: engine.task(task.id)!.agents[0].id, in: task.id)
        try await until("retried") { fake.created.current.count == 3 }
        guard fake.created.current.count == 3 else { return }
        XCTAssertNotEqual(fake.created.current[2].key, firstKey, "a retry is a new run, not a replay")
    }

    func testStateSurvivesEncoding() async throws {
        var task = ParallelTask(title: "t", agents: [ParallelAgent(title: "a", prompt: "p")])
        task.agents[0].runID = "run_9"
        task.agents[0].state = .running
        let decoded = try JSONDecoder().decode(ParallelTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)
    }
}
