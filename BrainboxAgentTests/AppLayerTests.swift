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

    func testHermesPendingProviderFailsClearly() async throws {
        let (store, _) = makeStore(provider: HermesProvider())
        store.send("hi")
        try await waitUntilIdle(store)
        guard case .failed(.notImplemented) = store.current?.messages.last?.state else {
            return XCTFail("Hermes must report pending integration")
        }
    }
}

@MainActor
final class SettingsAndSecurityTests: XCTestCase {
    func testSettingsPersistAndNeverBootIntoHermes() {
        let suite = "bb.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.providerKind, .mock)
        settings.backendURL = "wss://gw.tail0000.ts.net/v1/agent"
        settings.sessionTimeout = nil
        settings.providerKind = .hermes

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.backendURL, "wss://gw.tail0000.ts.net/v1/agent")
        XCTAssertNil(reloaded.sessionTimeout)
        XCTAssertEqual(reloaded.providerKind, .mock, "Pending Hermes provider is never restored on launch")
        XCTAssertNotNil(reloaded.validatedBackendURL)
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

        model.switchProvider(to: .mock)
        XCTAssertEqual(model.agentDescriptor.kind, .mock)
    }
}

final class DesignSystemTests: XCTestCase {
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
