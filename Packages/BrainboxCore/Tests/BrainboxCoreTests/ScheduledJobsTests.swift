import Foundation
import XCTest
@testable import BrainboxCore

// Fixtures use the job / execution / session shapes of hermes-agent 284d220
// (cron/jobs.py create_job + list_jobs, cron/executions.py, cron/scheduler.py).
// All names, prompts and ids are synthetic.

enum JobFixtures {
    static let jobID = "a1b2c3d4e5f6"

    static func execution(_ id: String, _ status: String, claimed: String = "2026-10-22T10:00:30.123456+00:00",
                          started: String? = "2026-10-22T10:00:31+00:00", finished: String? = nil, error: String? = nil) -> String {
        var fields = [#""id":"\#(id)""#, #""job_id":"\#(jobID)""#, #""source":"direct""#, #""status":"\#(status)""#,
                      #""claimed_at":"\#(claimed)""#, #""process_id":"p1""#, #""pid":4242"#]
        if let started { fields.append(#""started_at":"\#(started)""#) }
        if let finished { fields.append(#""finished_at":"\#(finished)""#) }
        if let error { fields.append(#""error":\#(jsonString(error))"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func jsonString(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    static func jobJSON(enabled: Bool = true, state: String = "scheduled", lastRun: String? = nil, lastStatus: String? = nil,
                        lastError: String? = nil, failureStreak: Int = 0, manualRunAt: String? = nil,
                        nextRun: String? = "2026-10-23T09:00:00+00:00", execution: String? = nil, name: String = "Morning summary") -> String {
        var fields = [#""id":"\#(jobID)""#, #""name":\#(jsonString(name))"#, #""prompt":"Summarise the test inbox""#,
                      #""schedule":{"kind":"cron","expr":"0 9 * * *","display":"0 9 * * *"}"#, #""schedule_display":"0 9 * * *""#,
                      #""enabled":\#(enabled)"#, #""state":"\#(state)""#, #""failure_streak":\#(failureStreak)"#, #""deliver":"local""#,
                      #""repeat":{"times":null,"completed":3}"#]
        fields.append(#""next_run_at":\#(nextRun.map(jsonString) ?? "null")"#)
        fields.append(#""last_run_at":\#(lastRun.map(jsonString) ?? "null")"#)
        fields.append(#""last_status":\#(lastStatus.map(jsonString) ?? "null")"#)
        fields.append(#""last_error":\#(lastError.map(jsonString) ?? "null")"#)
        if let manualRunAt { fields.append(#""manual_run_at":"\#(manualRunAt)""#) }
        fields.append(#""latest_execution":\#(execution ?? "null")"#)
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func job(_ json: String) -> HermesJob {
        try! JSONDecoder().decode(HermesJob.self, from: Data(json.utf8))
    }

    static func session(_ id: String, source: String = "cron", title: String? = nil, started: Double? = nil, ended: Double? = nil) -> HermesSession {
        HermesSession(id: id, source: source, title: title, startedAt: started, endedAt: ended)
    }

    static let base = HermesDates.parse("2026-10-22T10:00:00+00:00")!
}

final class HermesJobDecodingTests: XCTestCase {
    func testDecodesLifecycleFieldsAndLatestExecution() {
        let job = JobFixtures.job(JobFixtures.jobJSON(lastRun: "2026-10-22T09:00:05.5+00:00", lastStatus: "error", lastError: "boom",
                                                      failureStreak: 2, manualRunAt: "2026-10-22T10:00:00+00:00",
                                                      execution: JobFixtures.execution("e2", "running")))
        XCTAssertEqual(job.state, "scheduled")
        XCTAssertEqual(job.lastStatus, "error")
        XCTAssertEqual(job.lastError, "boom")
        XCTAssertEqual(job.failureStreak, 2)
        XCTAssertEqual(job.manualRunAt, "2026-10-22T10:00:00+00:00")
        XCTAssertEqual(job.schedule, "0 9 * * *")
        XCTAssertEqual(job.latestExecution?.id, "e2")
        XCTAssertEqual(job.latestExecution?.status, .running)
        XCTAssertEqual(job.latestExecution?.jobID, JobFixtures.jobID)
    }

    func testOlderServersWithoutLifecycleFieldsStillDecode() {
        let job = JobFixtures.job(#"{"id":"x1","name":"Bare"}"#)
        XCTAssertNil(job.latestExecution)
        XCTAssertEqual(job.failureStreak, 0)
        XCTAssertNil(job.state)
        XCTAssertEqual(HermesJobLifecycle.phase(of: job), .scheduled)
        let unknownStatus = JobFixtures.job(#"{"id":"x2","name":"N","latest_execution":{"id":"e9","status":"weird"}}"#)
        XCTAssertEqual(unknownStatus.latestExecution?.status, .unknown)
        XCTAssertEqual(unknownStatus.latestExecution?.rawStatus, "weird")
    }

    func testHermesTimestampsParse() {
        XCTAssertNotNil(HermesDates.parse("2026-10-22T10:00:30.123456+01:00"))
        XCTAssertNotNil(HermesDates.parse("2026-10-22T10:00:30+00:00"))
        XCTAssertNotNil(HermesDates.parse("2026-10-22T10:00:30Z"))
        XCTAssertNotNil(HermesDates.parse("2026-10-22T10:00:30"))
        XCTAssertEqual(HermesDates.parse("2026-10-22T11:00:30.5+01:00"), HermesDates.parse("2026-10-22T10:00:30.5Z"))
        XCTAssertNil(HermesDates.parse("tomorrow"))
        XCTAssertNil(HermesDates.parse(""))
    }
}

final class HermesJobLifecycleTests: XCTestCase {
    private func phase(_ json: String, now: Date = JobFixtures.base) -> HermesJobPhase {
        HermesJobLifecycle.phase(of: JobFixtures.job(json), now: now)
    }

    func testInFlightAttemptsWin() {
        XCTAssertEqual(phase(JobFixtures.jobJSON(execution: JobFixtures.execution("e1", "claimed"))), .starting)
        XCTAssertEqual(phase(JobFixtures.jobJSON(execution: JobFixtures.execution("e1", "running"))), .running)
        // Even a paused job shows a run that is still going.
        XCTAssertEqual(phase(JobFixtures.jobJSON(enabled: false, state: "paused", execution: JobFixtures.execution("e1", "running"))), .running)
    }

    func testPausedQueuedAndScheduled() {
        XCTAssertEqual(phase(JobFixtures.jobJSON(enabled: false, state: "paused")), .paused)
        XCTAssertEqual(phase(JobFixtures.jobJSON(manualRunAt: "2026-10-22T10:00:00+00:00")), .queued)
        XCTAssertEqual(phase(JobFixtures.jobJSON(nextRun: "2026-10-23T09:00:00+00:00")), .scheduled)
        XCTAssertEqual(phase(JobFixtures.jobJSON(nextRun: "2026-10-22T09:59:00+00:00")), .queued, "due but not yet picked up")
    }

    func testFinishedAttemptsAndJobRecordFallbacks() {
        let done = JobFixtures.execution("e1", "completed", finished: "2026-10-22T09:01:00+00:00")
        XCTAssertEqual(phase(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "ok", execution: done)), .completed)
        let failed = JobFixtures.execution("e1", "failed", finished: "2026-10-22T09:01:00+00:00", error: "provider timeout")
        XCTAssertEqual(phase(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "error", execution: failed)), .failed)
        XCTAssertEqual(phase(JobFixtures.jobJSON(execution: JobFixtures.execution("e1", "unknown"))), .unknown)
        XCTAssertEqual(phase(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "delivery_failed")), .completedDeliveryFailed)
        XCTAssertEqual(phase(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "error")), .failed)
        XCTAssertEqual(phase(JobFixtures.jobJSON(state: "completed", lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "ok", nextRun: nil)), .finished)
        XCTAssertEqual(phase(JobFixtures.jobJSON(state: "error")), .failed)
        // A ledger entry older than the job's last recorded run is stale: the job record wins.
        let stale = JobFixtures.execution("e0", "completed", claimed: "2026-10-20T09:00:00+00:00", started: "2026-10-20T09:00:01+00:00",
                                          finished: "2026-10-20T09:01:00+00:00")
        XCTAssertEqual(phase(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "error", execution: stale)), .failed)
    }

    func testFailureDetailIsSanitized() {
        let job = JobFixtures.job(JobFixtures.jobJSON(lastStatus: "error",
                                                      lastError: "401 from provider: Authorization: Bearer abcDEF123456789xyz OPENAI_API_KEY=sk-test-abcdefghij1234567890"))
        let detail = try! XCTUnwrap(HermesJobLifecycle.failureDetail(of: job))
        XCTAssertFalse(detail.contains("abcDEF123456789xyz"))
        XCTAssertFalse(detail.contains("sk-test-abcdefghij1234567890"))
        XCTAssertTrue(detail.contains("401 from provider"))
        XCTAssertNil(HermesJobLifecycle.failureDetail(of: JobFixtures.job(JobFixtures.jobJSON(lastStatus: "ok"))))
    }
}

final class RunNowTrackerTests: XCTestCase {
    private let baseline = JobFixtures.job(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "ok",
                                                               execution: JobFixtures.execution("e1", "completed", claimed: "2026-10-22T09:00:00+00:00",
                                                                                                started: "2026-10-22T09:00:01+00:00", finished: "2026-10-22T09:01:00+00:00")))
    private var tracker: RunNowTracker { RunNowTracker(job: baseline, triggeredAt: JobFixtures.base) }

    func testAcceptedIsOnlyQueuedNeverCompleted() {
        // Right after POST /run: same old (completed) attempt, manual_run_at set.
        let accepted = JobFixtures.job(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "ok",
                                                           manualRunAt: "2026-10-22T10:00:00+00:00",
                                                           execution: JobFixtures.execution("e1", "completed", claimed: "2026-10-22T09:00:00+00:00")))
        XCTAssertEqual(tracker.evaluate(accepted, now: JobFixtures.base.addingTimeInterval(5)), .queued)
    }

    func testFollowsTheNewAttemptToItsEnd() {
        let now = JobFixtures.base.addingTimeInterval(40)
        XCTAssertEqual(tracker.evaluate(JobFixtures.job(JobFixtures.jobJSON(execution: JobFixtures.execution("e2", "claimed"))), now: now), .starting)
        XCTAssertEqual(tracker.evaluate(JobFixtures.job(JobFixtures.jobJSON(execution: JobFixtures.execution("e2", "running"))), now: now), .running)
        XCTAssertEqual(tracker.evaluate(JobFixtures.job(JobFixtures.jobJSON(execution: JobFixtures.execution("e2", "completed", finished: "2026-10-22T10:01:00+00:00"))), now: now), .completed)
        let failed = tracker.evaluate(JobFixtures.job(JobFixtures.jobJSON(execution: JobFixtures.execution("e2", "failed", error: "Cron job timed out (inactivity) token=abcdef0123456789abcdef0123456789abcdef01"))), now: now)
        guard case .failed(let detail?) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(detail.contains("timed out"))
        XCTAssertFalse(detail.contains("abcdef0123456789abcdef0123456789abcdef01"))
        guard case .unknown = tracker.evaluate(JobFixtures.job(JobFixtures.jobJSON(execution: JobFixtures.execution("e2", "unknown"))), now: now) else {
            return XCTFail("worker vanished must stay unknown")
        }
    }

    func testAttemptsFromBeforeTheTriggerAreNotCredited() {
        // A different attempt that was claimed well before we pressed Run now.
        let old = JobFixtures.job(JobFixtures.jobJSON(manualRunAt: "2026-10-22T10:00:00+00:00",
                                                      execution: JobFixtures.execution("e0", "completed", claimed: "2026-10-22T09:30:00+00:00")))
        XCTAssertEqual(tracker.evaluate(old, now: JobFixtures.base.addingTimeInterval(10)), .queued)
    }

    func testTimeoutBecomesUnknownNotSuccess() {
        let stillQueued = JobFixtures.job(JobFixtures.jobJSON(manualRunAt: "2026-10-22T10:00:00+00:00",
                                                              execution: JobFixtures.execution("e1", "completed", claimed: "2026-10-22T09:00:00+00:00")))
        let late = JobFixtures.base.addingTimeInterval(RunNowTracker.timeout + 1)
        guard case .unknown(let reason) = tracker.evaluate(stillQueued, now: late) else { return XCTFail() }
        XCTAssertTrue(reason.contains("not triggered again"))
        guard case .unknown(let running) = tracker.evaluate(JobFixtures.job(JobFixtures.jobJSON(execution: JobFixtures.execution("e2", "running"))), now: late) else {
            return XCTFail()
        }
        XCTAssertTrue(running.contains("Still running"))
    }

    func testFallbackWithoutExecutionLedger() {
        let noLedger = JobFixtures.job(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "ok"))
        let t = RunNowTracker(job: noLedger, triggeredAt: JobFixtures.base)
        let now = JobFixtures.base.addingTimeInterval(60)
        XCTAssertEqual(t.evaluate(JobFixtures.job(JobFixtures.jobJSON(lastRun: "2026-10-22T09:01:00+00:00", lastStatus: "ok", manualRunAt: "2026-10-22T10:00:00+00:00")), now: now), .queued)
        XCTAssertEqual(t.evaluate(JobFixtures.job(JobFixtures.jobJSON(lastRun: "2026-10-22T10:00:50+00:00", lastStatus: "ok")), now: now), .completed)
        guard case .failed = t.evaluate(JobFixtures.job(JobFixtures.jobJSON(lastRun: "2026-10-22T10:00:50+00:00", lastStatus: "error", lastError: "x")), now: now) else {
            return XCTFail()
        }
        guard case .unknown = t.evaluate(nil, now: now) else { return XCTFail("deleted job") }
    }
}

final class CronRunMatchingTests: XCTestCase {
    private let job = JobFixtures.job(JobFixtures.jobJSON(name: "Morning   summary"))

    func testMatchesRunsByIdAndTitleOnlyFromCron() {
        let t0 = JobFixtures.base.timeIntervalSince1970
        let sessions = [
            JobFixtures.session("cron_\(JobFixtures.jobID)_20261022_090000", title: "Morning summary · Oct 22 09:00", started: t0 - 3600, ended: t0 - 3500),
            JobFixtures.session("cron_\(JobFixtures.jobID)_20261022_100031", title: "Morning summary · Oct 22 10:00", started: t0 + 31),
            JobFixtures.session("cron_ffffffffffff_20261022_100000", title: "Morning summary · Oct 22 10:00", started: t0),       // another job
            JobFixtures.session("agent:main:telegram:dm:42", source: "telegram", title: "Morning summary · Oct 22 10:00", started: t0), // not cron
            JobFixtures.session("compressed_child_1", source: "cron", title: "Morning summary · Oct 21 09:00", started: t0 - 90000),
            JobFixtures.session("cron_\(JobFixtures.jobID)_20261022_100031", title: "dup", started: t0 + 31)                       // duplicate page entry
        ]
        let runs = CronRunMatcher.runs(for: job, in: sessions)
        XCTAssertEqual(runs.map(\.sessionID), ["cron_\(JobFixtures.jobID)_20261022_100031",
                                               "cron_\(JobFixtures.jobID)_20261022_090000",
                                               "compressed_child_1"])
        XCTAssertEqual(CronRunMatcher.titlePrefix(for: "Morning   summary"), "Morning summary · ")
    }

    func testSessionIdTimestampFallback() {
        let date = CronRunMatcher.timestamp(fromSessionID: "cron_\(JobFixtures.jobID)_20261022_100031", jobID: JobFixtures.jobID)
        XCTAssertEqual(date, HermesDates.parse("2026-10-22T10:00:31Z"))
        XCTAssertNil(CronRunMatcher.timestamp(fromSessionID: "cron_other_20261022_100031", jobID: JobFixtures.jobID))
        let runs = CronRunMatcher.runs(for: job, in: [JobFixtures.session("cron_\(JobFixtures.jobID)_20261022_100031")])
        XCTAssertEqual(runs.first?.startedAt, date)
    }

    func testRunForExecutionPicksClosestWithinTolerance() {
        let t0 = JobFixtures.base.timeIntervalSince1970
        let runs = CronRunMatcher.runs(for: job, in: [
            JobFixtures.session("cron_\(JobFixtures.jobID)_a", started: t0 + 31),
            JobFixtures.session("cron_\(JobFixtures.jobID)_b", started: t0 + 200),
            JobFixtures.session("cron_\(JobFixtures.jobID)_c", started: t0 - 3600)
        ])
        let execution = HermesJobExecution(id: "e2", status: "completed", claimedAt: "2026-10-22T10:00:30+00:00", startedAt: "2026-10-22T10:00:31+00:00")
        XCTAssertEqual(CronRunMatcher.run(for: execution, in: runs)?.sessionID, "cron_\(JobFixtures.jobID)_a")
        let far = HermesJobExecution(id: "e3", status: "completed", startedAt: "2026-10-22T14:00:00+00:00")
        XCTAssertNil(CronRunMatcher.run(for: far, in: runs))
        XCTAssertEqual(CronRunMatcher.runs(startedAfter: JobFixtures.base, in: runs).map(\.sessionID), ["cron_\(JobFixtures.jobID)_b", "cron_\(JobFixtures.jobID)_a"])
    }

    func testResultIsTheFinalAssistantReply() {
        let messages = [
            HermesMessage(role: "user", content: "Summarise the test inbox", timestamp: 1),
            HermesMessage(role: "assistant", content: "Checking…", timestamp: 2),
            HermesMessage(role: "tool", content: "tool output", toolName: "terminal", timestamp: 3),
            HermesMessage(role: "assistant", content: "Inbox: 3 new messages.", timestamp: 4),
            HermesMessage(role: "assistant", content: "   ", timestamp: 5)
        ]
        XCTAssertEqual(CronRunResult.from(messages: messages.reversed()), .text("Inbox: 3 new messages."))
        XCTAssertEqual(CronRunResult.from(messages: [HermesMessage(role: "user", content: "x"), HermesMessage(role: "tool", content: "y")]), .noReply)
        XCTAssertEqual(CronRunResult.from(messages: []), .empty)
    }

    func testSanitizerKeepsMeaningAndRemovesSecrets() {
        let raw = "Request failed:\n\n  Bearer abc.def-ghi  TELEGRAM_BOT_TOKEN=123:ABC ghp_abcdefghijklmnop " + String(repeating: "x", count: 50)
        let clean = HermesTextSanitizer.sanitize(raw)
        XCTAssertEqual(clean.prefix(15), "Request failed:")
        XCTAssertFalse(clean.contains("abc.def-ghi"))
        XCTAssertFalse(clean.contains("123:ABC"))
        XCTAssertFalse(clean.contains("ghp_abcdefghijklmnop"))
        XCTAssertFalse(clean.contains(String(repeating: "x", count: 50)))
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertEqual(HermesTextSanitizer.sanitize(String(repeating: "word ", count: 200), maxLength: 20).count, 21)
        XCTAssertEqual(HermesTextSanitizer.sanitize("Model refused: rate limited"), "Model refused: rate limited")
    }
}

final class CronClientTests: XCTestCase {
    func testCronRunsPageThroughCronSessionsWithGETsOnly() async throws {
        let transport = MockHTTPTransport()
        let calls = Locked(0)
        transport.on("GET /hermes/api/sessions") { request in
            let n = calls.withLock { $0 += 1; return $0 }
            XCTAssertTrue(request.url.query?.contains("source=cron") ?? false)
            if n == 1 {
                return MockHTTPTransport.json(#"{"object":"list","data":[{"id":"cron_\#(JobFixtures.jobID)_20261022_090000","source":"cron","started_at":1000}],"limit":1,"offset":0,"has_more":true}"#)
            }
            return MockHTTPTransport.json(#"{"object":"list","data":[{"id":"cron_\#(JobFixtures.jobID)_20261022_100000","source":"cron","started_at":2000}],"limit":1,"offset":1,"has_more":false}"#)
        }
        let client = HermesFixtures.client(transport)
        let runs = try await client.cronRuns(for: JobFixtures.job(JobFixtures.jobJSON()), pageSize: 1)
        XCTAssertEqual(runs.map(\.sessionID), ["cron_\(JobFixtures.jobID)_20261022_100000", "cron_\(JobFixtures.jobID)_20261022_090000"])
        XCTAssertTrue(transport.requests.allSatisfy { $0.method == "GET" })
        XCTAssertEqual(transport.requests.last?.url.query?.contains("offset=1"), true)
    }

    func testFallsBackToUnfilteredScanWhenSourceFilterFindsNothing() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/api/sessions") { request in
            if request.url.query?.contains("source=cron") == true {
                return MockHTTPTransport.json(#"{"object":"list","data":[],"has_more":false}"#)
            }
            return MockHTTPTransport.json(#"{"object":"list","data":[{"id":"agent:main:telegram:dm:42","source":"telegram"},{"id":"cron_\#(JobFixtures.jobID)_20261022_100000","source":"scheduler","started_at":2000}],"has_more":false}"#)
        }
        let runs = try await HermesFixtures.client(transport).cronRuns(for: JobFixtures.job(JobFixtures.jobJSON()))
        XCTAssertEqual(runs.map(\.sessionID), ["cron_\(JobFixtures.jobID)_20261022_100000"])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testRunResultReadsMessages() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/api/sessions/cron_\(JobFixtures.jobID)_20261022_100000/messages") { _ in
            MockHTTPTransport.json(#"{"session_id":"x","data":[{"id":1,"role":"user","content":"go","timestamp":1},{"id":2,"role":"assistant","content":"Done: 3 items.","timestamp":2}],"pagination":{"returned":2}}"#)
        }
        let loaded = try await HermesFixtures.client(transport).cronRunResult(sessionID: "cron_\(JobFixtures.jobID)_20261022_100000")
        XCTAssertEqual(loaded.result, .text("Done: 3 items."))
        XCTAssertEqual(loaded.messages.count, 2)
        XCTAssertEqual(transport.requests.first?.method, "GET")
    }
}
