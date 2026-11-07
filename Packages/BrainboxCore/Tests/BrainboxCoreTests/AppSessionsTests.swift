import XCTest
@testable import BrainboxCore

/// Chat archive / delete plumbing (synthetic data; shapes from the Brainbox gateway
/// and hermes-agent 284d220).
final class AppSessionsTests: XCTestCase {
    private func hermes(_ id: UUID = UUID(), archivedAt: Date? = nil, sessionID: String? = nil) -> Conversation {
        var c = Conversation(id: id, title: "Chat", providerKind: .hermes, messages: [Message(role: .user, content: "hi")],
                             backendSessionID: sessionID ?? HermesAgentProvider.sessionID(for: id))
        c.archivedAt = archivedAt
        return c
    }

    func testAppSessionIDValidation() {
        let good = HermesAgentProvider.sessionID(for: UUID())
        XCTAssertTrue(AppSessionID.isValid(good))
        for bad in ["", "ios_", "ios_abc", "ios_" + String(repeating: "A", count: 32), "ios_" + String(repeating: "a", count: 33),
                    "ios_" + String(repeating: "a", count: 30) + "/.", "cron_abc_20261022_090000", "20261022_101010_ab12cd"] {
            XCTAssertFalse(AppSessionID.isValid(bad), bad)
        }
        XCTAssertNil(AppSessionID.serverID(for: Conversation(title: "m", providerKind: .mock)))
        XCTAssertNil(AppSessionID.serverID(for: hermes(sessionID: "20261022_telegram_x")), "never a non-app session")
    }

    func testOldSavedConversationsDecodeWithoutArchiveFlag() throws {
        let json = #"{"id":"6F1C2B9A-3D4E-4F50-8A6B-7C8D9E0F1A2B","title":"Old","createdAt":0,"updatedAt":0,"providerKind":"hermes","messages":[]}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isArchived)
        var archived = decoded
        archived.archivedAt = Date(timeIntervalSince1970: 100)
        let round = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(archived))
        XCTAssertTrue(round.isArchived)
    }

    func testCompressedAppConversationIsClassifiedByItsLineageRoot() throws {
        let root = "ios_" + String(repeating: "d", count: 32)
        let json = #"{"id":"20261022_101500_9f8e7d","source":"api_server","title":"Long chat","_lineage_root_id":"\#(root)"}"#
        let session = try JSONDecoder().decode(HermesSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.conversationRootID, root)
        XCTAssertEqual(session.sourceKind, .ios)
        let telegram = try JSONDecoder().decode(HermesSession.self, from: Data(#"{"id":"tg_1","source":"telegram"}"#.utf8))
        XCTAssertEqual(telegram.conversationRootID, "tg_1")
        XCTAssertEqual(telegram.sourceKind, .telegram)
    }

    func testGatewayPayloadsDecode() throws {
        let page = try JSONDecoder().decode(BrainboxAppSessionPage.self, from: Data(#"{"object":"list","state":"archived","data":[{"id":"ios_x","title":null,"archived":true,"owned":false,"message_count":4,"last_active":1760000000.5}],"has_more":true}"#.utf8))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.sessions.first?.messageCount, 4)
        XCTAssertEqual(page.sessions.first?.displayTitle, "Untitled conversation")
        XCTAssertFalse(page.sessions[0].owned)
        let deletion = try JSONDecoder().decode(BrainboxSessionDeletion.self, from: Data(#"{"object":"brainbox.session.deleted","id":"ios_x","deleted_sessions":["c2","c1","ios_x"],"files_removed":4,"verified":true}"#.utf8))
        XCTAssertEqual(deletion.deletedSessions.last, "ios_x")
        XCTAssertEqual(deletion.filesRemoved, 4)
    }

    func testReconcileOnlyChangesListedConversations() {
        var conversations = [hermes(), hermes(archivedAt: Date(timeIntervalSince1970: 5)), hermes(), Conversation(title: "m", providerKind: .mock)]
        let ids = conversations.map { AppSessionID.serverID(for: $0) }
        let changed = ArchiveSync.reconcile(&conversations, active: [ids[1]!], archived: [ids[0]!], now: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(Set(changed), [conversations[0].id, conversations[1].id])
        XCTAssertEqual(conversations[0].archivedAt, Date(timeIntervalSince1970: 9))
        XCTAssertNil(conversations[1].archivedAt)
        XCTAssertNil(conversations[2].archivedAt, "not listed → untouched")
        XCTAssertNil(conversations[3].archivedAt)
        // Idempotent.
        XCTAssertTrue(ArchiveSync.reconcile(&conversations, active: [ids[1]!], archived: [ids[0]!]).isEmpty)
    }

    func testArchivedEntriesMergeLocalAndServerAndSearch() {
        let local = hermes(archivedAt: Date())
        var activeLocal = hermes()
        activeLocal.title = "Active"
        let localServerID = AppSessionID.serverID(for: local)!
        let serverOnly = BrainboxAppSession(id: "ios_" + String(repeating: "e", count: 32), title: "Budget review", lastActive: 1_000, archived: true)
        let entries = ArchivedChatEntry.merge(local: [local, activeLocal],
                                              server: [BrainboxAppSession(id: localServerID, archived: true), serverOnly])
        XCTAssertEqual(entries.count, 2, "a local archived chat and its server copy are one row")
        XCTAssertEqual(entries.first { $0.id == localServerID }?.localID, local.id)
        XCTAssertNotNil(entries.first { $0.id == localServerID }?.server)
        XCTAssertNil(entries.first { $0.id == serverOnly.id }?.localID)
        XCTAssertEqual(ArchivedChatEntry.search(entries, "budget").map(\.id), [serverOnly.id])
        XCTAssertEqual(ArchivedChatEntry.search(entries, "  ").count, 2)
    }

    func testDeleteClientMapsGatewayAnswers() async throws {
        let id = "ios_" + String(repeating: "f", count: 32)
        let transport = MockHTTPTransport()
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!),
                                     transport: transport, tokenProvider: { "device-token-0123456789" })
        transport.on("DELETE /hermes/brainbox/sessions/\(id)") { _ in
            MockHTTPTransport.json(#"{"object":"brainbox.session.deleted","id":"\#(id)","deleted_sessions":["\#(id)"],"files_removed":0,"verified":false}"#)
        }
        do { _ = try await client.deleteAppSession(id: id); XCTFail("unverified must not count") } catch AgentError.remote(let code, _) {
            XCTAssertEqual(code, "delete_unverified")
        }
        transport.on("DELETE /hermes/brainbox/sessions/\(id)") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"Hermes' session database can't be read right now, so nothing was deleted.","code":"session_store_unavailable"}}"#, status: 503)
        }
        do { _ = try await client.deleteAppSession(id: id); XCTFail() } catch AgentError.remote(let code, let message) {
            XCTAssertEqual(code, "session_store_unavailable")
            XCTAssertTrue(message.contains("nothing was deleted"))
        }
        // Other profiles aren't managed by the gateway's chat endpoints.
        let profiled = client.with(profile: "research")
        do { _ = try await profiled.deleteAppSession(id: id); XCTFail() } catch AgentError.providerUnavailable {}
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertFalse(transport.requests.contains { $0.url.path.hasPrefix("/hermes/api/sessions") }, "never Hermes' raw delete")
    }
}
