import XCTest
import BrainboxCore
@testable import BrainboxAgent

/// Scheduled jobs against a scripted mock Hermes (shapes from hermes-agent
/// 284d220). Synthetic data only; the clock is simulated so polling is instant.
@MainActor
final class ScheduledJobsModelTests: XCTestCase {
    private let jobID = "a1b2c3d4e5f6"
    private let base = HermesDates.parse("2026-10-22T10:00:00+00:00")!

    nonisolated private func job(manual: Bool = false, lastRun: String = "2026-10-22T09:01:00+00:00", lastStatus: String = "ok",
                     execution: String) -> String {
        #"{"id":"\#(jobID)","name":"Morning summary","prompt":"Summarise the test inbox","schedule_display":"0 9 * * *","enabled":true,"state":"scheduled","next_run_at":"2026-10-23T09:00:00+00:00","last_run_at":"\#(lastRun)","last_status":"\#(lastStatus)","last_error":null,"failure_streak":0,"deliver":"local"\#(manual ? #","manual_run_at":"2026-10-22T10:00:00+00:00""# : ""),"latest_execution":\#(execution)}"#
    }

    nonisolated private func execution(_ id: String, _ status: String, claimed: String, error: String? = nil) -> String {
        #"{"id":"\#(id)","job_id":"\#(jobID)","status":"\#(status)","claimed_at":"\#(claimed)","started_at":"\#(claimed)"\#(error.map { #","error":"\#($0)""# } ?? "")}"#
    }

    private let oldExecution = #"{"id":"e1","status":"completed","claimed_at":"2026-10-22T09:00:00+00:00","started_at":"2026-10-22T09:00:01+00:00","finished_at":"2026-10-22T09:01:00+00:00"}"#

    /// Simulated clock: every `pause` advances it instantly.
    private func makeModel(_ transport: MockHTTPTransport) -> (ScheduledJobsModel, Locked<TimeInterval>) {
        let clock = Locked<TimeInterval>(0)
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!),
                                     transport: transport, tokenProvider: { "device-token-0123456789" })
        let start = base
        let model = ScheduledJobsModel(client: { client },
                                       now: { start.addingTimeInterval(clock.current) },
                                       pause: { seconds in
                                           clock.withLock { $0 += seconds }
                                           await Task.yield()
                                       })
        return (model, clock)
    }

    private func waitForTerminal(_ model: ScheduledJobsModel, _ id: String, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(model.runNow[id]?.phase.isTerminal ?? false) {
            if Date() > deadline { return XCTFail("run-now never reached a terminal state: \(String(describing: model.runNow[id]?.phase))") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Let the result lookup that follows a terminal state finish.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testRunNowGoesQueuedRunningCompletedAndFindsTheResult() async throws {
        let transport = MockHTTPTransport()
        let listCalls = Locked(0)
        let jobAt: @Sendable (Int) -> String = { [self] n in
            switch n {
            case 1, 2: return job(execution: oldExecution)                                                // before triggering
            case 3: return job(manual: true, execution: oldExecution)                                     // accepted → queued
            case 4: return job(manual: true, execution: execution("e2", "claimed", claimed: "2026-10-22T10:00:30+00:00"))
            case 5: return job(manual: true, execution: execution("e2", "running", claimed: "2026-10-22T10:00:30+00:00"))
            default: return job(lastRun: "2026-10-22T10:01:10+00:00", execution: execution("e2", "completed", claimed: "2026-10-22T10:00:30+00:00"))
            }
        }
        transport.on("GET /hermes/api/jobs") { _ in
            let n = listCalls.withLock { $0 += 1; return $0 }
            return MockHTTPTransport.json(#"{"jobs":[\#(jobAt(n))]}"#)
        }
        transport.on("POST /hermes/api/jobs/\(jobID)/run") { [self] _ in MockHTTPTransport.json(#"{"job":\#(job(manual: true, execution: "null"))}"#) }
        transport.on("GET /hermes/api/sessions") { [self] _ in
            MockHTTPTransport.json(#"{"object":"list","data":[{"id":"cron_\#(jobID)_20261022_100031","source":"cron","title":"Morning summary · Oct 22 10:00","started_at":\#(base.timeIntervalSince1970 + 31)},{"id":"cron_\#(jobID)_20261022_090000","source":"cron","started_at":\#(base.timeIntervalSince1970 - 3600)}],"has_more":false}"#)
        }
        transport.on("GET /hermes/api/sessions/cron_\(jobID)_20261022_100031/messages") { _ in
            MockHTTPTransport.json(#"{"data":[{"id":1,"role":"user","content":"Summarise the test inbox","timestamp":1},{"id":2,"role":"assistant","content":"Inbox: 3 new messages.","timestamp":2}]}"#)
        }
        let (model, _) = makeModel(transport)
        await model.refresh()
        let original = try XCTUnwrap(model.job(jobID))
        XCTAssertEqual(model.phase(of: original), .completed, "last run was fine")

        await model.runNow(original)
        // Accepted by Hermes = queued. The poller hasn't run yet (it starts with a pause).
        XCTAssertEqual(model.runNow[jobID]?.phase, .queued, "accepted shows queued, never completed")
        try await waitForTerminal(model, jobID)

        XCTAssertEqual(model.runNow[jobID]?.phase, .completed)
        XCTAssertEqual(transport.requests(matching: "POST /hermes/api/jobs/\(jobID)/run").count, 1, "triggered exactly once")
        XCTAssertEqual(model.runNow[jobID]?.resultRun?.sessionID, "cron_\(jobID)_20261022_100031", "result run matched to the new attempt")

        let run = try XCTUnwrap(model.runNow[jobID]?.resultRun)
        let loaded = try await model.result(for: run)
        XCTAssertEqual(loaded.result, .text("Inbox: 3 new messages."))
        // Results are read-only: only the run trigger is a write.
        XCTAssertEqual(transport.requests.filter { $0.method != "GET" }.map { $0.url.path }, ["/hermes/api/jobs/\(jobID)/run"])
    }

    func testRunNowTimesOutAsUnknownAndNeverTriggersAgain() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/api/jobs") { [self] _ in MockHTTPTransport.json(#"{"jobs":[\#(job(manual: true, execution: oldExecution))]}"#) }
        transport.on("POST /hermes/api/jobs/\(jobID)/run") { [self] _ in MockHTTPTransport.json(#"{"job":\#(job(manual: true, execution: "null"))}"#) }
        let (model, clock) = makeModel(transport)
        await model.refresh()
        await model.runNow(try XCTUnwrap(model.job(jobID)))
        try await waitForTerminal(model, jobID, timeout: 30)
        guard case .unknown(let reason)? = model.runNow[jobID]?.phase else { return XCTFail("\(String(describing: model.runNow[jobID]?.phase))") }
        XCTAssertTrue(reason.contains("not triggered again"))
        XCTAssertGreaterThan(clock.current, RunNowTracker.timeout)
        XCTAssertEqual(transport.requests(matching: "POST /hermes/api/jobs/\(jobID)/run").count, 1)
        XCTAssertNil(model.runNow[jobID]?.resultRun)
    }

    func testFailedRunShowsSanitizedError() async throws {
        let transport = MockHTTPTransport()
        let calls = Locked(0)
        transport.on("GET /hermes/api/jobs") { [self] _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n <= 2 { return MockHTTPTransport.json(#"{"jobs":[\#(job(execution: oldExecution))]}"#) }
            return MockHTTPTransport.json(#"{"jobs":[\#(job(lastRun: "2026-10-22T10:01:00+00:00", lastStatus: "error", execution: execution("e2", "failed", claimed: "2026-10-22T10:00:30+00:00", error: "Provider rejected Bearer abcdefghijklmnop123")))]}"#)
        }
        transport.on("POST /hermes/api/jobs/\(jobID)/run") { [self] _ in MockHTTPTransport.json(#"{"job":\#(job(manual: true, execution: "null"))}"#) }
        transport.on("GET /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"data":[],"has_more":false}"#) }
        let (model, _) = makeModel(transport)
        await model.refresh()
        await model.runNow(try XCTUnwrap(model.job(jobID)))
        try await waitForTerminal(model, jobID)
        guard case .failed(let detail?)? = model.runNow[jobID]?.phase else { return XCTFail() }
        XCTAssertTrue(detail.contains("Provider rejected"))
        XCTAssertFalse(detail.contains("abcdefghijklmnop123"))
        XCTAssertNil(model.runNow[jobID]?.resultRun, "no session found → no invented result")
        XCTAssertEqual(model.phase(of: try XCTUnwrap(model.job(jobID))), .failed)
    }

    func testDoubleTapTriggersOnceAndRequestErrorsAreNotTracked() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/api/jobs") { [self] _ in MockHTTPTransport.json(#"{"jobs":[\#(job(manual: true, execution: oldExecution))]}"#) }
        transport.on("POST /hermes/api/jobs/\(jobID)/run") { [self] _ in MockHTTPTransport.json(#"{"job":\#(job(manual: true, execution: "null"))}"#) }
        let (model, _) = makeModel(transport)
        model.pause = { _ in try await Task.sleep(nanoseconds: 10_000_000_000) }   // keep it pending
        await model.refresh()
        let target = try XCTUnwrap(model.job(jobID))
        await model.runNow(target)
        await model.runNow(target)
        XCTAssertEqual(transport.requests(matching: "POST /hermes/api/jobs/\(jobID)/run").count, 1)
        XCTAssertEqual(model.runNow[jobID]?.phase, .queued)
        model.dismissRunNow(jobID)

        let failing = MockHTTPTransport()
        failing.on("GET /hermes/api/jobs") { [self] _ in MockHTTPTransport.json(#"{"jobs":[\#(job(execution: oldExecution))]}"#) }
        failing.on("POST /hermes/api/jobs/\(jobID)/run") { _ in MockHTTPTransport.json(#"{"error":"Cron module not available"}"#, status: 501) }
        let (other, _) = makeModel(failing)
        await other.refresh()
        await other.runNow(try XCTUnwrap(other.job(jobID)))
        XCTAssertNil(other.runNow[jobID], "a rejected request is not shown as a run")
        XCTAssertNotNil(other.error)
    }

    func testUnavailableSchedulerAndMissingResults() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/api/jobs") { _ in MockHTTPTransport.json(#"{"error":"Cron module not available"}"#, status: 501) }
        let (model, _) = makeModel(transport)
        await model.refresh()
        XCTAssertNotNil(model.unavailable)
        XCTAssertTrue(model.jobs.isEmpty)

        let empty = MockHTTPTransport()
        empty.on("GET /hermes/api/sessions/cron_x/messages") { _ in MockHTTPTransport.json(#"{"data":[]}"#) }
        let (other, _) = makeModel(empty)
        let run = CronRun(sessionID: "cron_x", jobID: "x")
        let loaded = try await other.result(for: run)
        XCTAssertEqual(loaded.result, .empty)

        let disconnected = ScheduledJobsModel(client: { nil })
        await disconnected.refresh()
        XCTAssertEqual(disconnected.unavailable, "Connect to Hermes to manage scheduled tasks.")
    }

    func testDeleteWarningMatchesHermesBehaviour() {
        // Hermes 284d220 remove_job: erases outputs, does not interrupt a running attempt.
        XCTAssertTrue(JobDeletion.warning.contains("erases"))
        XCTAssertTrue(JobDeletion.warning.contains("is not stopped"))
        XCTAssertFalse(JobDeletion.warning.lowercased().contains("cancels"))
    }
}
