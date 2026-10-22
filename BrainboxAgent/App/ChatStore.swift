import SwiftUI
import BrainboxCore

/// Conversation state for the Agent screen. Talks only to `AgentProvider`,
/// so it behaves identically for Mock, Remote and (later) Hermes.
@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation] = []
    var currentID: UUID?
    private(set) var activeRequestID: UUID?
    private(set) var activeMessageID: UUID?
    private(set) var loadError: String?

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private let store: ConversationStore
    @ObservationIgnored var provider: () -> AgentProvider
    @ObservationIgnored var isOnline: () -> Bool
    /// Called when a reply finishes (used for haptics / notifications).
    @ObservationIgnored var onReplyFinished: ((Message) -> Void)?
    /// Backend routing for a conversation (teammate instructions, session).
    @ObservationIgnored var requestOptions: (Conversation?) -> AgentRequestOptions? = { _ in nil }
    /// Teammate new conversations are created for.
    @ObservationIgnored var activeTeammateID: () -> UUID? = { nil }
    /// Bumped whenever an approval request arrives (drives haptics/sheet).
    private(set) var approvalSignal = 0
    @ObservationIgnored private var resumeTasks: [UUID: Task<Void, Never>] = [:]

    // Archive / permanent delete (server-confirmed; see "Lifecycle" below).
    /// The Hermes client for chat management (always the default profile), or
    /// nil when not connected to Hermes.
    @ObservationIgnored var lifecycleClient: () -> HermesAPIClient? = { nil }
    /// Archived conversations on the server (including ones with no copy here).
    private(set) var serverArchived: [BrainboxAppSession] = []
    private(set) var archiveSyncError: String?
    /// Conversations with an archive / restore / delete request in flight.
    private(set) var busyConversations: Set<UUID> = []

    init(store: ConversationStore, provider: @escaping () -> AgentProvider, isOnline: @escaping () -> Bool) {
        self.store = store
        self.provider = provider
        self.isOnline = isOnline
        do {
            // Anything still "in flight" on disk was interrupted (app killed mid-stream).
            conversations = try store.loadAll().map { conversation in
                var c = conversation
                for i in c.messages.indices where !c.messages[i].state.isTerminal {
                    c.messages[i].state = .failed(.webSocketDisconnected)
                }
                return c
            }
        } catch {
            loadError = "Saved conversations could not be read."
        }
        currentID = conversations.first { !$0.isArchived }?.id
    }

    var current: Conversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    var isStreaming: Bool { activeRequestID != nil }

    /// Recent tool calls across conversations, newest first (Home → Recent tasks).
    var recentTasks: [(call: ToolCall, conversation: String)] {
        conversations.prefix(10).flatMap { conversation in
            conversation.messages.flatMap { message in message.toolCalls.map { (call: $0, conversation: conversation.title) } }
        }
        .sorted { $0.call.startedAt > $1.call.startedAt }
        .prefix(6)
        .map { $0 }
    }

    // MARK: Conversations

    func newConversation() {
        stopIfNeeded()
        let teammate = activeTeammateID()
        // Reuse an existing empty conversation instead of piling them up.
        if let empty = conversations.first(where: { $0.messages.isEmpty && !$0.isArchived && $0.teammateID == teammate }) {
            currentID = empty.id
            return
        }
        let conversation = Conversation(providerKind: provider().descriptor.kind, teammateID: teammate)
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
    }

    /// Conversations that belong to a teammate (untagged ones belong to the main assistant).
    func conversations(for teammateID: UUID) -> [Conversation] {
        conversations.filter { !$0.isArchived && ($0.teammateID ?? Teammate.mainAssistantID) == teammateID }
    }

    /// The main chat list: everything that isn't archived.
    var activeConversations: [Conversation] { conversations.filter { !$0.isArchived } }

    /// Archived Chats screen rows (local archived + server-only archived).
    var archivedEntries: [ArchivedChatEntry] { ArchivedChatEntry.merge(local: conversations, server: serverArchived) }

    /// The teammate's latest assistant message (drives its mascot mood).
    func latestReply(for teammateID: UUID) -> Message? {
        conversations(for: teammateID).first?.messages.last(where: { $0.role == .assistant })
    }

    /// Adds a conversation built from a transcript. `sessionID` binds it to
    /// one of the app's own `ios_` sessions; `carriesHistory` makes every run
    /// re-send the transcript (copies of Telegram and other sources, which
    /// get a fresh `ios_` session on first send).
    func importConversation(title: String, sessionID: String?, origin: String, teammateID: UUID?, messages: [Message], carriesHistory: Bool) {
        stopIfNeeded()
        let conversation = Conversation(title: title, providerKind: provider().descriptor.kind, messages: messages,
                                        backendSessionID: sessionID, teammateID: teammateID, origin: origin,
                                        carriesHistory: carriesHistory)
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
        persist(conversation.id)
    }

    /// User and assistant text from a Hermes transcript, as local messages.
    static func importable(_ transcript: [HermesMessage]) -> [Message] {
        transcript.compactMap { m in
            guard m.role == "user" || m.role == "assistant", !m.content.isEmpty else { return nil }
            return Message(role: m.role == "user" ? .user : .assistant, content: m.content, createdAt: m.date ?? Date(), state: .complete)
        }
    }

    /// "Continue in the app" for a session the app doesn't own (Telegram, CLI,
    /// other API clients). Makes a local copy that re-sends the transcript with
    /// every run and gets its own `ios_` session on first send. No request is
    /// made here: the original session was only read (GET) and is never
    /// forked, written or ended.
    func continueAsCopy(of session: HermesSession, transcript: [HermesMessage], teammateID: UUID?) {
        let title = String("\(session.displayTitle) (\(session.sourceKind.displayName) copy)".prefix(80))
        importConversation(title: title, sessionID: nil, origin: session.sourceKind.rawValue, teammateID: teammateID,
                           messages: Self.importable(transcript), carriesHistory: true)
    }

    /// Opens one of the app's own `ios_` sessions, re-attaching to the same
    /// session id when there's no local copy (e.g. after a reinstall); Hermes
    /// then loads its history itself. Non-app sessions go to `continueAsCopy`.
    func reopenOwnSession(_ session: HermesSession, transcript: [HermesMessage], teammateID: UUID?, archived: Bool = false) {
        guard session.sourceKind == .ios else {
            continueAsCopy(of: session, transcript: transcript, teammateID: teammateID)
            return
        }
        // A compressed conversation is listed under its newest continuation;
        // the app's conversation is always bound to the original `ios_` id.
        let rootID = session.conversationRootID
        if openConversation(boundTo: rootID) { return }
        importConversation(title: session.displayTitle, sessionID: rootID, origin: HermesSessionSource.ios.rawValue,
                           teammateID: teammateID, messages: Self.importable(transcript), carriesHistory: false)
        if archived, let id = currentID {
            mutateConversation(id) { $0.archivedAt = Date() }
            persist(id)
        }
    }

    /// Opens the local conversation bound to a backend session, if any.
    @discardableResult
    func openConversation(boundTo sessionID: String) -> Bool {
        guard let match = conversations.first(where: { $0.backendSessionID == sessionID }) else { return false }
        select(match.id)
        return true
    }

    // MARK: Run controls (server-side run backends)

    private var runController: RunControllingProvider? { provider() as? RunControllingProvider }

    var canSteer: Bool {
        guard let runController, activeRunID != nil else { return false }
        return runController.compatibility?.supports(.steer) ?? false
    }

    var activeRunID: String? {
        guard let requestID = activeRequestID else { return nil }
        if let id = runController?.runID(for: requestID) { return id }
        guard let conversation = current, let messageID = activeMessageID else { return nil }
        return conversation.messages.first { $0.id == messageID }?.runID
    }

    func steer(_ text: String) async throws {
        guard let runController, let runID = activeRunID else { return }
        try await runController.steer(runID: runID, text: text)
    }

    func respond(to approval: AgentApproval, choice: HermesApprovalChoice) async throws {
        guard let runController else { throw AgentError.providerUnavailable(detail: "Approvals need the Hermes backend.") }
        try await runController.respond(to: approval, choice: choice)
    }

    /// Pending approvals across all conversations (Tasks + Team badges).
    var pendingApprovals: [(conversationID: UUID, approval: AgentApproval)] {
        var result: [(conversationID: UUID, approval: AgentApproval)] = []
        for conversation in conversations {
            for message in conversation.messages {
                if let approval = message.pendingApproval { result.append((conversationID: conversation.id, approval: approval)) }
            }
        }
        return result
    }

    /// After a relaunch or reconnect: re-attach to replies whose run may
    /// still be going on the server, by polling the run's status.
    func resumeInterruptedRuns() {
        guard let runController else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for conversation in conversations {
            guard let message = conversation.messages.last, message.role == .assistant, let runID = message.runID,
                  message.createdAt > cutoff, message.id != activeMessageID, resumeTasks[message.id] == nil else { continue }
            guard case .failed(let error) = message.state, error == .webSocketDisconnected || error == .offline else { continue }
            let conversationID = conversation.id
            let messageID = message.id
            mutateMessage(conversationID, messageID) { $0.state = .streaming }
            let stream = runController.resume(runID: runID, alreadyStreamed: message.plainText)
            resumeTasks[messageID] = Task { [weak self] in
                do {
                    for try await event in stream {
                        guard let self else { return }
                        self.apply(event, conversationID: conversationID, messageID: messageID)
                    }
                } catch {
                    self?.apply(.failed(error.asAgentError), conversationID: conversationID, messageID: messageID)
                }
                guard let self else { return }
                self.resumeTasks[messageID] = nil
                self.persist(conversationID)
            }
        }
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        stopIfNeeded()
        currentID = id
    }

    /// Removes the conversation from this device only. Callers decide (and
    /// say) whether the server copy is gone; see `deletePermanently`.
    private func removeFromDevice(_ id: UUID) {
        if id == currentID { stopIfNeeded() }
        conversations.removeAll { $0.id == id }
        try? store.delete(id)
        if currentID == id { currentID = activeConversations.first?.id }
    }

    // MARK: Lifecycle: archive, restore, delete permanently

    enum DeletionResult: Equatable {
        /// The server deleted the conversation and verified nothing remains.
        case deletedEverywhere(BrainboxSessionDeletion)
        /// The server confirmed it never had this conversation.
        case notOnServer
        /// Never stored on a server this app can manage; removed from this device.
        case deviceOnly(String)

        var message: String {
            switch self {
            case .deletedEverywhere: return "Deleted from this device and from your server."
            case .notOnServer: return "Deleted. Your server had no copy of this chat."
            case .deviceOnly(let note): return note
            }
        }
    }

    func isBusy(_ id: UUID) -> Bool { busyConversations.contains(id) }

    /// True while a reply for this conversation is streaming or being resumed.
    func hasReplyInProgress(_ id: UUID) -> Bool {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return false }
        if activeRequestID != nil, conversation.messages.contains(where: { $0.id == activeMessageID }) { return true }
        return conversation.messages.contains { resumeTasks[$0.id] != nil }
    }

    /// Server-side work needs a live connection to the default Hermes profile.
    /// Nothing is queued offline: the user retries once connected.
    private func managementClient(for conversation: Conversation, action: String) throws -> HermesAPIClient {
        if let profile = requestOptions(conversation)?.profile, !profile.isEmpty, profile != "default" {
            throw AgentError.providerUnavailable(detail: "Chats on the “\(profile)” profile can't be \(action) from the app yet. Nothing was changed.")
        }
        guard isOnline(), let client = lifecycleClient() else {
            throw AgentError.providerUnavailable(detail: "Connect to your Hermes server to \(action == "deleted" ? "delete this chat permanently" : "change this chat"). Nothing was changed.")
        }
        return client.with(profile: nil)
    }

    /// Deletes the conversation from the server (through the Brainbox gateway,
    /// which also removes its continuations and leftover files and verifies the
    /// result) and only then from this device. On any failure nothing local is
    /// removed and the error is thrown for the UI to show.
    @discardableResult
    func deletePermanently(_ id: UUID) async throws -> DeletionResult {
        guard let conversation = conversations.first(where: { $0.id == id }) else { throw AgentError.remote(code: "not_found", message: "That chat no longer exists.") }
        guard !busyConversations.contains(id) else { throw AgentError.remote(code: "busy", message: "This chat is already being changed.") }
        guard !hasReplyInProgress(id) else {
            throw AgentError.permissionDenied(detail: "Stop the reply (or let it finish) before deleting this chat.")
        }
        guard let serverID = AppSessionID.serverID(for: conversation) else {
            removeFromDevice(id)
            return .deviceOnly(conversation.providerKind == .remote
                ? "Deleted from this device. This connection type has no server-side chat deletion, so anything that server kept is untouched."
                : "Deleted. This chat was only stored on this device.")
        }
        let client = try managementClient(for: conversation, action: "deleted")
        busyConversations.insert(id)
        defer { busyConversations.remove(id) }
        let outcome = try await client.deleteAppSession(id: serverID)
        removeFromDevice(id)
        serverArchived.removeAll { $0.id == serverID }
        switch outcome {
        case .deleted(let result): return .deletedEverywhere(result)
        case .notOnServer: return .notOnServer
        }
    }

    /// Permanently deletes an archived server conversation that has no copy on this device.
    func deletePermanently(serverSession session: BrainboxAppSession) async throws {
        guard isOnline(), let client = lifecycleClient()?.with(profile: nil) else {
            throw AgentError.providerUnavailable(detail: "Connect to your Hermes server to delete this chat permanently. Nothing was changed.")
        }
        _ = try await client.deleteAppSession(id: session.id)
        serverArchived.removeAll { $0.id == session.id }
        if let local = conversations.first(where: { AppSessionID.serverID(for: $0) == session.id }) { removeFromDevice(local.id) }
    }

    func archive(_ id: UUID) async throws { try await setArchived(true, id) }
    func restore(_ id: UUID) async throws { try await setArchived(false, id) }

    private func setArchived(_ archived: Bool, _ id: UUID) async throws {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        guard !busyConversations.contains(id) else { return }
        if let serverID = AppSessionID.serverID(for: conversation) {
            let client = try managementClient(for: conversation, action: archived ? "archived" : "restored")
            busyConversations.insert(id)
            defer { busyConversations.remove(id) }
            do {
                try await client.setArchived(archived, sessionID: serverID)
            } catch AgentError.remote(let code, _) where code == "not_found" {
                // Hermes has no such session (nothing was ever sent): the
                // archive state only exists on this device.
            }
            if !archived { serverArchived.removeAll { $0.id == serverID } }
        }
        if archived, id == currentID { stopIfNeeded() }
        mutateConversation(id) { $0.archivedAt = archived ? Date() : nil }
        persist(id)
        if archived, currentID == id { currentID = activeConversations.first?.id }
    }

    /// Restores an archived server conversation with no copy on this device.
    func restore(serverSession session: BrainboxAppSession) async throws {
        guard isOnline(), let client = lifecycleClient()?.with(profile: nil) else {
            throw AgentError.providerUnavailable(detail: "Connect to your Hermes server to restore this chat. Nothing was changed.")
        }
        try await client.setArchived(false, sessionID: session.id)
        serverArchived.removeAll { $0.id == session.id }
    }

    /// Re-reads archived state from the server and applies it to local chats.
    func syncArchiveState() async {
        guard isOnline(), let client = lifecycleClient()?.with(profile: nil) else { return }
        do {
            async let activePage = client.appSessions(state: .active)
            async let archivedPage = client.appSessions(state: .archived)
            let (active, archived) = try await (activePage, archivedPage)
            serverArchived = archived.sessions
            archiveSyncError = nil
            let changed = ArchiveSync.reconcile(&conversations, active: Set(active.sessions.map(\.id)),
                                                archived: Set(archived.sessions.map(\.id)))
            for id in changed { persist(id) }
            if let currentID, changed.contains(currentID), current?.isArchived == true {
                self.currentID = activeConversations.first?.id
            }
        } catch {
            archiveSyncError = error.asAgentError.message
        }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateConversation(id) { $0.title = trimmed }
        persist(id)
    }

    func deleteAll() {
        stopIfNeeded()
        conversations.removeAll()
        try? store.deleteAll()
        currentID = nil
    }

    // MARK: Sending

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        if current == nil { newConversation() }
        guard let conversationID = currentID else { return }

        let user = Message(role: .user, content: text)
        let assistant = Message(role: .assistant, content: "", state: .sending)
        mutateConversation(conversationID) { conversation in
            if conversation.messages.isEmpty || conversation.title == Conversation.untitled {
                conversation.title = Conversation.suggestedTitle(from: text)
            }
            conversation.messages.append(user)
            conversation.messages.append(assistant)
            conversation.updatedAt = Date()
            conversation.providerKind = provider().descriptor.kind
        }
        moveToTop(conversationID)

        // Offline: never queue. The user explicitly retries when back online.
        guard isOnline() else {
            mutateMessage(conversationID, assistant.id) { $0.state = .failed(.offline) }
            persist(conversationID)
            return
        }

        let request = AgentRequest(conversationID: conversationID, responseMessageID: assistant.id, content: text,
                                   options: requestOptions(conversations.first { $0.id == conversationID }))
        activeRequestID = request.requestID
        activeMessageID = assistant.id
        persist(conversationID)

        let agent = provider()
        streamTask = Task { [weak self] in
            var sawTerminal = false
            do {
                for try await event in agent.send(request) {
                    guard let self else { return }
                    let effects = self.apply(event, conversationID: conversationID, messageID: assistant.id)
                    if effects.finished { sawTerminal = true }
                }
            } catch {
                self?.apply(.failed(error.asAgentError), conversationID: conversationID, messageID: assistant.id)
                sawTerminal = true
            }
            guard let self else { return }
            if !sawTerminal {
                self.apply(.failed(Task.isCancelled ? .cancelled : .agentUnavailable), conversationID: conversationID, messageID: assistant.id)
            }
            self.finishRequest(conversationID: conversationID, messageID: assistant.id)
        }
    }

    /// Stop generation. Asks the provider to cancel, then hard-stops locally
    /// if the backend doesn't confirm quickly.
    func stop() {
        guard let requestID = activeRequestID, let messageID = activeMessageID, let conversationID = currentID else { return }
        let agent = provider()
        Task { [weak self] in
            await agent.cancel(requestID: requestID)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.activeRequestID == requestID else { return }
            self.streamTask?.cancel()
            self.apply(.failed(.cancelled), conversationID: conversationID, messageID: messageID)
            self.finishRequest(conversationID: conversationID, messageID: messageID)
        }
    }

    func retry(_ assistantMessageID: UUID) {
        guard !isStreaming, let conversation = current,
              let prompt = ChatReducer.retryPrompt(for: assistantMessageID, in: conversation),
              let index = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) else { return }
        mutateConversation(conversation.id) { c in
            c.messages.remove(at: index)
            if let userIndex = c.messages[..<index].lastIndex(where: { $0.role == .user }) {
                c.messages.remove(at: userIndex)
            }
        }
        send(prompt)
    }

    private func stopIfNeeded() {
        if isStreaming { stop() }
    }

    // MARK: Mutation helpers

    @discardableResult
    private func apply(_ event: AgentEvent, conversationID: UUID, messageID: UUID) -> ChatReducer.Effects {
        var effects = ChatReducer.Effects()
        mutateMessage(conversationID, messageID) { message in
            // Ignore late events after the message reached a terminal state.
            if message.state.isTerminal && message.state != .sending { return }
            effects = ChatReducer.apply(event, to: &message)
        }
        if let title = effects.title {
            mutateConversation(conversationID) { $0.title = title }
        }
        if case .runStarted(_, let sessionID) = event, let sessionID {
            mutateConversation(conversationID) { if $0.backendSessionID == nil { $0.backendSessionID = sessionID } }
        }
        if effects.approvalRequested {
            approvalSignal += 1
            persist(conversationID)
        }
        return effects
    }

    private func finishRequest(conversationID: UUID, messageID: UUID) {
        guard activeMessageID == messageID else { return }
        activeRequestID = nil
        activeMessageID = nil
        streamTask = nil
        mutateConversation(conversationID) { $0.updatedAt = Date() }
        persist(conversationID)
        if let message = conversations.first(where: { $0.id == conversationID })?.messages.first(where: { $0.id == messageID }) {
            onReplyFinished?(message)
        }
    }

    private func mutateConversation(_ id: UUID, _ body: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        body(&conversations[index])
    }

    private func mutateMessage(_ conversationID: UUID, _ messageID: UUID, _ body: (inout Message) -> Void) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == messageID }) else { return }
        body(&conversations[c].messages[m])
    }

    private func moveToTop(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)
    }

    private func persist(_ id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }), !conversation.messages.isEmpty else { return }
        // Persist a stable copy: in-flight messages are saved as interrupted
        // so a crash mid-stream never leaves a forever-"streaming" bubble.
        var copy = conversation
        for i in copy.messages.indices where !copy.messages[i].state.isTerminal && copy.messages[i].id != activeMessageID {
            copy.messages[i].state = .failed(.webSocketDisconnected)
        }
        try? store.save(copy)
    }
}
