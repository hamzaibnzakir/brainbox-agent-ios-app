import XCTest
import BrainboxCore
@testable import BrainboxAgent

@MainActor
final class ChatStoreTests: XCTestCase {
    private func makeStore(online: Bool = true, provider: AgentProvider = MockAgentProvider(configuration: .instant)) -> (ChatStore, InMemoryConversationStore) {
        let persistence = InMemoryConversationStore()
        let store = ChatStore(store: persistence, provider: { provider }, isOnline: { online })
        return (store, persistence)
    }

    private func waitUntilIdle(_ store: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isStreaming {
            if Date() > deadline { XCTFail("Chat never finished streaming"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testSendStreamsReplyAndPersists() async throws {
        let (store, persistence) = makeStore()
        store.send("check server status")
        XCTAssertTrue(store.isStreaming)
        try await waitUntilIdle(store)

        let conversation = try XCTUnwrap(store.current)
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0].role, .user)
        let reply = conversation.messages[1]
        XCTAssertEqual(reply.state, .complete)
        XCTAssertFalse(reply.toolCalls.isEmpty)
        XCTAssertTrue(reply.plainText.contains("mock agent"))
        XCTAssertEqual(conversation.title, "Server health check", "Provider-supplied titles replace the local one")

        let saved = try persistence.loadAll()
        XCTAssertEqual(saved.first?.messages.last?.state, .complete)
        XCTAssertFalse(store.recentTasks.isEmpty)
    }

    func testOfflineMessagesFailInsteadOfQueueing() async throws {
        let (store, _) = makeStore(online: false)
        store.send("restart nginx")
        XCTAssertFalse(store.isStreaming, "Nothing is queued while offline")
        XCTAssertEqual(store.current?.messages.last?.state, .failed(.offline))
    }

    func testRetryResendsPrompt() async throws {
        let (store, _) = makeStore()
        store.send("trigger an error")
        try await waitUntilIdle(store)
        let failed = try XCTUnwrap(store.current?.messages.last)
        guard case .failed = failed.state else { return XCTFail("Expected failure, got \(failed.state)") }

        store.retry(failed.id)
        try await waitUntilIdle(store)
        let messages = try XCTUnwrap(store.current?.messages)
        XCTAssertEqual(messages.count, 2, "Retry replaces the failed exchange instead of duplicating it")
        XCTAssertEqual(messages.first?.content, "trigger an error")
    }

    func testStopCancelsGeneration() async throws {
        let (store, _) = makeStore(provider: MockAgentProvider(configuration: .standard))
        store.send("run a long deploy")
        try await Task.sleep(nanoseconds: 300_000_000)
        store.stop()
        try await waitUntilIdle(store, timeout: 4)
        XCTAssertEqual(store.current?.messages.last?.state, .cancelled)
    }

    func testConversationManagement() {
        let (store, _) = makeStore()
        store.newConversation()
        let first = store.currentID
        store.newConversation()
        XCTAssertEqual(store.currentID, first, "Empty conversations are reused")
        store.send("hello")
        let id = try! XCTUnwrap(store.currentID)
        store.rename(id, to: "  Renamed  ")
        XCTAssertEqual(store.current?.title, "Renamed")
        store.delete(id)
        XCTAssertNil(store.conversations.first { $0.id == id })
    }

    func testHermesRunCarriesTeammateInstructionsAndSurfacesApproval() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/api/sessions") { _ in MockHTTPTransport.json(#"{"session":{"id":"ios_x","source":"api_server"}}"#, status: 201) }
        transport.on("POST /hermes/v1/runs") { _ in MockHTTPTransport.json(#"{"run_id":"run_7","status":"started"}"#, status: 202) }
        transport.on("POST /hermes/v1/runs/run_7/approval") { _ in MockHTTPTransport.json(#"{"run_id":"run_7","choice":"deny","resolved":1}"#) }
        transport.onStream("GET /hermes/v1/runs/run_7/events") { _ in
            MockHTTPTransport.sse([
                "data: {\"event\":\"approval.request\",\"command\":\"rm -rf /tmp/cache\",\"choices\":[\"once\",\"deny\"]}\n\n",
                "data: {\"event\":\"approval.responded\",\"choice\":\"deny\"}\n\n",
                "data: {\"event\":\"run.completed\",\"output\":\"I did not delete anything.\"}\n\n"
            ], delay: 0.15)
        }
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!, pollInterval: 0.01),
                                     transport: transport, tokenProvider: { "device-token-0123456789" })
        let provider = HermesAgentProvider(client: client, pause: { _ in })
        let (store, persistence) = makeStore(provider: provider)
        let teammate = Teammate(name: "Ops", role: "SRE", instructions: "Be careful.", mascot: MascotStyle(shape: .orb, hue: 0.1))
        store.requestOptions = { _ in AgentRequestOptions(instructions: teammate.runInstructions, teammateID: teammate.id) }
        store.activeTeammateID = { teammate.id }

        store.send("clear the cache")
        // The approval reaches the message while the run is blocked.
        let deadline = Date().addingTimeInterval(3)
        while store.pendingApprovals.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let pending = try XCTUnwrap(store.pendingApprovals.first)
        XCTAssertEqual(pending.approval.command, "rm -rf /tmp/cache")
        XCTAssertEqual(store.approvalSignal, 1)
        try await store.respond(to: pending.approval, choice: .deny)

        try await waitUntilIdle(store)
        let conversation = try XCTUnwrap(store.current)
        XCTAssertEqual(conversation.teammateID, teammate.id)
        XCTAssertEqual(conversation.backendSessionID, HermesAgentProvider.sessionID(for: conversation.id))
        let reply = try XCTUnwrap(conversation.messages.last)
        XCTAssertEqual(reply.state, .complete)
        XCTAssertEqual(reply.runID, "run_7")
        XCTAssertNil(reply.pendingApproval)
        XCTAssertEqual(reply.resolvedApprovals?.first?.choice, "deny")
        XCTAssertEqual(reply.plainText, "I did not delete anything.")

        let runBody = try JSONDecoder().decode(JSONValue.self, from: transport.requests(matching: "POST /hermes/v1/runs")[0].body ?? Data())
        XCTAssertEqual(runBody["instructions"]?.stringValue, teammate.runInstructions)
        XCTAssertEqual(try persistence.loadAll().first?.backendSessionID, conversation.backendSessionID)
    }

    func testInterruptedHermesReplyResumesByPolling() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/v1/runs/run_old") { _ in
            MockHTTPTransport.json(#"{"object":"hermes.run","run_id":"run_old","status":"completed","output":"Partial answer, now finished."}"#)
        }
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!, pollInterval: 0.01),
                                     transport: transport, tokenProvider: { "device-token-0123456789" })
        let provider = HermesAgentProvider(client: client, pause: { _ in })
        let conversationID = UUID()
        let saved = Conversation(id: conversationID, title: "Long task", providerKind: .hermes, messages: [
            Message(role: .user, content: "do the long thing"),
            Message(role: .assistant, content: "Partial answer", state: .streaming, runID: "run_old")
        ])
        let persistence = InMemoryConversationStore([saved])
        let store = ChatStore(store: persistence, provider: { provider }, isOnline: { true })
        XCTAssertEqual(store.current?.messages.last?.state, .failed(.webSocketDisconnected), "Interrupted on relaunch")
        store.resumeInterruptedRuns()
        let deadline = Date().addingTimeInterval(3)
        while store.current?.messages.last?.state != .complete && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.current?.messages.last?.state, .complete)
        XCTAssertEqual(store.current?.messages.last?.plainText, "Partial answer, now finished.")
    }

    func testConversationsAreGroupedByTeammate() {
        let (store, _) = makeStore()
        let a = UUID(), b = UUID()
        var current = a
        store.activeTeammateID = { current }
        store.newConversation()
        store.send("hello a")
        current = b
        store.newConversation()
        XCTAssertEqual(store.conversations(for: b).count, 1)
        XCTAssertEqual(store.conversations(for: a).count, 1)
        XCTAssertNotEqual(store.conversations(for: a).first?.id, store.conversations(for: b).first?.id)
    }
}

@MainActor
final class SettingsAndSecurityTests: XCTestCase {
    func testSettingsPersistIncludingHermes() {
        let suite = "bb.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.providerKind, .mock)
        settings.backendURL = "wss://gw.tail0000.ts.net/v1/agent"
        settings.sessionTimeout = nil
        settings.providerKind = .hermes
        settings.hermesURL = "https://vps.tail0000.ts.net:8444/hermes"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.backendURL, "wss://gw.tail0000.ts.net/v1/agent")
        XCTAssertNil(reloaded.sessionTimeout)
        XCTAssertEqual(reloaded.providerKind, .hermes)
        XCTAssertNotNil(reloaded.validatedBackendURL)
        XCTAssertNotNil(reloaded.validatedHermesURL)
        XCTAssertNil(defaults.string(forKey: "hermes.token"), "Secrets never go to UserDefaults")
        XCTAssertNil(defaults.string(forKey: "gateway.token"), "Secrets never go to UserDefaults")
    }

    func testBiometricGateBypassOnlyForTesting() async {
        let gate = BiometricGate(policy: { SecurityPolicy(biometricsEnabled: true) }, bypass: true)
        let allowed = await gate.authorize(.deleteFile)
        XCTAssertTrue(allowed)
        gate.noteBackgrounded()
        gate.noteForegrounded()
        XCTAssertFalse(gate.isLocked)
    }

    func testKeychainCredentialStoreRoundTrip() throws {
        let store = KeychainCredentialStore(service: "app.brainbox.agent.tests.\(UUID().uuidString)")
        do {
            try store.write("test-token-abcdefghijklmnop", for: .gatewayToken)
        } catch CredentialStoreError.unexpectedStatus(let status) where status == -34018 {
            throw XCTSkip("Keychain unavailable for unsigned simulator builds (errSecMissingEntitlement). Covered on signed device builds.")
        }
        XCTAssertEqual(try store.read(.gatewayToken), "test-token-abcdefghijklmnop")
        try store.write("test-token-rotated-000000000", for: .gatewayToken)
        XCTAssertEqual(try store.read(.gatewayToken), "test-token-rotated-000000000")
        try store.delete(.gatewayToken)
        XCTAssertNil(try store.read(.gatewayToken))
    }

    func testAppModelSwitchesProvidersThroughOneInterface() async throws {
        let model = AppModel(environment: LaunchEnvironment(isUITesting: false, isUnitTesting: true))
        model.start()
        XCTAssertEqual(model.agentDescriptor.kind, .mock)
        XCTAssertNotNil(model.suite.vps)

        model.switchProvider(to: .remote)
        XCTAssertEqual(model.agentDescriptor.name, "Remote Agent")
        XCTAssertNil(model.suite.files, "Unconfigured remote exposes nothing")

        model.settings.backendURL = "wss://gw.tail0000.ts.net/v1/agent"
        model.rebuildSuite()
        XCTAssertNotNil(model.suite.files, "Configured remote exposes gateway-backed providers")

        model.switchProvider(to: .hermes)
        XCTAssertFalse(model.isHermes, "Without URL + token Hermes stays unconfigured, never guessed")
        model.settings.hermesURL = "https://vps.tail0000.ts.net:8444/hermes"
        try model.saveHermesToken("device-token-abcdefghijklmnop")
        model.rebuildSuite()
        XCTAssertTrue(model.isHermes)
        XCTAssertEqual(model.agentDescriptor.kind, .hermes)
        XCTAssertNil(model.suite.vps, "Hermes exposes the agent only; server controls stay with the gateway")

        model.switchProvider(to: .mock)
        XCTAssertEqual(model.agentDescriptor.kind, .mock)
    }

    func testTeammateRequestOptionsRouteProfileAndInstructions() throws {
        let workspace = HermesWorkspace(teammateURL: nil, runsURL: nil)
        var mate = Teammate(name: "Researcher", role: "research analyst", instructions: "Cite sources.", model: "m-2",
                            profile: "research", mascot: MascotStyle(shape: .hexagon, hue: 0.6))
        try workspace.save(mate)
        workspace.activeTeammateID = mate.id
        let options = try XCTUnwrap(workspace.requestOptions(for: nil))
        XCTAssertEqual(options.profile, "research")
        XCTAssertEqual(options.model, "m-2")
        XCTAssertTrue(options.instructions?.contains("Cite sources.") ?? false)
        mate.name = ""
        XCTAssertThrowsError(try workspace.save(mate))
        workspace.delete(Teammate.mainAssistantID)
        XCTAssertNotNil(workspace.teammate(Teammate.mainAssistantID), "The main assistant can't be deleted")
    }
}

final class DesignSystemTests: XCTestCase {
    func testEveryMotionTokenHasAReducedVariant() {
        for token in MotionToken.allCases {
            XCTAssertEqual(Motion.animation(token, reduceMotion: true), Motion.reducedCrossfade, "\(token) must crossfade under Reduce Motion")
        }
        XCTAssertEqual(Motion.animation(.bouncy, reduceMotion: false), Motion.bouncy)
        XCTAssertNotEqual(Motion.animation(.bouncy, reduceMotion: false), Motion.reducedCrossfade)
        XCTAssertEqual(Motion.cappedStagger(100), Motion.cappedStagger(Motion.maxStaggeredItems - 1))
    }

    func testMotionStaggerStaysWithinBudget() {
        XCTAssertEqual(Motion.stagger(0), 0)
        XCTAssertEqual(Motion.stagger(2), 0.07, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(Motion.stagger(500), Motion.staggerBudget)
    }

    func testOrbModeReflectsConnectionFirst() {
        XCTAssertEqual(OrbMode(status: .streaming, connection: .connected), .streaming)
        XCTAssertEqual(OrbMode(status: .ready, connection: .reconnecting(attempt: 1, retryIn: 1)), .offline)
        XCTAssertEqual(OrbMode(status: .ready, connection: .failed(.timedOut)), .error)
        XCTAssertEqual(OrbMode(status: .runningTool(name: "x"), connection: .connected), .tool)
    }
}
