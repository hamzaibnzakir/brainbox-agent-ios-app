import XCTest
import BrainboxCore
@testable import BrainboxAgent

/// Composer submissions against a scripted Hermes + proxy: commands are routed,
/// never sent to the model as text; skills use Hermes' own message; images go
/// inline and are only marked sent once Hermes accepts the run.
@MainActor
final class ChatCommandTests: XCTestCase {
    private let catalog = HermesCommandCatalog(
        native: [.init(name: "compress", description: "Compress the conversation context", aliases: ["compact"]),
                 .init(name: "version", description: "Show Hermes Agent version", aliases: ["v"], executor: true)],
        skills: [.init(name: "demo-skill", description: "Demo")])

    private func makeStore() -> (ChatStore, MockHTTPTransport, Locked<[JSONValue]>) {
        let transport = MockHTTPTransport()
        let bodies = Locked<[JSONValue]>([])
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"session":{"id":"ios_x","source":"api_server"}}"#, status: 201) }
        transport.on("POST /hermes/v1/runs") { request in
            if let body = try? JSONDecoder().decode(JSONValue.self, from: request.body ?? Data()) { bodies.withLock { $0.append(body) } }
            return MockHTTPTransport.json(#"{"run_id":"run_1","status":"started"}"#, status: 202)
        }
        transport.onStream("GET /hermes/v1/runs/run_1/events") { _ in
            MockHTTPTransport.sse(["data: {\"event\":\"run.completed\",\"output\":\"ok\"}\n\n"], delay: 0.05)
        }
        transport.on("POST /hermes/brainbox/commands/skill") { _ in
            MockHTTPTransport.json(#"{"object":"brainbox.skill_invocation","name":"demo-skill","message":"[IMPORTANT: The user has invoked the \"demo-skill\" skill] SKILL BODY\n\ngo"}"#)
        }
        transport.on("GET /hermes/v1/models") { _ in MockHTTPTransport.json(#"{"object":"list","data":[{"id":"hermes-agent"},{"id":"claude-sonnet"}]}"#) }
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!, pollInterval: 0.01),
                                     transport: transport, tokenProvider: { "device-token-0123456789" })
        let provider = HermesAgentProvider(client: client, pause: { _ in })
        let store = ChatStore(store: InMemoryConversationStore(), provider: { provider }, isOnline: { true })
        store.lifecycleClient = { client }
        store.commandCatalog = { [catalog] in catalog }
        // As in the app (HermesWorkspace.requestOptions): the chat's model override routes the run.
        store.requestOptions = { conversation in
            AgentRequestOptions(sessionID: conversation?.backendSessionID, model: conversation?.modelOverride)
        }
        return (store, transport, bodies)
    }

    private func idle(_ store: ChatStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isStreaming {
            if Date() > deadline { return XCTFail("still streaming") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testUnsupportedAndUnknownCommandsAreNeverSent() async throws {
        let (store, transport, bodies) = makeStore()
        for text in ["/compact", "/compress now", "/frobnicate", "/steer"] {
            let outcome = await store.submit(text)
            guard case .refused(let reason) = outcome else { return XCTFail("\(text): \(outcome)") }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertTrue(bodies.current.isEmpty, "no run was created")
        XCTAssertTrue(transport.requests.filter { $0.method == "POST" }.isEmpty)
    }

    func testEscapedSlashIsSentAsText() async throws {
        let (store, _, bodies) = makeStore()
        do { let outcome = await store.submit("//compress is just a word here"); XCTAssertEqual(outcome, .sent) }
        try await idle(store)
        XCTAssertEqual(bodies.current.first?["input"]?.stringValue, "/compress is just a word here")
    }

    func testSkillCommandRunsHermesBuiltMessage() async throws {
        let (store, transport, bodies) = makeStore()
        do { let outcome = await store.submit("/demo_skill go"); XCTAssertEqual(outcome, .sent) }
        try await idle(store)
        XCTAssertEqual(transport.requests(matching: "POST /hermes/brainbox/commands/skill").count, 1)
        let input = try XCTUnwrap(bodies.current.first?["input"]?.stringValue)
        XCTAssertTrue(input.hasPrefix("[IMPORTANT: The user has invoked"))
        let user = try XCTUnwrap(store.current?.messages.first { $0.role == .user })
        XCTAssertEqual(user.content, "/demo-skill go", "the chat shows what you typed")
        XCTAssertEqual(user.sentContent, input, "and records what was actually sent")
    }

    func testLocalCommandsProduceOutputAndAreNotSent() async throws {
        let (store, _, bodies) = makeStore()
        do { let outcome = await store.submit("/help"); XCTAssertEqual(outcome, .handled(nil)) }
        XCTAssertEqual(store.current?.messages.last?.role, .system)
        XCTAssertTrue(store.current?.messages.last?.content.contains("/steer") ?? false)
        do { let outcome = await store.submit("/stop"); XCTAssertEqual(outcome, .refused("Nothing is running.")) }
        do { let outcome = await store.submit("/files"); XCTAssertEqual(outcome, .navigate(.files)) }
        do { let outcome = await store.submit("/parallel a | b"); XCTAssertEqual(outcome, .parallel(["a", "b"])) }
        XCTAssertTrue(bodies.current.isEmpty)
    }

    func testHermesHandlerCommandsRunOnTheProxyNotTheModel() async throws {
        let (store, transport, bodies) = makeStore()
        transport.on("POST /hermes/brainbox/commands/run") { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
            switch body["name"]?.stringValue {
            case "version": return MockHTTPTransport.json(#"{"name":"version","text":"Hermes Agent v0.21.2","format":"plain"}"#)
            case "btw":
                XCTAssertTrue(body["session_id"]?.stringValue?.hasPrefix("ios_") ?? false)
                return MockHTTPTransport.json(#"{"name":"btw","text":"You picked nginx earlier.","format":"markdown"}"#)
            default: return MockHTTPTransport.json(#"{"error":{"message":"x","code":"unknown_command"}}"#, status: 404)
            }
        }
        do { let outcome = await store.submit("/v"); XCTAssertEqual(outcome, .handled(nil)) }
        XCTAssertTrue(store.current?.messages.last?.content.contains("Hermes Agent v0.21.2") ?? false)

        store.newConversation()
        guard case .handled = await store.submit("/btw what did we pick?") else { return XCTFail() }
        let deadline = Date().addingTimeInterval(3)
        while !(store.current?.messages.contains { $0.content.contains("You picked nginx") } ?? false) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.current?.messages.contains { $0.role == .system && $0.content.contains("You picked nginx") } ?? false)
        XCTAssertTrue(bodies.current.isEmpty, "neither command started a model run")
    }

    func testStatusAndUsageReadHermesSessionRecord() async throws {
        let (store, transport, _) = makeStore()
        store.newConversation()
        let id = try XCTUnwrap(store.currentID)
        transport.on("GET /hermes/api/sessions/\(HermesAgentProvider.sessionID(for: id))") { _ in
            MockHTTPTransport.json(#"{"object":"hermes.session","session":{"id":"ios_x","model":"claude-sonnet","title":"Deploy","input_tokens":1200,"output_tokens":300,"message_count":4,"estimated_cost_usd":0.0123}}"#)
        }
        guard case .handled = await store.submit("/status") else { return XCTFail() }
        let status = try XCTUnwrap(store.current?.messages.last?.content)
        XCTAssertTrue(status.contains("Model: claude-sonnet") && status.contains("Tokens: 1,500") && status.contains("Agent running: no"), status)
        guard case .handled = await store.submit("/usage") else { return XCTFail() }
        XCTAssertTrue(store.current?.messages.last?.content.contains("Input tokens: 1,200") ?? false)
    }

    func testBackgroundCommandRunsSeparately() async throws {
        let (store, _, bodies) = makeStore()
        store.newConversation()
        let origin = try XCTUnwrap(store.currentID)
        let outcome = await store.submit("/bg summarise the logs")
        XCTAssertEqual(outcome, .background(prompt: "summarise the logs", origin: origin))
        XCTAssertTrue(bodies.current.isEmpty, "the current chat's session isn't used")
        // When the background task settles, its result is posted back once.
        var agent = ParallelAgent(title: "s", prompt: "summarise the logs")
        agent.state = .completed
        agent.output = "Logs are clean."
        let task = ParallelTask(title: "Background", agents: [agent], wantsSynthesis: false, originConversationID: origin)
        store.deliverBackgroundResult(task)
        store.deliverBackgroundResult(task)
        let posted = store.current?.messages.filter { $0.content.contains("Logs are clean.") } ?? []
        XCTAssertEqual(posted.count, 1)
    }

    /// A run whose event stream stays open until `release` is set.
    private func longRunStore(busyMode: String?) -> (ChatStore, MockHTTPTransport, Locked<[JSONValue]>, Locked<Bool>) {
        let (store, transport, bodies) = makeStore()
        let release = Locked(false)
        transport.onStream("GET /hermes/v1/runs/run_1/events") { _ in
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    continuation.yield(Data("id: 1\ndata: {\"event\":\"message.delta\",\"run_id\":\"run_1\",\"delta\":\"working\"}\n\n".utf8))
                    while !release.current && !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                    continuation.yield(Data("id: 2\ndata: {\"event\":\"run.completed\",\"run_id\":\"run_1\",\"output\":\"working\"}\n\n".utf8))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return HTTPStreamResponse(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: stream)
        }
        store.busyInputMode = { busyMode }
        return (store, transport, bodies, release)
    }

    func testMessageWhileBusyFollowsTelegramsQueueMode() async throws {
        let (store, _, bodies, release) = longRunStore(busyMode: "queue")
        let started = await store.submit("start the long job")
        XCTAssertEqual(started, .sent)
        let deadline = Date().addingTimeInterval(3)
        while store.activeRunID == nil && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard case .handled(let ack) = await store.submit("and then summarise") else { return XCTFail("not applied") }
        XCTAssertTrue(ack?.contains("Queued") ?? false)
        XCTAssertEqual(store.queuedInstructions[store.currentID!]?.map(\.text), ["and then summarise"])
        XCTAssertEqual(bodies.current.count, 1, "nothing extra was sent while the reply runs")
        release.withLock { $0 = true }
        let sentLater = Date().addingTimeInterval(5)
        while bodies.current.count < 2 && Date() < sentLater { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(bodies.current.last?["input"]?.stringValue, "and then summarise", "sent once, after the reply ended")
        release.withLock { $0 = true }
    }

    func testMessageWhileBusyWithUnknownModeIsRefusedNotLost() async throws {
        let (store, _, bodies, release) = longRunStore(busyMode: nil)
        let started = await store.submit("start")
        XCTAssertEqual(started, .sent)
        let deadline = Date().addingTimeInterval(3)
        while bodies.current.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard case .refused = await store.submit("follow-up") else { return XCTFail() }
        XCTAssertEqual(bodies.current.count, 1)
        release.withLock { $0 = true }
    }

    func testDoubleTappedCommandRunsOnce() async throws {
        let (store, transport, _) = makeStore()
        let calls = Locked(0)
        transport.on("POST /hermes/brainbox/commands/run") { _ in
            calls.withLock { $0 += 1 }
            try await Task.sleep(nanoseconds: 100_000_000)
            return MockHTTPTransport.json(#"{"name":"version","text":"v1","format":"plain"}"#)
        }
        async let first = store.submit("/version")
        async let second = store.submit("/version")
        _ = await (first, second)
        XCTAssertEqual(calls.current, 1)
    }

    func testModelCommandIsValidatedAndUsedForRuns() async throws {
        let (store, _, bodies) = makeStore()
        guard case .refused = await store.submit("/model gpt-imaginary") else { return XCTFail("unknown model must be refused") }
        guard case .handled = await store.submit("/model claude-sonnet") else { return XCTFail() }
        XCTAssertEqual(store.current?.modelOverride, "claude-sonnet")
        do { let outcome = await store.submit("hello"); XCTAssertEqual(outcome, .sent) }
        try await idle(store)
        XCTAssertEqual(bodies.current.last?["model"]?.stringValue, "claude-sonnet")
    }

    func testImagesGoInlineAndAreMarkedSentOnlyAfterHermesAccepts() async throws {
        let (store, _, bodies) = makeStore()
        let dataURL = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="
        let attachment = MessageAttachment(name: "photo.jpg", kind: .image, byteCount: 12, status: .preparing)
        do { let outcome = await store.submit("What is this?", attachments: [attachment], imageDataURLs: [dataURL]); XCTAssertEqual(outcome, .sent) }
        try await idle(store)
        let input = try XCTUnwrap(bodies.current.first?["input"])
        XCTAssertEqual(input[0]?["role"]?.stringValue, "user")
        XCTAssertEqual(input[0]?["content"]?[0]?["text"]?.stringValue, "What is this?")
        XCTAssertEqual(input[0]?["content"]?[1]?["image_url"]?["url"]?.stringValue, dataURL)
        let user = try XCTUnwrap(store.current?.messages.first { $0.role == .user })
        XCTAssertEqual(user.attachments?.first?.status, .sent)
        XCTAssertNil(user.sentContent)
    }

    func testCommandsCantCarryAttachments() async {
        let (store, _, _) = makeStore()
        let attachment = MessageAttachment(name: "a.txt", kind: .file, byteCount: 3, serverPath: "/w/inbox/a.txt", status: .uploaded)
        guard case .refused = await store.submit("/help", attachments: [attachment]) else { return XCTFail() }
    }
}
