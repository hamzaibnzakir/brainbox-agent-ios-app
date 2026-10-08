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
        currentID = conversations.first?.id
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
        // Reuse an existing empty conversation instead of piling them up.
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            currentID = empty.id
            return
        }
        let conversation = Conversation(providerKind: provider().descriptor.kind)
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        stopIfNeeded()
        currentID = id
    }

    func delete(_ id: UUID) {
        if id == currentID { stopIfNeeded() }
        conversations.removeAll { $0.id == id }
        try? store.delete(id)
        if currentID == id { currentID = conversations.first?.id }
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

        let request = AgentRequest(conversationID: conversationID, responseMessageID: assistant.id, content: text)
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
