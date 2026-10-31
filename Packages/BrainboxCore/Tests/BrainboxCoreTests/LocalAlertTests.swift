import XCTest
@testable import BrainboxCore

final class LocalAlertTests: XCTestCase {
    private func job(_ exec: String, _ status: String, name: String = "Morning summary") -> HermesJob {
        HermesJob(id: "a1b2c3d4e5f6", name: name, latestExecution: HermesJobExecution(id: exec, status: status))
    }

    func testJobDetectorSeedsThenAlertsOnlyOnNewOutcomes() throws {
        var detector = JobAlertDetector()
        XCTAssertTrue(detector.alerts(for: [job("e1", "completed")]).isEmpty, "existing history never alerts")
        XCTAssertTrue(detector.alerts(for: [job("e1", "completed")]).isEmpty)
        XCTAssertTrue(detector.alerts(for: [job("e2", "running")]).isEmpty, "running isn't an outcome")
        let done = detector.alerts(for: [job("e2", "completed")])
        XCTAssertEqual(done.map(\.kind), [.jobFinished])
        XCTAssertEqual(done.first?.link, "brainbox://tasks/job/a1b2c3d4e5f6")
        XCTAssertEqual(detector.alerts(for: [job("e3", "failed")]).map(\.kind), [.jobFailed])
        // Survives a relaunch / background refresh without re-alerting.
        var restored = try JSONDecoder().decode(JobAlertDetector.self, from: JSONEncoder().encode(detector))
        XCTAssertTrue(restored.alerts(for: [job("e3", "failed")]).isEmpty)
    }

    func testLedgerDedupesAndIsBounded() {
        var ledger = AlertLedger()
        ledger.capacity = 3
        XCTAssertTrue(ledger.record("a"))
        XCTAssertFalse(ledger.record("a"))
        _ = ledger.record("b"); _ = ledger.record("c"); _ = ledger.record("d")
        XCTAssertEqual(ledger.keys, ["b", "c", "d"])
    }

    func testRunAlertsAreNeutralAndKeyedByRunAndState() {
        let alert = RunAlerts.alert(runID: "run_1", title: "Deploy the gateway", state: .completed)
        XCTAssertEqual(alert?.dedupeKey, "run:run_1:completed")
        XCTAssertEqual(RunAlerts.alert(runID: "run_1", title: "x", state: .waitingForApproval)?.kind, .approvalNeeded)
        XCTAssertNil(RunAlerts.alert(runID: "run_1", title: "x", state: .running))
        XCTAssertNil(RunAlerts.alert(runID: "run_1", title: "x", state: .cancelled), "your own Stop doesn't need an alert")
    }

    func testParallelTaskAlertOnlyWhenFinished() {
        var task = ParallelTask(title: "Check", agents: [ParallelAgent(title: "a", prompt: "p")], wantsSynthesis: false)
        XCTAssertNil(RunAlerts.alert(for: task))
        task.agents[0].state = .completed
        XCTAssertEqual(RunAlerts.alert(for: task)?.body, "1 of 1 agents finished “Check”.")
    }
}

final class DeepLinkMoreTests: XCTestCase {
    func testAgentAndTerminalLinks() {
        let id = UUID()
        XCTAssertEqual(BrainboxDeepLink.parse(URL(string: "brainbox://agents/\(id.uuidString.lowercased())")!), .agents(taskID: id))
        XCTAssertEqual(BrainboxDeepLink.parse(URL(string: "brainbox://terminal")!), .terminal)
        // Every alert link the app posts must open somewhere.
        let alert = RunAlerts.alert(for: { var t = ParallelTask(id: id, title: "x", agents: [], wantsSynthesis: false); t.agents = []; return t }())
        XCTAssertNotNil(alert.flatMap { URL(string: $0.link) }.flatMap(BrainboxDeepLink.parse))
        XCTAssertNotNil(BrainboxDeepLink.parse(URL(string: RunAlerts.alert(runID: "run_1", title: "t", state: .completed)!.link)!))
    }
}
