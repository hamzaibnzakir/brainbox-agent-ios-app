import XCTest
import BrainboxCore
@testable import BrainboxAgent

/// Composer submissions against a scripted Hermes + proxy: commands are routed,
/// never sent to the model as text; skills use Hermes' own message; images go
/// inline and are only marked sent once Hermes accepts the run.
@MainActor
final class ChatCommandTests: XCTestCase {
    private let catalog = HermesCommandCatalog(
        native: [.init(name: "compress", description: "Compress the conversation context", aliases: ["compact"])],
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
        XCTAssertEqual(await store.submit("//compress is just a word here"), .sent)
        try await idle(store)
        XCTAssertEqual(bodies.current.first?["input"]?.stringValue, "/compress is just a word here")
    }

    func testSkillCommandRunsHermesBuiltMessage() async throws {
        let (store, transport, bodies) = makeStore()
        XCTAssertEqual(await store.submit("/demo_skill go"), .sent)
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
        XCTAssertEqual(await store.submit("/help"), .handled(nil))
        XCTAssertEqual(store.current?.messages.last?.role, .system)
        XCTAssertTrue(store.current?.messages.last?.content.contains("/steer") ?? false)
        XCTAssertEqual(await store.submit("/stop"), .refused("Nothing is running."))
        XCTAssertEqual(await store.submit("/files"), .navigate(.files))
        XCTAssertEqual(await store.submit("/parallel a | b"), .parallel(["a", "b"]))
        XCTAssertTrue(bodies.current.isEmpty)
    }

    func testModelCommandIsValidatedAndUsedForRuns() async throws {
        let (store, _, bodies) = makeStore()
        guard case .refused = await store.submit("/model gpt-imaginary") else { return XCTFail("unknown model must be refused") }
        guard case .handled = await store.submit("/model claude-sonnet") else { return XCTFail() }
        XCTAssertEqual(store.current?.modelOverride, "claude-sonnet")
        XCTAssertEqual(await store.submit("hello"), .sent)
        try await idle(store)
        XCTAssertEqual(bodies.current.last?["model"]?.stringValue, "claude-sonnet")
    }

    func testImagesGoInlineAndAreMarkedSentOnlyAfterHermesAccepts() async throws {
        let (store, _, bodies) = makeStore()
        let dataURL = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="
        let attachment = MessageAttachment(name: "photo.jpg", kind: .image, byteCount: 12, status: .preparing)
        XCTAssertEqual(await store.submit("What is this?", attachments: [attachment], imageDataURLs: [dataURL]), .sent)
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
