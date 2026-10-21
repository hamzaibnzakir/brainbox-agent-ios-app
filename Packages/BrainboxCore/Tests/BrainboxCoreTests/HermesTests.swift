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
        // Hermes ends the source session when forking, so non-app sessions
        // are refused client-side — no request is ever sent.
        do {
            _ = try await client.forkSession(id: "agent:main:telegram:dm:42", title: "From Telegram")
            XCTFail("forking a Telegram session must be refused")
        } catch AgentError.permissionDenied {}
        XCTAssertTrue(transport.requests(matching: "POST /hermes/api/sessions/agent:main:telegram:dm:42/fork").isEmpty)
        transport.on("POST /hermes/api/sessions/ios_a/fork") { _ in MockHTTPTransport.json(#"{"object":"hermes.session","session":{"id":"fork_1","source":"api_server","parent_session_id":"ios_a"}}"#, status: 201) }
        let fork = try await client.forkSession(id: "ios_a", title: "Branch")
        XCTAssertEqual(fork.id, "fork_1")
        XCTAssertEqual(fork.parentSessionID, "ios_a")
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

final class HermesURLValidatorTests: XCTestCase {
    func testAcceptsHTTPSAndPrivateHTTPOnly() {
        XCTAssertEqual(HermesURLValidator.validate("https://vps.tail1234.ts.net:8444/hermes"), .valid(URL(string: "https://vps.tail1234.ts.net:8444/hermes")!))
        if case .invalid = HermesURLValidator.validate("http://100.101.102.103:8642") { XCTFail("tailscale http must be allowed") }
        if case .valid = HermesURLValidator.validate("http://example.com:8642") { XCTFail("public http must be refused") }
        if case .valid = HermesURLValidator.validate("wss://vps.ts.net") { XCTFail("ws schemes are not Hermes URLs") }
        if case .valid = HermesURLValidator.validate("https://user:pw@vps.ts.net") { XCTFail("credentials in URL must be refused") }
        if case .valid = HermesURLValidator.validate("https://vps.ts.net/hermes?key=x") { XCTFail("query must be refused") }
        if case .valid = HermesURLValidator.validate("  ") { XCTFail("empty must be refused") }
    }
}

final class HermesProfileRoutingTests: XCTestCase {
    func testTeammateOnAProfileRunsAndStopsThere() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/p/research/api/sessions") { _ in MockHTTPTransport.json(#"{"session":{"id":"ios_x"}}"#, status: 201) }
        transport.on("POST /hermes/p/research/v1/runs") { _ in MockHTTPTransport.json(#"{"run_id":"run_p","status":"started"}"#, status: 202) }
        transport.on("POST /hermes/p/research/v1/runs/run_p/stop") { _ in MockHTTPTransport.json(#"{"run_id":"run_p","status":"stopping"}"#) }
        transport.onStream("GET /hermes/p/research/v1/runs/run_p/events") { _ in
            MockHTTPTransport.sse([HermesFixtures.event(#"{"event":"message.delta","delta":"x"}"#)], delay: 0.05)
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let request = AgentRequest(conversationID: UUID(), content: "hi", options: AgentRequestOptions(profile: "research"))
        let stream = provider.send(request)
        var iterator = stream.makeAsyncIterator()
        var sawRun = false
        while let event = try await iterator.next() {
            if case .runStarted = event { sawRun = true; break }
        }
        XCTAssertTrue(sawRun)
        try await provider.stop(runID: "run_p")
        XCTAssertEqual(transport.requests(matching: "POST /hermes/p/research/v1/runs/run_p/stop").count, 1)
        XCTAssertTrue(transport.requests(matching: "POST /hermes/v1/runs").isEmpty)
    }
}


// MARK: - P0: carried history, session safety, early stop

/// Holds a mock request open until the test releases it.
final class TestGate: @unchecked Sendable {
    private let state = Locked<(open: Bool, arrived: Int, waiters: [CheckedContinuation<Void, Never>])>((false, 0, []))

    var arrivals: Int { state.withLock { $0.arrived } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                s.arrived += 1
                if s.open { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            let w = s.waiters
            s.waiters = []
            return w
        }
        waiters.forEach { $0.resume() }
    }
}

func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
}

final class CarriedHistoryTests: XCTestCase {
    private func conversation(_ messages: [Message]) -> Conversation {
        Conversation(providerKind: .hermes, messages: messages, carriesHistory: true)
    }

    func testDropsTheTurnBeingSentAndKeepsOrder() {
        let c = conversation([
            Message(role: .user, content: "first"),
            Message(role: .assistant, content: "reply one"),
            Message(role: .user, content: "current question"),
            Message(role: .assistant, content: "", state: .sending)
        ])
        XCTAssertEqual(CarriedHistory.build(from: c), [HistoryTurn(role: "user", content: "first"), HistoryTurn(role: "assistant", content: "reply one")])
    }

    func testSkipsFailedEmptySystemAndUnfinishedMessages() {
        let c = conversation([
            Message(role: .system, content: "note"),
            Message(role: .user, content: "  "),
            Message(role: .user, content: "kept"),
            Message(role: .assistant, content: "partial", state: .failed(.cancelled)),
            Message(role: .assistant, content: "streaming", state: .streaming),
            Message(role: .assistant, content: "kept too"),
            Message(role: .user, content: "now")
        ])
        XCTAssertEqual(CarriedHistory.build(from: c).map(\.content), ["kept", "kept too"])
    }

    func testCapsMessageCountAndCharactersFromTheOldestEnd() {
        let many = (0..<10).map { Message(role: $0 % 2 == 0 ? .user : .assistant, content: "m\($0)") } + [Message(role: .user, content: "now")]
        XCTAssertEqual(CarriedHistory.build(from: conversation(many), maxMessages: 3).map(\.content), ["m7", "m8", "m9"])
        let long = [Message(role: .user, content: String(repeating: "a", count: 60)),
                    Message(role: .assistant, content: String(repeating: "b", count: 60)),
                    Message(role: .user, content: "now")]
        XCTAssertEqual(CarriedHistory.build(from: conversation(long), maxCharacters: 100).map(\.content), [String(repeating: "b", count: 60)])
        let huge = [Message(role: .user, content: "x" + String(repeating: "y", count: 200)), Message(role: .user, content: "now")]
        let trimmed = CarriedHistory.build(from: conversation(huge), maxCharacters: 50)
        XCTAssertEqual(trimmed.count, 1)
        XCTAssertEqual(trimmed[0].content, String(repeating: "y", count: 50), "keeps the most recent part")
    }

    func testCarriesHistoryFlagRoundTripsAndOldFilesDecode() throws {
        let copy = conversation([Message(role: .user, content: "hi")])
        let decoded = try WireCoding.decoder.decode(Conversation.self, from: WireCoding.encoder.encode(copy))
        XCTAssertTrue(decoded.carriesHistory)
        let plain = Conversation(providerKind: .hermes)
        let json = String(decoding: try WireCoding.encoder.encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("carriedHistory"), "default conversations keep the old file shape")
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"Old","createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z","providerKind":"hermes","messages":[],"backendSessionID":"ios_abc"}"#
        XCTAssertFalse(try WireCoding.decoder.decode(Conversation.self, from: Data(legacy.utf8)).carriesHistory)
    }
}

final class HermesSessionSafetyTests: XCTestCase {
    private func server() -> MockHTTPTransport {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"object":"hermes.session","session":{"id":"ios_x","source":"api_server"}}"#, status: 201) }
        transport.on("POST /hermes/v1/runs") { _ in MockHTTPTransport.json(#"{"run_id":"run_42","status":"started"}"#, status: 202) }
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            MockHTTPTransport.sse([HermesFixtures.event(#"{"event":"run.completed","output":"ok"}"#)])
        }
        return transport
    }

    func testCreateRunSendsConversationHistoryOnlyWhenSet() async throws {
        let transport = server()
        let client = HermesFixtures.client(transport)
        _ = try await client.createRun(input: "a", options: .init(sessionID: "ios_x"))
        _ = try await client.createRun(input: "b", options: .init(sessionID: "ios_x", conversationHistory: []))
        _ = try await client.createRun(input: "c", options: .init(sessionID: "ios_x", conversationHistory: [
            HistoryTurn(role: "user", content: "from telegram"), HistoryTurn(role: "assistant", content: "answer")]))
        let bodies = try transport.requests(matching: "POST /hermes/v1/runs").map { try JSONDecoder().decode(JSONValue.self, from: $0.body ?? Data()) }
        XCTAssertNil(bodies[0]["conversation_history"])
        XCTAssertNil(bodies[1]["conversation_history"])
        guard case .array(let turns)? = bodies[2]["conversation_history"] else { return XCTFail("missing history") }
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0]["role"]?.stringValue, "user")
        XCTAssertEqual(turns[0]["content"]?.stringValue, "from telegram")
    }

    func testProviderRefusesToWriteToNonAppSessions() async throws {
        let transport = server()
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let request = AgentRequest(conversationID: UUID(), content: "hi",
                                   options: AgentRequestOptions(sessionID: "agent:main:telegram:dm:42"))
        let events = try await collect(provider.send(request))
        guard case .failed(.permissionDenied)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(transport.requests.isEmpty, "nothing may reach Hermes")
    }

    func testCopiedConversationRunsInItsOwnAppSessionWithHistory() async throws {
        let transport = server()
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let conversationID = UUID()
        let history = [HistoryTurn(role: "user", content: "telegram question"), HistoryTurn(role: "assistant", content: "telegram answer")]
        _ = try await collect(provider.send(AgentRequest(conversationID: conversationID, content: "continue",
                                                         options: AgentRequestOptions(conversationHistory: history))))
        let sessionBody = try JSONDecoder().decode(JSONValue.self, from: transport.requests(matching: "POST /hermes/api/sessions")[0].body ?? Data())
        XCTAssertEqual(sessionBody["id"]?.stringValue, HermesAgentProvider.sessionID(for: conversationID))
        let runBody = try JSONDecoder().decode(JSONValue.self, from: transport.requests(matching: "POST /hermes/v1/runs")[0].body ?? Data())
        XCTAssertEqual(runBody["session_id"]?.stringValue, HermesAgentProvider.sessionID(for: conversationID))
        guard case .array(let turns)? = runBody["conversation_history"] else { return XCTFail("history not sent") }
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(transport.requests.allSatisfy { !$0.url.path.contains("telegram") })
    }
}

final class HermesEarlyStopTests: XCTestCase {
    private func server(runGate: TestGate? = nil, sessionGate: TestGate? = nil) -> MockHTTPTransport {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/api/sessions") { _ in
            await sessionGate?.wait()
            return MockHTTPTransport.json(#"{"object":"hermes.session","session":{"id":"ios_x","source":"api_server"}}"#, status: 201)
        }
        transport.on("POST /hermes/v1/runs") { _ in
            await runGate?.wait()
            return MockHTTPTransport.json(#"{"run_id":"run_42","status":"started"}"#, status: 202)
        }
        transport.on("POST /hermes/v1/runs/run_42/stop") { _ in MockHTTPTransport.json(#"{"run_id":"run_42","status":"stopping"}"#) }
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            MockHTTPTransport.sse([HermesFixtures.event(#"{"event":"run.cancelled","run_id":"run_42"}"#)])
        }
        return transport
    }

    func testStopBeforeRunIDArrivesStopsTheRunWhenItDoes() async throws {
        let gate = TestGate()
        let transport = server(runGate: gate)
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let request = AgentRequest(conversationID: UUID(), content: "count to 300")
        let collector = Task { try await self.collect(provider.send(request)) }

        await waitFor { gate.arrivals == 1 }
        await provider.cancel(requestID: request.requestID)
        XCTAssertTrue(transport.requests(matching: "POST /hermes/v1/runs/run_42/stop").isEmpty, "no run id yet")
        gate.open()

        let events = try await collector.value
        XCTAssertEqual(transport.requests(matching: "POST /hermes/v1/runs/run_42/stop").count, 1)
        guard case .failed(.cancelled)? = events.last else { return XCTFail("\(events)") }
        XCTAssertNil(provider.runID(for: request.requestID), "bookkeeping cleaned up")
    }

    func testStopDuringSessionSetupNeverStartsARun() async throws {
        let gate = TestGate()
        let transport = server(sessionGate: gate)
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let request = AgentRequest(conversationID: UUID(), content: "hi")
        let collector = Task { try await self.collect(provider.send(request)) }

        await waitFor { gate.arrivals == 1 }
        await provider.cancel(requestID: request.requestID)
        gate.open()

        let events = try await collector.value
        guard case .failed(.cancelled)? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(transport.requests(matching: "POST /hermes/v1/runs").isEmpty, "the run was never created")
    }

    func testRunIsStoppedEvenIfTheAppStopsListeningMidCreate() async throws {
        let gate = TestGate()
        let transport = server(runGate: gate)
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let request = AgentRequest(conversationID: UUID(), content: "long job")
        let consumer = Task {
            var events: [AgentEvent] = []
            do { for try await event in provider.send(request) { events.append(event) } } catch {}
            return events
        }

        await waitFor { gate.arrivals == 1 }
        // What ChatStore.stop() does: ask to cancel, then stop consuming.
        await provider.cancel(requestID: request.requestID)
        consumer.cancel()
        gate.open()

        await waitFor { !transport.requests(matching: "POST /hermes/v1/runs/run_42/stop").isEmpty }
        XCTAssertEqual(transport.requests(matching: "POST /hermes/v1/runs/run_42/stop").count, 1,
                       "the run Hermes created must still be stopped")
        _ = await consumer.value
    }

    func testStopAfterRunIDStillStopsImmediately() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"session":{"id":"ios_x"}}"#, status: 201) }
        transport.on("POST /hermes/v1/runs") { _ in MockHTTPTransport.json(#"{"run_id":"run_42","status":"started"}"#, status: 202) }
        transport.on("POST /hermes/v1/runs/run_42/stop") { _ in MockHTTPTransport.json(#"{"run_id":"run_42","status":"stopping"}"#) }
        transport.onStream("GET /hermes/v1/runs/run_42/events") { _ in
            MockHTTPTransport.sse([HermesFixtures.event(#"{"event":"message.delta","delta":"1"}"#),
                                   HermesFixtures.event(#"{"event":"run.cancelled"}"#)], delay: 0.3)
        }
        let provider = HermesAgentProvider(client: HermesFixtures.client(transport), pause: { _ in })
        let request = AgentRequest(conversationID: UUID(), content: "go")
        let collector = Task { try await self.collect(provider.send(request)) }
        await waitFor { provider.runID(for: request.requestID) != nil }
        await provider.cancel(requestID: request.requestID)
        XCTAssertEqual(transport.requests(matching: "POST /hermes/v1/runs/run_42/stop").count, 1)
        _ = try await collector.value
    }
}
