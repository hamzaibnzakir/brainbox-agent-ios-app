import Foundation

// Archive, restore and permanent deletion of the app's own conversations.
//
// Permanent deletion goes through the Brainbox gateway (`DELETE /brainbox/sessions/{id}`),
// never Hermes' raw delete: the gateway also removes the conversation's compression
// continuations and the transcript / request-dump files Hermes' HTTP delete leaves behind,
// checks that this device owns the conversation, and verifies nothing remains before it
// answers. The gateway refuses the raw route, so a partial delete can't happen by accident.

/// One of the app's own conversations as the gateway lists it (`ios_` roots only).
public struct BrainboxAppSession: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    public var startedAt: Double?
    public var lastActive: Double?
    public var messageCount: Int?
    public var archived: Bool
    /// False for a conversation created before ownership was recorded (claimable).
    public var owned: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, archived, owned
        case startedAt = "started_at"
        case lastActive = "last_active"
        case messageCount = "message_count"
    }

    public init(id: String, title: String? = nil, startedAt: Double? = nil, lastActive: Double? = nil,
                messageCount: Int? = nil, archived: Bool = false, owned: Bool = true) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.archived = archived
        self.owned = owned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        startedAt = HermesDecoding.number(c, .startedAt)
        lastActive = HermesDecoding.number(c, .lastActive)
        messageCount = HermesDecoding.number(c, .messageCount).map { Int($0) }
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
        owned = (try? c.decodeIfPresent(Bool.self, forKey: .owned)) ?? false
    }

    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return "Untitled conversation"
    }

    public var lastActivity: Date? { (lastActive ?? startedAt).map { Date(timeIntervalSince1970: $0) } }

    /// As a `HermesSession`, for the existing open/import paths.
    public var asSession: HermesSession {
        HermesSession(id: id, source: "api_server", title: title, startedAt: startedAt, messageCount: messageCount,
                      lastActive: lastActive, archived: archived)
    }
}

public struct BrainboxAppSessionPage: Decodable, Hashable, Sendable {
    public var sessions: [BrainboxAppSession]
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey { case data, hasMore = "has_more" }

    public init(sessions: [BrainboxAppSession], hasMore: Bool) {
        self.sessions = sessions
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? c.decode([BrainboxAppSession].self, forKey: .data)) ?? []
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
    }
}

/// What the gateway confirmed it removed.
public struct BrainboxSessionDeletion: Decodable, Hashable, Sendable {
    public var id: String
    /// The conversation plus its compression continuations, in delete order.
    public var deletedSessions: [String]
    /// Transcript / request-dump files removed from Hermes' sessions folder.
    public var filesRemoved: Int
    public var verified: Bool

    enum CodingKeys: String, CodingKey {
        case id, verified
        case deletedSessions = "deleted_sessions"
        case filesRemoved = "files_removed"
    }

    public init(id: String, deletedSessions: [String], filesRemoved: Int, verified: Bool) {
        self.id = id
        self.deletedSessions = deletedSessions
        self.filesRemoved = filesRemoved
        self.verified = verified
    }
}

public enum AppSessionDeletionOutcome: Hashable, Sendable {
    /// The gateway deleted the conversation and verified nothing remains.
    case deleted(BrainboxSessionDeletion)
    /// The server confirmed it has no such conversation (e.g. never sent).
    case notOnServer
}

public enum AppSessionListState: String, Sendable {
    case active, archived
}

/// Exactly the ids `HermesAgentProvider.sessionID(for:)` creates.
public enum AppSessionID {
    public static func isValid(_ id: String) -> Bool {
        guard id.hasPrefix(HermesSessionSource.appSessionPrefix) else { return false }
        let hex = id.dropFirst(HermesSessionSource.appSessionPrefix.count)
        return hex.count == 32 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// The server session a local conversation is (or would be) stored under,
    /// or nil when it isn't one of the app's own Hermes conversations.
    public static func serverID(for conversation: Conversation) -> String? {
        guard conversation.providerKind == .hermes else { return nil }
        let id = conversation.backendSessionID ?? HermesAgentProvider.sessionID(for: conversation.id)
        return isValid(id) ? id : nil
    }
}

extension HermesAPIClient {
    private var isDefaultProfile: Bool {
        configuration.profile.map { $0.isEmpty || $0 == "default" } ?? true
    }

    private func requireGatewaySessions() throws {
        guard isDefaultProfile else {
            throw AgentError.providerUnavailable(detail: "Archiving and deleting chats is only available for the default Hermes profile.")
        }
    }

    /// The app's own conversations (active or archived), newest first.
    public func appSessions(state: AppSessionListState, limit: Int = 200, offset: Int = 0) async throws -> BrainboxAppSessionPage {
        try requireGatewaySessions()
        let response = try await unchecked("GET", "/brainbox/sessions",
                                           query: ["state": state.rawValue, "limit": String(limit), "offset": String(offset)])
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        return try decode(BrainboxAppSessionPage.self, from: response)
    }

    /// Archives or restores one of the app's own conversations (Hermes `archived` flag).
    @discardableResult
    public func setArchived(_ archived: Bool, sessionID: String) async throws -> HermesSession {
        guard AppSessionID.isValid(sessionID) else {
            throw AgentError.permissionDenied(detail: "Only the app's own conversations can be archived.")
        }
        try requireGatewaySessions()
        return try await updateSession(id: sessionID, archived: archived)
    }

    /// Permanently deletes one of the app's own conversations through the gateway.
    public func deleteAppSession(id: String) async throws -> AppSessionDeletionOutcome {
        guard AppSessionID.isValid(id) else {
            throw AgentError.permissionDenied(detail: "Only the app's own conversations can be deleted.")
        }
        try requireGatewaySessions()
        let response = try await unchecked("DELETE", "/brainbox/sessions/\(Self.escape(id))", timeout: 60)
        if (200..<300).contains(response.status) {
            let result = try decode(BrainboxSessionDeletion.self, from: response)
            guard result.verified, result.id == id else {
                throw AgentError.remote(code: "delete_unverified", message: "The server didn't confirm the deletion.")
            }
            return .deleted(result)
        }
        if response.status == 404, Self.errorCode(response.body) == "session_not_found" { return .notOnServer }
        throw Self.sessionError(response)
    }

    static func errorCode(_ body: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body), let error = json["error"] else { return nil }
        return error["code"]?.stringValue
    }

    /// Gateway errors keep their own code and message (a 5xx here means "nothing
    /// or not everything was deleted", which must not read as a plain outage).
    static func sessionError(_ response: HTTPResponse) -> AgentError {
        guard let code = errorCode(response.body) else {
            if response.status == 404 || response.status == 405 {
                return .providerUnavailable(detail: "Your server doesn't have the Brainbox gateway's chat management yet, so nothing was changed.")
            }
            return error(status: response.status, body: response.body)
        }
        let message = (try? JSONDecoder().decode(JSONValue.self, from: response.body))?["error"]?["message"]?.stringValue ?? "HTTP \(response.status)"
        switch response.status {
        case 401: return error(status: 401, body: response.body)
        case 403: return .permissionDenied(detail: message)
        default: return .remote(code: code, message: message)
        }
    }
}

// MARK: - Keeping the local list in step with the server

public enum ArchiveSync {
    /// Applies the server's archived flags to local conversations. Only
    /// conversations the server listed are touched; one missing from both lists
    /// (another profile, or past the first page) keeps its local state, since
    /// absence is not proof of anything. Returns the ids that changed.
    public static func reconcile(_ conversations: inout [Conversation], active: Set<String>, archived: Set<String>,
                                 now: Date = Date()) -> [UUID] {
        var changed: [UUID] = []
        for index in conversations.indices {
            guard let serverID = AppSessionID.serverID(for: conversations[index]) else { continue }
            if archived.contains(serverID), conversations[index].archivedAt == nil {
                conversations[index].archivedAt = now
                changed.append(conversations[index].id)
            } else if active.contains(serverID), conversations[index].archivedAt != nil {
                conversations[index].archivedAt = nil
                changed.append(conversations[index].id)
            }
        }
        return changed
    }
}

/// A row on the Archived Chats screen: a local archived conversation, an
/// archived server conversation with no copy on this device, or both.
public struct ArchivedChatEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var preview: String
    public var archivedAt: Date?
    public var lastActivity: Date?
    public var localID: UUID?
    public var server: BrainboxAppSession?

    /// Local archived conversations first matched to their server copy, then
    /// server-only ones; newest activity first.
    public static func merge(local: [Conversation], server: [BrainboxAppSession]) -> [ArchivedChatEntry] {
        var serverByID = Dictionary(server.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [ArchivedChatEntry] = local.filter(\.isArchived).map { conversation in
            let serverID = AppSessionID.serverID(for: conversation)
            let match = serverID.flatMap { serverByID.removeValue(forKey: $0) }
            return ArchivedChatEntry(id: serverID ?? conversation.id.uuidString, title: conversation.title,
                                     preview: conversation.preview, archivedAt: conversation.archivedAt,
                                     lastActivity: conversation.updatedAt, localID: conversation.id, server: match)
        }
        entries += server.filter { serverByID[$0.id] != nil }.map { session in
            ArchivedChatEntry(id: session.id, title: session.displayTitle, preview: "", archivedAt: nil,
                              lastActivity: session.lastActivity, localID: nil, server: session)
        }
        return entries.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    public static func search(_ entries: [ArchivedChatEntry], _ query: String) -> [ArchivedChatEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.preview.localizedCaseInsensitiveContains(needle) }
    }
}
