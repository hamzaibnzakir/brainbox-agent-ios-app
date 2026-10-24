import XCTest
import BrainboxCore
@testable import BrainboxAgent

/// Archive / restore / permanent delete against a scripted gateway + Hermes.
/// Synthetic ids and data only; nothing here talks to a real server.
@MainActor
final class ChatLifecycleTests: XCTestCase {
    private let base = "https://vps.example.ts.net/hermes"

    private func client(_ transport: MockHTTPTransport) -> HermesAPIClient {
        HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: base)!), transport: transport,
                        tokenProvider: { "device-token-0123456789" })
    }

    private func hermesConversation(title: String = "Trip plan", origin: String? = nil, copy: Bool = false) -> Conversation {
        let id = UUID()
        return Conversation(id: id, title: title, providerKind: .hermes,
                            messages: [Message(role: .user, content: "plan a trip"), Message(role: .assistant, content: "Sure.")],
                            backendSessionID: copy ? nil : HermesAgentProvider.sessionID(for: id), origin: origin, carriesHistory: copy)
    }

    private func makeStore(_ conversations: [Conversation], transport: MockHTTPTransport, online: Bool = true)
        -> (ChatStore, InMemoryConversationStore) {
        let persistence = InMemoryConversationStore(conversations)
        let store = ChatStore(store: persistence, provider: { MockAgentProvider(configuration: .instant) }, isOnline: { online })
        let api = client(transport)
        store.lifecycleClient = { api }
        return (store, persistence)
    }

    nonisolated private func deleted(_ id: String, chain: [String] = []) -> HTTPResponse {
        let sessions = (chain + [id]).map { "\"\($0)\"" }.joined(separator: ",")
        return MockHTTPTransport.json(#"{"object":"brainbox.session.deleted","id":"\#(id)","deleted_sessions":[\#(sessions)],"files_removed":3,"verified":true}"#)
    }

    private func nonGET(_ transport: MockHTTPTransport) -> [String] {
        transport.requests.filter { $0.method != "GET" }.map { "\($0.method) \($0.url.path)" }
    }

    // MARK: Delete permanently

    func testDeletePermanentlyRemovesFromServerThenDevice() async throws {
        let conversation = hermesConversation()
        let serverID = try XCTUnwrap(conversation.backendSessionID)
        let transport = MockHTTPTransport()
        transport.on("DELETE /hermes/brainbox/sessions/\(serverID)") { [self] _ in deleted(serverID, chain: ["20261022_cont"]) }
        let (store, persistence) = makeStore([conversation], transport: transport)

        let result = try await store.deletePermanently(conversation.id)

        guard case .deletedEverywhere(let info) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(info.deletedSessions, ["20261022_cont", serverID])
        XCTAssertTrue(info.verified)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(try persistence.loadAll().isEmpty, "gone after a restart too")
        // Only the gateway's verified delete — never Hermes' raw DELETE.
        XCTAssertEqual(nonGET(transport), ["DELETE /hermes/brainbox/sessions/\(serverID)"])
    }

    func testBackendFailureKeepsTheChatAndReportsIt() async throws {
        let conversation = hermesConversation()
        let serverID = try XCTUnwrap(conversation.backendSessionID)
        let transport = MockHTTPTransport()
        transport.on("DELETE /hermes/brainbox/sessions/\(serverID)") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"Hermes did not delete the whole conversation. Nothing was reported as deleted; try again.","code":"delete_failed"}}"#, status: 502)
        }
        let (store, persistence) = makeStore([conversation], transport: transport)

        do {
            try await store.deletePermanently(conversation.id)
            XCTFail("must not claim success")
        } catch AgentError.remote(let code, let message) {
            XCTAssertEqual(code, "delete_failed")
            XCTAssertTrue(message.contains("try again"))
        }
        XCTAssertEqual(store.conversations.map(\.id), [conversation.id], "local copy is not hidden on failure")
        XCTAssertEqual(try persistence.loadAll().count, 1)
        XCTAssertFalse(store.isBusy(conversation.id))
    }

    func testOfflineDeleteChangesNothing() async throws {
        let conversation = hermesConversation()
        let transport = MockHTTPTransport()
        let (store, persistence) = makeStore([conversation], transport: transport, online: false)
        do {
            try await store.deletePermanently(conversation.id)
            XCTFail("offline delete must not succeed")
        } catch AgentError.providerUnavailable(let detail) {
            XCTAssertTrue(detail.contains("Nothing was changed"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try persistence.loadAll().count, 1)
    }

    func testAnotherDevicesChatAndMissingGatewayAreRefused() async throws {
        let mine = hermesConversation()
        let other = hermesConversation(title: "Other")
        let transport = MockHTTPTransport()
        transport.on("DELETE /hermes/brainbox/sessions/\(mine.backendSessionID!)") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"This conversation belongs to another device.","code":"session_not_owned"}}"#, status: 403)
        }
        // A server without the gateway: plain 404 with no Brainbox error code.
        transport.on("DELETE /hermes/brainbox/sessions/\(other.backendSessionID!)") { _ in
            HTTPResponse(status: 404, body: Data("404: Not Found".utf8))
        }
        let (store, _) = makeStore([mine, other], transport: transport)
        do { try await store.deletePermanently(mine.id); XCTFail() } catch AgentError.permissionDenied(let detail) {
            XCTAssertTrue(detail.contains("another device"))
        }
        do { try await store.deletePermanently(other.id); XCTFail() } catch AgentError.providerUnavailable(let detail) {
            XCTAssertTrue(detail.contains("nothing was changed"))
        }
        XCTAssertEqual(store.conversations.count, 2)
    }

    func testChatTheServerNeverHadIsDeletedLocallyWithAnHonestMessage() async throws {
        let conversation = hermesConversation()
        let transport = MockHTTPTransport()
        transport.on("DELETE /hermes/brainbox/sessions/\(conversation.backendSessionID!)") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"This conversation no longer exists on Hermes.","code":"session_not_found"}}"#, status: 404)
        }
        let (store, _) = makeStore([conversation], transport: transport)
        let result = try await store.deletePermanently(conversation.id)
        XCTAssertEqual(result, .notOnServer)
        XCTAssertTrue(result.message.contains("no copy"))
        XCTAssertTrue(store.conversations.isEmpty)
    }

    func testTelegramCopyOnlyEverTouchesItsOwnAppSession() async throws {
        // A copy of a Telegram chat carries history and runs under its own ios_ id.
        let copy = hermesConversation(title: "Groceries (Telegram copy)", origin: "telegram", copy: true)
        let appID = HermesAgentProvider.sessionID(for: copy.id)
        let transport = MockHTTPTransport()
        transport.on("DELETE /hermes/brainbox/sessions/\(appID)") { [self] _ in deleted(appID) }
        let (store, _) = makeStore([copy], transport: transport)
        _ = try await store.deletePermanently(copy.id)
        XCTAssertEqual(nonGET(transport), ["DELETE /hermes/brainbox/sessions/\(appID)"])
        XCTAssertTrue(nonGET(transport).allSatisfy { $0.contains("/ios_") })
    }

    func testDeviceOnlyChatsNeedNoServer() async throws {
        let local = Conversation(title: "Mock chat", providerKind: .mock, messages: [Message(role: .user, content: "hi")])
        let transport = MockHTTPTransport()
        let (store, persistence) = makeStore([local], transport: transport, online: false)
        let result = try await store.deletePermanently(local.id)
        guard case .deviceOnly(let note) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(note.contains("only stored on this device"))
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(try persistence.loadAll().isEmpty)
    }

    func testClientRefusesIdsThatAreNotAppSessions() async {
        let api = client(MockHTTPTransport())
        for bad in ["20261022_101010_abcd", "cron_a1b2c3_20261022_090000", "ios_../../state.db", "ios_" + String(repeating: "A", count: 32)] {
            do { _ = try await api.deleteAppSession(id: bad); XCTFail(bad) } catch AgentError.permissionDenied {}
            catch { XCTFail("\(bad): \(error)") }
            do { _ = try await api.setArchived(true, sessionID: bad); XCTFail(bad) } catch AgentError.permissionDenied {}
            catch { XCTFail("\(bad): \(error)") }
        }
    }

    // MARK: Archive / restore

    func testArchiveAndRestorePersistAcrossRestart() async throws {
        let conversation = hermesConversation()
        let serverID = conversation.backendSessionID!
        let transport = MockHTTPTransport()
        let bodies = Locked<[String]>([])
        transport.on("PATCH /hermes/api/sessions/\(serverID)") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            bodies.withLock { $0.append(body) }
            let archived = body.contains("true")
            return MockHTTPTransport.json(#"{"session":{"id":"\#(serverID)","source":"api_server","archived":\#(archived)}}"#)
        }
        let (store, persistence) = makeStore([conversation], transport: transport)

        try await store.archive(conversation.id)
        XCTAssertTrue(store.activeConversations.isEmpty, "hidden from the main list")
        XCTAssertEqual(store.archivedEntries.map(\.localID), [conversation.id])
        XCTAssertNil(store.currentID, "the archived chat is no longer the current chat")

        // Relaunch: the archived flag is on disk.
        let relaunched = ChatStore(store: persistence, provider: { MockAgentProvider(configuration: .instant) }, isOnline: { true })
        XCTAssertEqual(relaunched.conversations.first?.isArchived, true)
        XCTAssertNil(relaunched.currentID, "an archived chat isn't reopened as the current chat")

        try await store.restore(conversation.id)
        XCTAssertEqual(store.activeConversations.map(\.id), [conversation.id])
        XCTAssertEqual(try persistence.loadAll().first?.isArchived, false)
        XCTAssertEqual(bodies.current.count, 2)
        XCTAssertTrue(bodies.current[0].contains(#""archived":true"#))
        XCTAssertTrue(bodies.current[1].contains(#""archived":false"#))
        XCTAssertEqual(nonGET(transport), ["PATCH /hermes/api/sessions/\(serverID)", "PATCH /hermes/api/sessions/\(serverID)"])
    }

    func testOfflineArchiveIsRefused() async throws {
        let conversation = hermesConversation()
        let (store, _) = makeStore([conversation], transport: MockHTTPTransport(), online: false)
        do { try await store.archive(conversation.id); XCTFail() } catch AgentError.providerUnavailable {}
        XCTAssertFalse(store.conversations[0].isArchived)
    }

    func testSyncAppliesServerArchiveStateAndListsServerOnlyChats() async throws {
        let archivedElsewhere = hermesConversation(title: "Archived on iPad")
        let restoredElsewhere: Conversation = {
            var c = hermesConversation(title: "Restored elsewhere")
            c.archivedAt = Date(timeIntervalSince1970: 1)
            return c
        }()
        let untouched = hermesConversation(title: "Not listed (other profile)")
        let serverOnly = "ios_" + String(repeating: "c", count: 32)
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/brainbox/sessions") { request in
            if request.url.query?.contains("state=archived") == true {
                return MockHTTPTransport.json(#"{"object":"list","state":"archived","data":[{"id":"\#(archivedElsewhere.backendSessionID!)","title":"Archived on iPad","archived":true,"owned":true},{"id":"\#(serverOnly)","title":"Old reinstall chat","archived":true,"owned":false,"last_active":1760000000}],"has_more":false}"#)
            }
            return MockHTTPTransport.json(#"{"object":"list","state":"active","data":[{"id":"\#(restoredElsewhere.backendSessionID!)","archived":false,"owned":true}],"has_more":false}"#)
        }
        let (store, persistence) = makeStore([archivedElsewhere, restoredElsewhere, untouched], transport: transport)
        await store.syncArchiveState()

        XCTAssertNil(store.archiveSyncError)
        XCTAssertEqual(store.conversations.first { $0.id == archivedElsewhere.id }?.isArchived, true)
        XCTAssertEqual(store.conversations.first { $0.id == restoredElsewhere.id }?.isArchived, false)
        XCTAssertEqual(store.conversations.first { $0.id == untouched.id }?.isArchived, false, "absence proves nothing")
        let entries = store.archivedEntries
        XCTAssertEqual(Set(entries.map(\.id)), [archivedElsewhere.backendSessionID!, serverOnly])
        XCTAssertNil(entries.first { $0.id == serverOnly }?.localID)
        XCTAssertEqual(ArchivedChatEntry.search(entries, "reinstall").map(\.id), [serverOnly])
        XCTAssertEqual(try persistence.loadAll().filter(\.isArchived).count, 1)
        XCTAssertTrue(nonGET(transport).isEmpty, "sync is read-only")
    }

    func testDeleteIsRefusedWhileAReplyIsStreaming() async throws {
        let transport = MockHTTPTransport()
        let persistence = InMemoryConversationStore()
        let slow = MockAgentProvider(configuration: .standard)
        let store = ChatStore(store: persistence, provider: { slow }, isOnline: { true })
        let api = client(transport)
        store.lifecycleClient = { api }
        store.send("write a long essay")
        let id = try XCTUnwrap(store.currentID)
        XCTAssertTrue(store.hasReplyInProgress(id))
        do { try await store.deletePermanently(id); XCTFail() } catch AgentError.permissionDenied {}
        XCTAssertTrue(transport.requests.isEmpty)
        store.stop()
    }
}
