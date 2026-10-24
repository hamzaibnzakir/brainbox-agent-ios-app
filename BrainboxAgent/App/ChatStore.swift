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
    /// The conversation the in-flight reply belongs to (may differ from `currentID`).
    private(set) var activeConversationID: UUID?
    /// Follow-up instructions waiting for the current reply to end, per conversation.
    private(set) var queuedInstructions: [UUID: [QueuedInstruction]] = [:]
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
        guard let conversationID = activeConversationID, let messageID = activeMessageID else { return nil }
        return message(conversationID, messageID)?.runID
    }

    func steer(_ text: String) async throws {
        guard let runController, let runID = activeRunID else { return }
        try await runController.steer(runID: runID, text: text)
    }

    func respond(to approval: AgentApproval, choice: HermesApprovalChoice) async throws {
        guard let runController else { throw AgentError.providerUnavailable(detail: "Approvals need the Hermes backend.") }
        try await runController.respond(to: approval, choice: choice)
    }

    /// Re-open live run streams right away (foreground, network back, or "Reconnect").
    func reconnectLiveRuns() {
        runController?.reconnectActiveRuns()
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

    /// Switching chats never stops a reply: it keeps running (and streaming
    /// into its own conversation) while you look at another one.
    func select(_ id: UUID) {
        guard id != currentID else { return }
        currentID = id
    }

    /// Removes the conversation from this device only. Callers decide (and
    /// say) whether the server copy is gone; see `deletePermanently`.
    private func removeFromDevice(_ id: UUID) {
        if id == activeConversationID { stopIfNeeded() }
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
        if archived, id == activeConversationID { stopIfNeeded() }
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
        send(rawText, sentContent: nil)
    }

    /// Sends a user turn. `text` is what the chat shows; `sentContent` (skill
    /// messages, file paths) is what the agent receives; images go inline.
    func send(_ rawText: String, sentContent: String?, attachments: [MessageAttachment] = [], imageDataURLs: [String] = []) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming else { return }

        if current == nil { newConversation() }
        guard let conversationID = currentID else { return }

        var user = Message(role: .user, content: text.isEmpty ? "(attachment)" : text)
        user.sentContent = sentContent
        user.attachments = attachments.isEmpty ? nil : attachments
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

        var request = AgentRequest(conversationID: conversationID, responseMessageID: assistant.id, content: sentContent ?? text,
                                   options: requestOptions(conversations.first { $0.id == conversationID }))
        request.imageDataURLs = imageDataURLs.isEmpty ? nil : imageDataURLs
        let userMessageID = user.id
        activeRequestID = request.requestID
        activeMessageID = assistant.id
        activeConversationID = conversationID
        persist(conversationID)

        let agent = provider()
        streamTask = Task { [weak self] in
            var sawTerminal = false
            do {
                for try await event in agent.send(request) {
                    guard let self else { return }
                    if case .runStarted = event {
                        // Hermes accepted the run: its attachments reached the server with it.
                        self.mutateMessage(conversationID, userMessageID) { message in
                            guard var items = message.attachments else { return }
                            for i in items.indices where items[i].status == .uploaded || items[i].status == .preparing { items[i].status = .sent }
                            message.attachments = items
                        }
                    }
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

    // MARK: Slash commands

    /// Where a command wants the app to go.
    enum CommandDestination: Equatable { case workspace, sessions, files, terminal }

    /// What a composer submission did, for the UI.
    enum SubmitOutcome: Equatable {
        case sent
        case handled(String?)
        case navigate(CommandDestination)
        case parallel([String])
        /// `/bg`: run this prompt as a separate background session, result posted back here.
        case background(prompt: String, origin: UUID)
        case refused(String)
    }

    /// Hermes' command registry + skills (from the proxy), when connected.
    @ObservationIgnored var commandCatalog: () -> HermesCommandCatalog? = { nil }
    /// Short real-state summary for /status (connection, server).
    @ObservationIgnored var statusSummary: () -> String = { "" }

    /// The composer's single entry point: routes slash commands (never sending
    /// them to the model as text) and sends everything else.
    func submit(_ rawText: String, attachments: [MessageAttachment] = [], imageDataURLs: [String] = [],
                attachmentNote: String? = nil) async -> SubmitOutcome {
        let parsed = SlashCommandRouter.parse(rawText, catalog: commandCatalog())
        if !attachments.isEmpty {
            if case .text = parsed {} else {
                return .refused("Attachments can only be sent with a normal message, not with a command.")
            }
        }
        switch parsed {
        case .text(let text):
            guard !isStreaming else {
                return .refused("A reply is still running. Use Steer, “Send after this”, or Stop first.")
            }
            let sent = attachmentNote.map { text.isEmpty ? $0 : text + $0 }
            send(text, sentContent: sent, attachments: attachments, imageDataURLs: imageDataURLs)
            return .sent
        case .skill(let name, let instruction):
            guard !isStreaming else { return .refused("Wait for the current reply (or stop it) before running /\(name).") }
            guard let client = lifecycleClient() else {
                return .refused("Skill commands need a live connection to Hermes through the Brainbox proxy.")
            }
            do {
                let message = try await client.skillInvocation(name: name, instruction: instruction)
                send("/\(name)" + (instruction.isEmpty ? "" : " \(instruction)"), sentContent: message)
                return .sent
            } catch {
                return .refused("/\(name) wasn't run: \(error.asAgentError.message)")
            }
        case .app(let command, let argument):
            return await perform(command, argument: argument)
        case .hermes(let name, let argument):
            guard let client = lifecycleClient() else {
                return .refused("/\(name) runs with Hermes' own handler on the Brainbox proxy, which isn't connected.")
            }
            do {
                let reply = try await client.runHermesCommand(name: name, arguments: argument)
                addCommandOutput("/\(name)", reply.text.isEmpty ? "(Hermes returned no text.)" : reply.text)
                return .handled(nil)
            } catch {
                return .refused("/\(name) failed: \(error.asAgentError.message)")
            }
        case .unavailable, .missingArgument, .unknown:
            return .refused(SlashCommandRouter.explanation(for: parsed, catalogIsLive: commandCatalog()?.isLive ?? false)
                            ?? "That command can't run here.")
        }
    }

    private func perform(_ command: AppCommand, argument: String) async -> SubmitOutcome {
        switch command {
        case .new:
            newConversation()
            return .handled(nil)
        case .stop:
            guard isStreaming else { return .refused("Nothing is running.") }
            stop()
            return .handled("Stop sent — waiting for Hermes to confirm.")
        case .steer:
            guard isStreaming else { return .refused("Nothing is running to steer. Send it as a normal message instead.") }
            do {
                try await steer(argument, mode: .inject)
                return .handled("Steering sent to the running agent.")
            } catch {
                return .refused(error.asAgentError.message)
            }
        case .queue:
            guard isStreaming else {
                send(argument)
                return .sent
            }
            try? await steer(argument, mode: .queue)
            return .handled("Queued — it's sent when the current reply ends.")
        case .retry:
            guard !isStreaming, let last = current?.messages.last(where: { $0.role == .assistant }) else {
                return .refused(isStreaming ? "Wait for the current reply first." : "There's nothing to retry yet.")
            }
            retry(last.id)
            return .sent
        case .title:
            guard let id = currentID else { return .refused("Open a chat first.") }
            rename(id, to: argument)
            if let conversation = current, let serverID = AppSessionID.serverID(for: conversation),
               conversation.backendSessionID != nil, let client = lifecycleClient()?.with(profile: nil) {
                do {
                    _ = try await client.updateSession(id: serverID, title: argument)
                    return .handled("Renamed here and on Hermes.")
                } catch {
                    return .handled("Renamed here. Hermes' title wasn't updated: \(error.asAgentError.message)")
                }
            }
            return .handled("Renamed.")
        case .model:
            return await chooseModel(argument)
        case .approve, .deny:
            guard let conversation = current,
                  let approval = conversation.messages.last(where: { $0.pendingApproval != nil })?.pendingApproval else {
                return .refused("Nothing is waiting for an approval in this chat.")
            }
            do {
                try await respond(to: approval, choice: command == .approve ? .once : .deny)
                return .handled(command == .approve ? "Approved once." : "Denied.")
            } catch {
                return .refused(error.asAgentError.message)
            }
        case .status:
            let session = await currentServerSession()
            var runID: String?
            var liveness: RunLiveness?
            if let conversationID = activeConversationID, conversationID == currentID, let messageID = activeMessageID,
               let reply = message(conversationID, messageID) {
                runID = reply.runID ?? "starting"
                liveness = reply.liveness
            }
            let queued = currentID.flatMap { queuedInstructions[$0]?.count } ?? 0
            addCommandOutput("/status", SessionReport.status(session: session.record, sessionID: session.id, modelOverride: current?.modelOverride,
                                                             runID: runID, liveness: liveness, queued: queued, connection: statusSummary()))
            return .handled(nil)
        case .usage:
            let session = await currentServerSession()
            guard let record = session.record else {
                return .refused(session.id == nil ? "Usage is tracked by Hermes per conversation; this chat isn't on Hermes."
                                                  : "Hermes has no usage for this chat yet.")
            }
            addCommandOutput("/usage", SessionReport.usage(session: record))
            return .handled(nil)
        case .bg:
            if currentID == nil { newConversation() }
            guard let origin = currentID else { return .refused("Open a chat first.") }
            return .background(prompt: argument, origin: origin)
        case .btw:
            guard let conversation = current, let serverID = AppSessionID.serverID(for: conversation) else {
                return .refused("/btw asks about one of your Hermes chats — open one first.")
            }
            guard let client = lifecycleClient() else {
                return .refused("/btw runs Hermes' side-question handler on the Brainbox proxy, which isn't connected.")
            }
            let question = argument
            let conversationID = conversation.id
            // Like Telegram: answered on a transcript snapshot, the running reply isn't touched.
            Task { [weak self] in
                do {
                    let reply = try await client.runHermesCommand(name: "btw", arguments: question, sessionID: serverID)
                    self?.addCommandOutput("/btw " + question, reply.text, to: conversationID)
                } catch {
                    self?.addCommandOutput("/btw " + question, "Hermes couldn't answer: \(error.asAgentError.message)", to: conversationID)
                }
            }
            return .handled("Asking on the side — the answer appears here.")
        case .skills:
            guard let catalog = commandCatalog() else { return .refused("Hermes' skill list isn't available (needs the Brainbox proxy).") }
            let list = catalog.skills.isEmpty ? "Hermes has no skill commands installed."
                : catalog.skills.map { "/\($0.name) — \($0.description)" }.joined(separator: "\n")
            addCommandOutput("/skills", list)
            return .handled(nil)
        case .help:
            var sections: [String] = []
            if let client = lifecycleClient(), let reply = try? await client.runHermesCommand(name: "help", arguments: argument) {
                sections.append(reply.text)
                sections.append("---")
            }
            sections.append("**In this app**\n" + AppCommand.allCases.map {
                "`/\($0.rawValue)\($0.argsHint.isEmpty ? "" : " " + $0.argsHint)` — \($0.summary)"
            }.joined(separator: "\n"))
            if let skills = commandCatalog()?.skills, !skills.isEmpty { sections.append("Plus \(skills.count) Hermes skill command(s) — type /skills.") }
            sections.append("Commands that need Telegram's live session (e.g. /compress, /personality) are explained instead of being sent to the model. Type / to search everything.")
            addCommandOutput("/help", sections.joined(separator: "\n\n"))
            return .handled(nil)
        case .archive:
            guard let id = currentID else { return .refused("Open a chat first.") }
            do {
                try await archive(id)
                return .handled("Archived.")
            } catch {
                return .refused(error.asAgentError.message)
            }
        case .agents: return .navigate(.workspace)
        case .sessions: return .navigate(.sessions)
        case .files: return .navigate(.files)
        case .terminal: return .navigate(.terminal)
        case .parallel:
            let tasks = SlashCommandRouter.parallelTasks(argument)
            guard tasks.count >= 2 else { return .refused("Give at least two tasks separated by | — e.g. /parallel check disk | review logs") }
            return .parallel(tasks)
        }
    }

    private func chooseModel(_ argument: String) async -> SubmitOutcome {
        if currentID == nil { newConversation() }
        guard let id = currentID else { return .refused("Open a chat first.") }
        let name = argument.trimmingCharacters(in: .whitespaces)
        var available: [String]?
        if let client = lifecycleClient() { available = (try? await client.models())?.map(\.id) }
        if name.isEmpty {
            let current = conversations.first { $0.id == id }?.modelOverride
            let list = available.map { $0.isEmpty ? "Hermes listed no models." : $0.map { "• \($0)" }.joined(separator: "\n") }
                ?? "The model list isn't available right now."
            addCommandOutput("/model", "This chat uses: \(current ?? "the preset's model")\n\n\(list)\n\nUse /model <name> to switch, /model default to go back.")
            return .handled(nil)
        }
        if name == "default" {
            mutateConversation(id) { $0.modelOverride = nil }
            persist(id)
            return .handled("This chat uses the preset's model again.")
        }
        if let available, !available.isEmpty, !available.contains(name) {
            return .refused("Hermes doesn't list a model called “\(name)”. Type /model to see the list.")
        }
        mutateConversation(id) { $0.modelOverride = name }
        persist(id)
        return .handled("This chat now asks Hermes for \(name). Hermes reports an error on the next message if it can't route it.")
    }

    /// Local command output (never sent to the agent or stored on the server).
    private func addCommandOutput(_ command: String, _ text: String, to conversationID: UUID? = nil) {
        if conversationID == nil, current == nil { newConversation() }
        guard let id = conversationID ?? currentID, conversations.contains(where: { $0.id == id }) else { return }
        mutateConversation(id) { $0.messages.append(Message(role: .system, content: "**\(command)**\n\n" + text, state: .complete)) }
        persist(id)
    }

    /// Hermes' record of the current chat (`GET /api/sessions/{id}`), when it has one.
    private func currentServerSession() async -> (id: String?, record: HermesSession?) {
        guard let conversation = current, let serverID = AppSessionID.serverID(for: conversation) else { return (nil, nil) }
        guard let client = lifecycleClient() else { return (serverID, nil) }
        return (serverID, try? await client.session(id: serverID))
    }

    /// `/bg` finished: post its result into the chat it was started from (once).
    func deliverBackgroundResult(_ task: ParallelTask) {
        guard task.isFinished, let origin = task.originConversationID, let agent = task.agents.first else { return }
        let key = "bb.bg.delivered"
        var delivered = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !delivered.contains(task.id.uuidString) else { return }
        delivered.append(task.id.uuidString)
        UserDefaults.standard.set(Array(delivered.suffix(200)), forKey: key)
        let body: String
        switch agent.state {
        case .completed: body = agent.output.isEmpty ? "(The background run finished without text output.)" : agent.output
        case .cancelled: body = "Stopped before finishing." + (agent.output.isEmpty ? "" : "\n\n" + agent.output)
        default: body = "Didn't finish: \(agent.error ?? agent.state.rawValue)."
        }
        addCommandOutput("/bg " + String(agent.prompt.prefix(60)) + (agent.prompt.count > 60 ? "…" : ""), body, to: origin)
    }

    static func describe(_ phase: StopPhase) -> String {
        switch phase {
        case .requested: return "requested"
        case .acknowledged: return "Hermes is stopping it"
        case .finishedFirst: return "finished before the stop"
        case .unconfirmed: return "not confirmed"
        }
    }

    // MARK: Stop

    /// How long to wait for the server to confirm a stop before saying so.
    @ObservationIgnored var stopConfirmationTimeout: TimeInterval = 45

    /// Stop the in-flight reply. For server-side runs (Hermes) this asks the
    /// server to interrupt the run and keeps following it: the reply only
    /// shows as stopped once the server reports it cancelled. Pressing Stop
    /// again while a stop is pending does nothing; after an unconfirmed stop
    /// it retries. Local providers (Mock) are cancelled locally.
    func stop() {
        guard let requestID = activeRequestID, let messageID = activeMessageID, let conversationID = activeConversationID else { return }
        let phase = message(conversationID, messageID)?.stop
        if phase?.isPending == true { return }   // idempotent
        apply(.stopRequested, conversationID: conversationID, messageID: messageID)
        guard let runController else {
            let agent = provider()
            Task { [weak self] in
                await agent.cancel(requestID: requestID)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.activeRequestID == requestID else { return }
                // Local providers have no server work: cancelling the stream is the stop.
                self.streamTask?.cancel()
                self.apply(.failed(.cancelled), conversationID: conversationID, messageID: messageID)
                self.finishRequest(conversationID: conversationID, messageID: messageID)
            }
            return
        }
        Task { [weak self] in
            let result = await runController.requestStop(requestID: requestID)
            guard let self, self.activeRequestID == requestID else { return }
            switch result {
            case .sent(let status):
                if status == .stopping || status == .running || status == .queued {
                    self.apply(.stopAcknowledged, conversationID: conversationID, messageID: messageID)
                }
                // Terminal statuses arrive on the run stream / poll and settle the reply.
            case .deferredUntilRunStarts:
                break   // the provider sends the stop as soon as Hermes returns the run id
            case .notRunning:
                // No server run behind this request (e.g. still creating the session).
                self.streamTask?.cancel()
                self.apply(.failed(.cancelled), conversationID: conversationID, messageID: messageID)
                self.finishRequest(conversationID: conversationID, messageID: messageID)
                return
            case .failed(let error):
                self.apply(.stopUnconfirmed("The stop request failed: \(error.message) The run may still be going — try Stop again or check Tasks."),
                           conversationID: conversationID, messageID: messageID)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(self.stopConfirmationTimeout * 1_000_000_000))
            guard self.activeRequestID == requestID, self.message(conversationID, messageID)?.stop?.isPending == true else { return }
            self.apply(.stopUnconfirmed("Hermes hasn't confirmed the stop yet. The run may still be working — Brainbox keeps following it."),
                       conversationID: conversationID, messageID: messageID)
        }
    }

    /// Stops following an unconfirmed reply locally. Says plainly that the
    /// server never confirmed, so nobody mistakes it for a stop.
    func stopFollowing() {
        guard let messageID = activeMessageID, let conversationID = activeConversationID else { return }
        streamTask?.cancel()
        apply(.failed(.remote(code: "detached", message: "Stopped following this reply. Hermes never confirmed the stop, so the run may still have finished on the server — check Tasks.")),
              conversationID: conversationID, messageID: messageID)
        finishRequest(conversationID: conversationID, messageID: messageID)
    }

    // MARK: Steering

    enum SteerMode: String, CaseIterable, Identifiable {
        /// Hermes `/steer`: the running agent reads it at its next step.
        case inject
        /// Sent as the next message once this reply has ended.
        case queue
        /// Stop the current work (server-confirmed), then send this.
        case interrupt
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inject: return "Steer now"
            case .queue: return "Send after this"
            case .interrupt: return "Stop and send"
            }
        }
        var detail: String {
            switch self {
            case .inject: return "The agent reads it at its next step, without stopping."
            case .queue: return "Waits until the current reply ends, then sends it as a new message."
            case .interrupt: return "Stops the current work, waits for Hermes to confirm, then sends it."
            }
        }
    }

    struct QueuedInstruction: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let afterInterrupt: Bool
    }

    var canInject: Bool { canSteer }

    /// Sends guidance to the reply that's running in the active conversation.
    func steer(_ rawText: String, mode: SteerMode) async throws {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let conversationID = activeConversationID, isStreaming else {
            send(text)
            return
        }
        switch mode {
        case .inject:
            guard let runController, let runID = activeRunID else {
                throw AgentError.notImplemented(detail: "This backend can't steer a running reply. Use “Send after this” instead.")
            }
            do {
                try await runController.steer(runID: runID, text: text)
            } catch AgentError.remote(let code, _) where code == "run_not_accepting_steer" || code == "steer_not_accepted" {
                throw AgentError.remote(code: code, message: "The agent isn't taking steering right now (it may be waiting on a tool or an approval). Use “Send after this” instead.")
            }
        case .queue:
            queuedInstructions[conversationID, default: []].append(QueuedInstruction(text: text, afterInterrupt: false))
        case .interrupt:
            queuedInstructions[conversationID, default: []].insert(QueuedInstruction(text: text, afterInterrupt: true), at: 0)
            stop()
        }
    }

    func removeQueued(_ id: UUID, from conversationID: UUID) {
        queuedInstructions[conversationID]?.removeAll { $0.id == id }
        if queuedInstructions[conversationID]?.isEmpty == true { queuedInstructions[conversationID] = nil }
    }

    /// After a reply ends: send the next queued instruction. A failed reply
    /// keeps the queue (the user decides); a cancelled one only continues if
    /// the cancellation was the requested interrupt.
    private func dispatchQueued(after conversationID: UUID, finalState: MessageState?) {
        guard var queue = queuedInstructions[conversationID], let next = queue.first else { return }
        switch finalState {
        case .complete?: break
        case .cancelled?: guard next.afterInterrupt else { return }
        default: return
        }
        queue.removeFirst()
        queuedInstructions[conversationID] = queue.isEmpty ? nil : queue
        Task { @MainActor [weak self] in
            guard let self, !self.isStreaming else { return }
            if self.currentID != conversationID { self.currentID = conversationID }
            self.send(next.text)
        }
    }

    /// Sends a held instruction now (e.g. after a failed reply).
    func sendQueuedNow(_ id: UUID, in conversationID: UUID) {
        guard !isStreaming, let item = queuedInstructions[conversationID]?.first(where: { $0.id == id }) else { return }
        removeQueued(id, from: conversationID)
        if currentID != conversationID { currentID = conversationID }
        send(item.text)
    }

    private func message(_ conversationID: UUID, _ messageID: UUID) -> Message? {
        conversations.first { $0.id == conversationID }?.messages.first { $0.id == messageID }
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
        activeConversationID = nil
        streamTask = nil
        mutateConversation(conversationID) { $0.updatedAt = Date() }
        persist(conversationID)
        let finished = message(conversationID, messageID)
        if let finished { onReplyFinished?(finished) }
        dispatchQueued(after: conversationID, finalState: finished?.state)
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
