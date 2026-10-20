import Foundation
import XCTest
@testable import BrainboxCore

// MARK: - Fixtures

enum HermesFixtures {
    /// Shape copied from `_handle_capabilities` in hermes-agent v0.21.2.
    static let capabilities = #"""
    {"object":"hermes.api_server.capabilities","platform":"hermes-agent","model":"hermes-agent",
     "auth":{"type":"bearer","required":true},
     "runtime":{"mode":"server_agent","tool_execution":"server","split_runtime":false},
     "features":{"chat_completions":true,"run_submission":true,"runs_idempotency":{"supported":true,"durable":true,"retention_seconds":86400},
       "run_status":true,"run_events_sse":true,"run_stop":true,"run_steer":true,"run_approval_response":true,
       "tool_progress_events":true,"approval_events":true,"session_resources":true,"session_chat":true,
       "session_chat_streaming":true,"session_fork":true,"admin_config_rw":false,"jobs_admin":false,"skills_api":true,
       "session_continuity_header":"X-Hermes-Session-Id","browser_extension_control":{"enabled":false,"protocol_version":1}},
     "endpoints":{"runs":{"method":"POST","path":"/v1/runs"},"run_status":{"method":"GET","path":"/v1/runs/{run_id}"},
       "run_events":{"method":"GET","path":"/v1/runs/{run_id}/events"},"sessions":{"method":"GET","path":"/api/sessions"},
       "session_messages":{"method":"GET","path":"/api/sessions/{session_id}/messages"},
       "session_fork":{"method":"POST","path":"/api/sessions/{session_id}/fork"},"toolsets":{"method":"GET","path":"/v1/toolsets"}}}
    """#

    static let oldServerCapabilities = #"""
    {"object":"hermes.api_server.capabilities","platform":"hermes-agent","auth":{"type":"bearer","required":true},
     "features":{"chat_completions":true,"run_submission":true,"run_status":true},"endpoints":{}}
    """#

    static func event(_ json: String) -> String { "data: \(json)\n\n" }

    static func client(_ transport: MockHTTPTransport, profile: String? = nil, base: String = "https://vps.example.ts.net:8443/hermes") -> HermesAPIClient {
        HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: base)!, profile: profile, pollInterval: 0.01),
                        transport: transport, tokenProvider: { "device-token-123" })
    }
}

// MARK: - SSE

final class SSEParserTests: XCTestCase {
    func testParsesEventsSplitAcrossArbitraryChunks() {
        let stream = "event: tool.started\ndata: {\"a\":1}\n\ndata: second\n\n"
        let bytes = Array(stream.utf8)
        for split in 1..<bytes.count {
            var parser = SSEParser()
            var events = parser.feed(bytes[..<split])
            events += parser.feed(bytes[split...])
            XCTAssertEqual(events, [SSEEvent(event: "tool.started", data: #"{"a":1}"#), SSEEvent(data: "second")], "split at \(split)")
        }
    }

    func testHandlesCRLFAndCRAcrossChunks() {
        var parser = SSEParser()
        var events = parser.feed("data: one\r")
        events += parser.feed("\n\r\n")
        events += parser.feed("data: two\r\r")
        XCTAssertEqual(events.map(\.data), ["one", "two"])
    }

    func testMultilineDataIdsRetryAndComments() {
        var parser = SSEParser()
        let events = parser.feed(": keepalive\n\nid: 7\nretry: 1500\ndata: line1\ndata: line2\n\n: stream closed\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2")
        XCTAssertEqual(events[0].id, "7")
        XCTAssertEqual(events[0].retry, 1500)
        XCTAssertEqual(parser.lastEventID, "7")
    }

    func testFinishFlushesUnterminatedEventAndMultibyteSplit() {
        var parser = SSEParser()
        let bytes = Array("data: héllo 👋".utf8)
        var events = parser.feed(bytes[..<9]) // splits inside "é"
        events += parser.feed(bytes[9...])
        events += parser.finish()
        XCTAssertEqual(events.map(\.data), ["héllo 👋"])
    }

    func testFieldWithoutColonAndEmptyDataLine() {
        var parser = SSEParser()
        let events = parser.feed("data\n\ndata:\ndata:x\n\n")
        XCTAssertEqual(events.map(\.data), ["", "\nx"])
    }
}

// MARK: - Models & compatibility

final class HermesModelTests: XCTestCase {
    func testCapabilitiesDecodeAndCompatibility() throws {
        let caps = try JSONDecoder().decode(HermesCapabilities.self, from: Data(HermesFixtures.capabilities.utf8))
        XCTAssertEqual(caps.authType, "bearer")
        XCTAssertTrue(caps.supports("run_steer"))
        XCTAssertFalse(caps.supports("jobs_admin"))
        XCTAssertFalse(caps.supports("browser_extension_control"))
        XCTAssertTrue(caps.supports("runs_idempotency"))
        let report = HermesCompatibilityReport.evaluate(caps)
        XCTAssertTrue(report.isCompatible, report.problems.joined())
        XCTAssertTrue(report.supports(.approvals))
        XCTAssertTrue(report.supports(.sessionFork))
    }

    func testOlderServerWithoutEventsIsIncompatible() throws {
        let caps = try JSONDecoder().decode(HermesCapabilities.self, from: Data(HermesFixtures.oldServerCapabilities.utf8))
        let report = HermesCompatibilityReport.evaluate(caps)
        XCTAssertFalse(report.isCompatible)
        XCTAssertTrue(report.problems.contains { $0.contains("Live run events") })
        XCTAssertTrue(report.problems.contains { $0.contains("Session history") })
    }

    func testForeignServerIsIncompatible() {
        let caps = HermesCapabilities(object: "something.else", features: ["run_submission": true, "run_events_sse": true, "run_status": true, "session_resources": true])
        XCTAssertFalse(HermesCompatibilityReport.evaluate(caps).isCompatible)
    }

    func testSessionDecodingAndSourceClassification() throws {
        let json = #"""
        {"object":"list","data":[
          {"id":"agent:main:telegram:dm:42","source":"telegram","title":null,"started_at":1760000000.5,"last_active":"1760000100","message_count":12,"preview":"hey","pinned":0},
          {"id":"ios_0123456789abcdef0123456789abcdef","source":"api_server","title":"Deploy fix","started_at":1760000200},
          {"id":"api_1760_x","source":"api_server"},
          {"id":"cli_1","source":"cli"}],
         "limit":4,"offset":0,"has_more":true}
        """#
        let page = try JSONDecoder().decode(HermesSessionPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.sessions.map(\.sourceKind), [.telegram, .ios, .api, .cli])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.sessions[0].displayTitle, "hey")
        XCTAssertEqual(page.sessions[0].lastActive, 1760000100)
        XCTAssertTrue(page.sessions[0].sourceKind.isExternalPlatform)
    }

    func testMessageContentVariants() throws {
        let json = #"""
        {"object":"list","session_id":"s","data":[
          {"id":1,"role":"user","content":"hi","timestamp":1760000000},
          {"id":2,"role":"assistant","content":[{"type":"text","text":"part one"},{"type":"text","text":"part two"}]},
          {"id":3,"role":"tool","content":null,"tool_name":"terminal"}],
         "pagination":{"limit":500,"offset":0,"order":"latest","returned":3}}
        """#
        let page = try JSONDecoder().decode(HermesMessagePage.self, from: Data(json.utf8))
        XCTAssertEqual(page.messages.map(\.content), ["hi", "part one\npart two", ""])
        XCTAssertEqual(page.messages[0].rawID, "1")
        XCTAssertTrue(page.messages[2].isTool)
        XCTAssertEqual(page.returned, 3)
    }

    func testRunEventParsing() {
        XCTAssertEqual(HermesRunEvent.parse(data: #"{"event":"message.delta","run_id":"r","timestamp":1,"delta":"Hi"}"#), .messageDelta("Hi"))
        XCTAssertEqual(HermesRunEvent.parse(data: #"{"event":"tool.completed","run_id":"r","tool":"terminal","duration":1.25,"error":true}"#),
                       .toolCompleted(tool: "terminal", duration: 1.25, isError: true))
        guard case .approvalRequest(let approval)? = HermesRunEvent.parse(data: #"{"command":"rm -rf /tmp/x","description":"recursive delete","pattern_key":"rm","allow_permanent":false,"allow_session":true,"event":"approval.request","run_id":"r","timestamp":1,"choices":["once","session","deny"]}"#) else {
            return XCTFail("approval not parsed")
        }
        XCTAssertEqual(approval.command, "rm -rf /tmp/x")
        XCTAssertEqual(approval.choices, ["once", "session", "deny"])
        XCTAssertEqual(HermesRunEvent.parse(data: #"{"event":"run.completed","output":"Done.","usage":{"input_tokens":5,"output_tokens":7,"total_tokens":12}}"#),
                       .completed(output: "Done.", usage: HermesUsage(inputTokens: 5, outputTokens: 7, totalTokens: 12), pendingSteer: nil))
        XCTAssertEqual(HermesRunEvent.parse(data: #"{"event":"brand.new","x":1}"#), .unknown(name: "brand.new"))
        XCTAssertNil(HermesRunEvent.parse(data: "not json"))
    }

    func testApprovalChoicesDerivedWhenMissing() throws {
        let smart = try JSONDecoder().decode(HermesApprovalRequest.self, from: Data(#"{"command":"x","smart_denied":true}"#.utf8))
        XCTAssertEqual(smart.choices, ["once", "deny"])
        let full = try JSONDecoder().decode(HermesApprovalRequest.self, from: Data(#"{"command":"x"}"#.utf8))
        XCTAssertEqual(full.choices, ["once", "session", "always", "deny"])
    }

    func testJobDecodingIsLenient() throws {
        let json = #"{"jobs":[{"id":"abcdef123456","name":"Daily report","prompt":"Summarise","schedule":{"display":"every day at 9am","expr":"0 9 * * *"},"enabled":true,"paused":false,"deliver":"telegram"},{"job_id":"x","name":"Bare"}]}"#
        let jobs = try JSONDecoder().decode(HermesJobsEnvelope.self, from: Data(json.utf8)).jobs
        XCTAssertEqual(jobs[0].schedule, "every day at 9am")
        XCTAssertEqual(jobs[0].deliver, "telegram")
        XCTAssertEqual(jobs[1].id, "x")
    }
}

// MARK: - Client

final class HermesClientTests: XCTestCase {
    func testURLBuildingWithPrefixProfileAndEscaping() {
        let transport = MockHTTPTransport()
        let plain = HermesFixtures.client(transport)
        XCTAssertEqual(plain.url("/v1/runs").absoluteString, "https://vps.example.ts.net:8443/hermes/v1/runs")
        let profiled = HermesFixtures.client(transport, profile: "research", base: "https://h.example/hermes/")
        XCTAssertEqual(profiled.url("/v1/capabilities").absoluteString, "https://h.example/hermes/p/research/v1/capabilities")
        let defaultProfile = HermesFixtures.client(transport, profile: "default")
        XCTAssertFalse(defaultProfile.url("/x").absoluteString.contains("/p/"))
        XCTAssertEqual(HermesAPIClient.escape("agent:main:telegram:dm:42"), "agent:main:telegram:dm:42")
        XCTAssertEqual(HermesAPIClient.escape("a/b?c"), "a%2Fb%3Fc")
    }

    func testSendsBearerTokenAndMapsErrors() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/v1/capabilities") { _ in MockHTTPTransport.json(#"{"error":{"message":"Invalid API key","type":"invalid_request_error","code":"invalid_api_key"}}"#, status: 401) }
        transport.on("POST /hermes/v1/runs/r1/approval") { _ in MockHTTPTransport.json(#"{"error":{"message":"Run has no pending approval: r1","code":"approval_not_pending"}}"#, status: 409) }
        let client = HermesFixtures.client(transport)
        do {
            _ = try await client.capabilities()
            XCTFail("expected auth failure")
        } catch let error as AgentError {
            guard case .authenticationFailed = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(transport.requests.first?.headers["Authorization"], "Bearer device-token-123")
        do {
            try await client.respondToApproval(runID: "r1", choice: .once)
            XCTFail("expected conflict")
        } catch AgentError.remote(let code, let message) {
            XCTAssertEqual(code, "approval_not_pending")
            XCTAssertTrue(message.contains("no pending approval"))
        }
    }

    func testCreateRunSendsIdempotencyAndBody() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/v1/runs") { _ in MockHTTPTransport.json(#"{"run_id":"run_1","status":"started","replayed":false}"#, status: 202) }
        let client = HermesFixtures.client(transport)
        let accepted = try await client.createRun(input: "hello", options: .init(sessionID: "ios_x", instructions: "be brief", model: "m1", idempotencyKey: "key-1"))
        XCTAssertEqual(accepted.runID, "run_1")
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.headers["Idempotency-Key"], "key-1")
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
        XCTAssertEqual(body["input"]?.stringValue, "hello")
        XCTAssertEqual(body["session_id"]?.stringValue, "ios_x")
        XCTAssertEqual(body["instructions"]?.stringValue, "be brief")
        XCTAssertEqual(body["model"]?.stringValue, "m1")
    }

    func testRunEventsDeduplicatesById() async throws {
        let transport = MockHTTPTransport()
        transport.onStream("GET /hermes/v1/runs/r/events") { _ in
            MockHTTPTransport.sse([
                "id: 1\ndata: {\"event\":\"message.delta\",\"delta\":\"a\"}\n\n",
                "id: 1\ndata: {\"event\":\"message.delta\",\"delta\":\"a\"}\n\n",
                ": keepalive\n\n",
                "id: 2\ndata: {\"event\":\"run.completed\",\"output\":\"a\"}\n\n",
                "data: {\"event\":\"message.delta\",\"delta\":\"after terminal\"}\n\n"
            ])
        }
        var events: [HermesRunEvent] = []
        for try await event in HermesFixtures.client(transport).runEvents(id: "r") { events.append(event) }
        XCTAssertEqual(events, [.messageDelta("a"), .completed(output: "a", usage: nil, pendingSteer: nil)])
    }

    func testSessionCreationAndForkBodies() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"object":"hermes.session","session":{"id":"ios_a","source":"api_server","title":"T"}}"#, status: 201) }
        transport.on("POST /hermes/api/sessions/agent:main:telegram:dm:42/fork") { _ in MockHTTPTransport.json(#"{"object":"hermes.session","session":{"id":"fork_1","source":"api_server","parent_session_id":"agent:main:telegram:dm:42"}}"#, status: 201) }
        let client = HermesFixtures.client(transport)
        let created = try await client.createSession(id: "ios_a", title: "T")
        XCTAssertEqual(created.sourceKind, .ios)
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requests[0].body ?? Data())
        XCTAssertEqual(body["source"]?.stringValue, "api_server")
        let fork = try await client.forkSession(id: "agent:main:telegram:dm:42", title: "From Telegram")
        XCTAssertEqual(fork.id, "fork_1")
        XCTAssertEqual(fork.parentSessionID, "agent:main:telegram:dm:42")
    }
}

// MARK: - Mapper

final class HermesRunMapperTests: XCTestCase {
    func testToolsMatchFIFOByNameAndStatusesFollow() {
        var mapper = HermesRunMapper(runID: "r")
        let a = mapper.map(.toolStarted(tool: "terminal", preview: "ls"))
        let b = mapper.map(.toolStarted(tool: "terminal", preview: "pwd"))
        guard case .toolStarted(let first)? = a.last, case .toolStarted(let second)? = b.last else { return XCTFail() }
        XCTAssertEqual(first.kind, .terminal)
        XCTAssertEqual(first.input, "ls")
        let done1 = mapper.map(.toolCompleted(tool: "terminal", duration: 0.5, isError: false))
        XCTAssertEqual(done1.count, 1) // another terminal still running → no status change
        guard case .toolFinished(let id1, _, .succeeded)? = done1.first else { return XCTFail() }
        XCTAssertEqual(id1, first.id)
        let done2 = mapper.map(.toolCompleted(tool: "terminal", duration: nil, isError: true))
        guard case .toolFinished(let id2, let result, .failed)? = done2.first else { return XCTFail() }
        XCTAssertEqual(id2, second.id)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(done2.last, .status(.thinking))
        XCTAssertEqual(mapper.map(.toolCompleted(tool: "terminal", duration: nil, isError: false)), []) // unmatched ignored
    }

    func testCompletionEmitsOnlyUnseenRemainder() {
        var mapper = HermesRunMapper(runID: "r")
        _ = mapper.map(.messageDelta("Hello"))
        XCTAssertEqual(mapper.map(.completed(output: "Hello world", usage: nil, pendingSteer: nil)), [.textDelta(" world"), .completed])
        XCTAssertEqual(mapper.map(.messageDelta("late")), [])

        var silent = HermesRunMapper(runID: "r2")
        XCTAssertEqual(silent.map(.completed(output: "Full answer", usage: nil, pendingSteer: nil)), [.textDelta("Full answer"), .completed])

        var diverged = HermesRunMapper(runID: "r3")
        _ = diverged.map(.messageDelta("Draft"))
        XCTAssertEqual(diverged.map(.completed(output: "Different", usage: nil, pendingSteer: nil)), [.completed])
    }

    func testApprovalLifecycleAndReconcile() {
        var mapper = HermesRunMapper(runID: "r")
        let events = mapper.map(.approvalRequest(HermesApprovalRequest(command: "systemctl restart nginx", choices: ["once", "deny"])))
        guard case .approvalRequested(let approval)? = events.first else { return XCTFail() }
        XCTAssertEqual(approval.runID, "r")
        // Polling while still waiting does not duplicate the prompt.
        XCTAssertEqual(mapper.reconcile(HermesRunStatus(runID: "r", status: .waitingForApproval, approval: HermesApprovalRequest(command: "systemctl restart nginx"))), [])
        // Resolved from another device (e.g. Telegram /approve).
        XCTAssertEqual(mapper.reconcile(HermesRunStatus(runID: "r", status: .running)), [.approvalResolved(choice: "resolved elsewhere"), .status(.thinking)])
        XCTAssertEqual(mapper.reconcile(HermesRunStatus(runID: "r", status: .failed, error: "boom")), [.failed(.remote(code: "run_failed", message: "boom"))])
        XCTAssertTrue(mapper.finished)
    }

    func testCancelledAndInterrupted() {
        var a = HermesRunMapper(runID: "a")
        XCTAssertEqual(a.map(.cancelled), [.failed(.cancelled)])
        var b = HermesRunMapper(runID: "b")
        guard case .failed(.remote(let code, _))? = b.map(.interrupted(error: nil)).first else { return XCTFail() }
        XCTAssertEqual(code, "run_interrupted")
    }

    func testToolKinds() {
        XCTAssertEqual(HermesRunMapper.kind(forTool: "terminal"), .terminal)
        XCTAssertEqual(HermesRunMapper.kind(forTool: "browser_navigate"), .browser)
        XCTAssertEqual(HermesRunMapper.kind(forTool: "web_search"), .search)
        XCTAssertEqual(HermesRunMapper.kind(forTool: "read_file"), .file)
        XCTAssertEqual(HermesRunMapper.kind(forTool: "execute_code"), .code)
        XCTAssertEqual(HermesRunMapper.kind(forTool: "mystery"), .other)
    }
}

// MARK: - Provider (end to end against the mock server)

final class HermesProviderTests: XCTestCase {
    private func makeServer(events: [String], afterEventsFail: Bool = false) -> MockHTTPTransport {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/v1/capabilities") { _ in MockHTTPTransport.json(HermesFixtures.capabilities) }
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"object":"hermes.session","session":{"id":"ios_x","source":"api_server"}}"#, status: 201) }
        transport.on("POST /hermes/v1/runs") { _ in MockHTTPTransport.json(#"{"run_id":"run_42","status":"started"}"#, status: 202) }
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            MockHTTPTransport.sse(events, failAtEnd: afterEventsFail ? URLError(.networkConnectionLost) : nil)
        }
        return transport
    }

    func testConnectEvaluatesCompatibility() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/v1/capabilities") { _ in MockHTTPTransport.json(HermesFixtures.oldServerCapabilities) }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        do {
            try await provider.connect()
            XCTFail("old server must be rejected")
        } catch AgentError.providerUnavailable(let detail) {
            XCTAssertTrue(detail.contains("Live run events"))
        }
        XCTAssertEqual(provider.compatibility?.isCompatible, false)
    }

    func testFullTurnWithToolAndApproval() async throws {
        let transport = makeServer(events: [
            HermesFixtures.event(#"{"event":"tool.started","run_id":"run_42","tool":"terminal","preview":"df -h"}"#),
            HermesFixtures.event(#"{"event":"tool.completed","run_id":"run_42","tool":"terminal","duration":0.4,"error":false}"#),
            HermesFixtures.event(#"{"command":"rm -rf /var/tmp/cache","description":"recursive delete","event":"approval.request","run_id":"run_42","choices":["once","deny"]}"#),
            HermesFixtures.event(#"{"event":"approval.responded","run_id":"run_42","choice":"once","resolved":1}"#),
            HermesFixtures.event(#"{"event":"message.delta","run_id":"run_42","delta":"Disk is "}"#),
            HermesFixtures.event(#"{"event":"message.delta","run_id":"run_42","delta":"fine."}"#),
            HermesFixtures.event(#"{"event":"run.completed","run_id":"run_42","output":"Disk is fine.","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}"#)
        ])
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        try await provider.connect()
        let conversationID = UUID()
        let request = AgentRequest(conversationID: conversationID, content: "check disk",
                                   options: AgentRequestOptions(instructions: "You are the ops teammate."))
        let events = try await collect(provider.send(request))

        var message = Message(role: .assistant, content: "", state: .sending)
        for event in events { ChatReducer.apply(event, to: &message) }
        XCTAssertEqual(message.state, .complete)
        XCTAssertEqual(message.plainText, "Disk is fine.")
        XCTAssertEqual(message.runID, "run_42")
        XCTAssertEqual(message.toolCalls.first?.status, .succeeded)
        XCTAssertNil(message.pendingApproval)
        XCTAssertEqual(message.resolvedApprovals?.first?.command, "rm -rf /var/tmp/cache")

        // Session was created with the app prefix; the run went to that session.
        let sessionBody = try JSONDecoder().decode(JSONValue.self, from: transport.requests(matching: "POST /hermes/api/sessions")[0].body ?? Data())
        XCTAssertEqual(sessionBody["id"]?.stringValue, HermesAgentProvider.sessionID(for: conversationID))
        let runBody = try JSONDecoder().decode(JSONValue.self, from: transport.requests(matching: "POST /hermes/v1/runs")[0].body ?? Data())
        XCTAssertEqual(runBody["session_id"]?.stringValue, HermesAgentProvider.sessionID(for: conversationID))
        XCTAssertEqual(runBody["instructions"]?.stringValue, "You are the ops teammate.")
        XCTAssertEqual(transport.requests(matching: "POST /hermes/v1/runs")[0].headers["Idempotency-Key"], request.requestID.uuidString.lowercased())
    }

    func testDroppedStreamRecoversByPolling() async throws {
        let transport = makeServer(events: [HermesFixtures.event(#"{"event":"message.delta","delta":"Working"}"#)], afterEventsFail: true)
        let polls = Locked(0)
        transport.on("GET /hermes/v1/runs/run_42") { _ in
            let n = polls.withLock { $0 += 1; return $0 }
            if n < 3 { return MockHTTPTransport.json(#"{"object":"hermes.run","run_id":"run_42","status":"running"}"#) }
            return MockHTTPTransport.json(#"{"object":"hermes.run","run_id":"run_42","status":"completed","output":"Working on it — done."}"#)
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        try await provider.connect()
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "go")))
        var message = Message(role: .assistant, content: "", state: .sending)
        for event in events { ChatReducer.apply(event, to: &message) }
        XCTAssertEqual(message.state, .complete)
        XCTAssertEqual(message.plainText, "Working on it — done.")
        XCTAssertEqual(polls.current, 3)
    }

    func testExpiredRunStatusFailsHonestly() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/v1/runs/old") { _ in MockHTTPTransport.json(#"{"error":{"message":"Run not found: old","code":"run_not_found"}}"#, status: 404) }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let events = try await collect(provider.resume(runID: "old", alreadyStreamed: "partial"))
        guard case .failed(.remote(let code, _))? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(code, "run_expired")
    }

    func testStopSteerAndApprovalCallTheRightRoutes() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/v1/runs/r9/stop") { _ in MockHTTPTransport.json(#"{"run_id":"r9","status":"stopping"}"#) }
        transport.on("POST /hermes/v1/runs/r9/steer") { _ in MockHTTPTransport.json(#"{"object":"hermes.run.steer","run_id":"r9","accepted":true}"#) }
        transport.on("POST /hermes/v1/runs/r9/approval") { _ in MockHTTPTransport.json(#"{"object":"hermes.run.approval_response","run_id":"r9","choice":"deny","resolved":1}"#) }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        try await provider.stop(runID: "r9")
        try await provider.steer(runID: "r9", text: "  focus on nginx  ")
        let approval = AgentApproval(runID: "r9", command: "rm x", choices: ["once", "deny"], requestID: "req-1")
        try await provider.respond(to: approval, choice: .deny)
        do {
            try await provider.respond(to: approval, choice: .always)
            XCTFail("must refuse a choice the server did not offer")
        } catch AgentError.permissionDenied {}

        let steer = try JSONDecoder().decode(JSONValue.self, from: transport.requests(matching: "POST /hermes/v1/runs/r9/steer")[0].body ?? Data())
        XCTAssertEqual(steer["input"]?.stringValue, "focus on nginx")
        let answer = try JSONDecoder().decode(JSONValue.self, from: transport.requests(matching: "POST /hermes/v1/runs/r9/approval")[0].body ?? Data())
        XCTAssertEqual(answer["choice"]?.stringValue, "deny")
        XCTAssertEqual(answer["request_id"]?.stringValue, "req-1")
        XCTAssertEqual(transport.requests(matching: "POST /hermes/v1/runs/r9/approval").count, 1)
    }

    func testRunCreationFailureSurfacesError() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"error":{"message":"Session already exists: x","code":"session_exists"}}"#, status: 409) }
        transport.on("POST /hermes/v1/runs") { _ in MockHTTPTransport.json(#"{"error":{"message":"Too many concurrent runs","code":"too_many_runs"}}"#, status: 429) }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "x")))
        guard case .failed(.remote(let code, _))? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(code, "rate_limited")
    }

    func testSessionIDRoundTrip() {
        let id = UUID()
        let session = HermesAgentProvider.sessionID(for: id)
        XCTAssertTrue(session.hasPrefix("ios_"))
        XCTAssertEqual(HermesAgentProvider.conversationID(fromSessionID: session), id)
        XCTAssertNil(HermesAgentProvider.conversationID(fromSessionID: "agent:main:telegram:dm:1"))
    }
}

// MARK: - Teammates, mascots, run records

final class TeammateTests: XCTestCase {
    func testValidationAndInstructions() throws {
        var mate = Teammate(name: "Ops", role: "SRE", instructions: "Be careful.", mascot: MascotStyle(shape: .orb, hue: 0.2))
        XCTAssertNoThrow(try mate.validate())
        XCTAssertEqual(mate.runInstructions, "You are acting as the user's SRE (teammate name: Ops).\n\nBe careful.")
        mate.profile = "Bad Name"
        XCTAssertThrowsError(try mate.validate()) { XCTAssertEqual($0 as? Teammate.ValidationError, .invalidProfile) }
        mate.profile = "research-2"
        XCTAssertNoThrow(try mate.validate())
        mate.name = "   "
        XCTAssertThrowsError(try mate.validate())
        XCTAssertEqual(Teammate.starterTeam.count, 5)
        XCTAssertEqual(Set(Teammate.starterTeam.map(\.id)).count, 5)
    }

    func testApprovalScopeOnlyNarrowsChoices() {
        let all = ["once", "session", "always", "deny"]
        XCTAssertEqual(ApprovalScopeLimit.onceOnly.filter(all), ["once", "deny"])
        XCTAssertEqual(ApprovalScopeLimit.allowSession.filter(all), ["once", "session", "deny"])
        XCTAssertEqual(ApprovalScopeLimit.serverDefault.filter(["once", "deny"]), ["once", "deny"])
    }

    func testProfileNameRules() {
        XCTAssertTrue(HermesConfiguration.isValidProfileName("coder"))
        XCTAssertTrue(HermesConfiguration.isValidProfileName("ops_2-x"))
        XCTAssertFalse(HermesConfiguration.isValidProfileName("2coder"))
        XCTAssertFalse(HermesConfiguration.isValidProfileName("../etc"))
        XCTAssertFalse(HermesConfiguration.isValidProfileName("Coder"))
        XCTAssertFalse(HermesConfiguration.isValidProfileName(String(repeating: "a", count: 33)))
    }

    func testMascotMoodFollowsRealState() {
        let now = Date()
        var waiting = Message(role: .assistant, content: "", state: .streaming)
        waiting.pendingApproval = AgentApproval(runID: "r", command: "x", choices: ["once", "deny"])
        XCTAssertEqual(MascotMood.derive(status: .thinking, connected: true, latest: waiting, isActiveTeammate: true, now: now), .waitingApproval)
        let streaming = Message(role: .assistant, content: "x", state: .streaming)
        XCTAssertEqual(MascotMood.derive(status: .runningTool(name: "terminal"), connected: true, latest: streaming, isActiveTeammate: true, now: now), .working)
        XCTAssertEqual(MascotMood.derive(status: .streaming, connected: true, latest: streaming, isActiveTeammate: true, now: now), .thinking)
        let done = Message(role: .assistant, content: "x", createdAt: now.addingTimeInterval(-1), state: .complete)
        XCTAssertEqual(MascotMood.derive(status: .ready, connected: true, latest: done, isActiveTeammate: true, now: now), .happy)
        XCTAssertEqual(MascotMood.derive(status: .ready, connected: true, latest: done, isActiveTeammate: true, now: now.addingTimeInterval(30)), .idle)
        let failed = Message(role: .assistant, content: "x", createdAt: now, state: .failed(.cancelled))
        XCTAssertEqual(MascotMood.derive(status: .ready, connected: true, latest: failed, isActiveTeammate: false, now: now), .failed)
        XCTAssertEqual(MascotMood.derive(status: .ready, connected: false, latest: done, isActiveTeammate: true, now: now), .offline)
        XCTAssertEqual(MascotMood.derive(status: .ready, connected: true, latest: nil, isActiveTeammate: false, now: now), .idle)
    }

    func testRunRecordTimelineCoalescesAndKeepsTerminalState() {
        var record = RunRecord(id: "r", title: "Agent run")
        let t0 = Date()
        record = record.applying(RunActivity(runID: "r", sessionID: "s", title: "Check disk", state: .running, date: t0))
        record = record.applying(RunActivity(runID: "r", event: .messageDelta("Hel"), date: t0))
        record = record.applying(RunActivity(runID: "r", event: .messageDelta("lo"), date: t0))
        record = record.applying(RunActivity(runID: "r", event: .toolStarted(tool: "terminal", preview: "df"), date: t0))
        record = record.applying(RunActivity(runID: "r", event: .completed(output: "Hello", usage: nil, pendingSteer: nil), state: .completed, date: t0))
        record = record.applying(RunActivity(runID: "r", state: .running, date: t0)) // late non-terminal update ignored
        XCTAssertEqual(record.title, "Check disk")
        XCTAssertEqual(record.sessionID, "s")
        XCTAssertEqual(record.state, .completed)
        XCTAssertNotNil(record.finishedAt)
        XCTAssertEqual(record.timeline.map(\.kind), [.output, .toolStarted, .completed])
        XCTAssertEqual(record.timeline.first?.detail, "Hello")
        XCTAssertEqual(record.outputPreview, "Hello")
    }

    func testRunRecordsRoundTripThroughJSON() throws {
        let record = RunRecord(id: "r", conversationID: UUID(), title: "x", state: .waitingForApproval,
                               timeline: [RunTimelineEntry(kind: .approvalRequested, title: "Approval requested", detail: "rm")])
        let data = try JSONEncoder().encode([record])
        XCTAssertEqual(try JSONDecoder().decode([RunRecord].self, from: data), [record])
    }

    func testOldConversationsStillDecode() throws {
        // A conversation saved by the previous app version (no new fields).
        let id = UUID()
        let legacy = #"{"id":"\#(id.uuidString)","title":"Old","createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z","providerKind":"mock","messages":[{"id":"\#(UUID().uuidString)","role":"user","content":"hi","createdAt":"2026-10-01T10:00:00.000Z","state":{"complete":{}},"toolCalls":[]}]}"#
        let conversation = try WireCoding.decoder.decode(Conversation.self, from: Data(legacy.utf8))
        XCTAssertNil(conversation.backendSessionID)
        XCTAssertNil(conversation.messages.first?.runID)
    }
}
