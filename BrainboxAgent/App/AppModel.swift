import BrainboxCore
import Foundation
import HermesKit
import Observation
import SwiftUI

/// A saved Hermes session (from `session.list`).
struct SessionSummary: Identifiable, Hashable {
    var id: String
    var title: String
    var preview: String
    var startedAt: Date
    var messageCount: Int
    var source: String

    /// Sessions from messaging platforms (Telegram, …) and cron are shown read-only:
    /// Brainbox never writes into or deletes another surface's history.
    var isReadOnly: Bool { !["tui", "desktop", "cli", ""].contains(source) }

    init?(_ json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        title = json["title"]?.stringValue ?? ""
        preview = json["preview"]?.stringValue ?? ""
        startedAt = json["started_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date()
        messageCount = json["message_count"]?.intValue ?? 0
        source = json["source"]?.stringValue ?? ""
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let p = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "Untitled chat" : p
    }
}

@MainActor
@Observable
final class AppModel {
    let store = AppStore.shared
    let engine: HermesEngine

    var connection: LinkState = .idle
    var profile: ServerProfile?
    var identity: SSHIdentity
    private var storedPreferences = Preferences.current
    var preferences: Preferences {
        get { storedPreferences }
        set {
            storedPreferences = newValue
            Preferences.current = newValue
        }
    }

    var transcripts: [String: Transcript] = [:]
    var currentChat: String?
    var sessions: [SessionSummary] = []
    var sessionsError: String?
    var composerPrefill: [String: String] = [:]
    var lastEvent: GatewayEvent?
    var toast: String?
    var selectedTab: Tab = .chat
    /// Pet sprite sheet from Hermes (`pet.info`), when the user has one.
    var pet: PetSprite?
    /// Files shared into the app ("Open in Brainbox"), waiting in the composer.
    var sharedAttachments: [Attachment] = []
    /// Set by the Siri/widget voice shortcut.
    var voiceRequested = false

    enum Tab: Hashable { case chat, sessions, agents, hub }

    private var pumping = false
    let notifier = Notifier.shared

    init() {
        engine = HermesEngine(persistence: AppStore.shared)
        identity = AppStore.shared.identity()
        profile = AppStore.shared.profile
    }

    var isConnected: Bool { connection.isConnected }

    var serverInfo: HermesServerInfo? {
        if case .connected(let info) = connection { return info }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        guard !pumping else { return }
        pumping = true
        if Self.isDemo { loadDemo(); return }
        let updates = engine.updates
        Task { [weak self] in
            for await update in updates {
                self?.handle(update)
            }
        }
        if profile != nil { Task { await connect() } }
    }

    private func handle(_ update: EngineUpdate) {
        switch update {
        case .state(let state):
            let wasConnected = connection.isConnected
            connection = state
            if state.isConnected, !wasConnected {
                Task { await refreshSessions(); await loadPet() }
                if currentChat == nil { Task { await restoreLastChat() } }
            }
        case .transcript(let chat, let transcript):
            transcripts[chat] = transcript
            if transcript.busy { store.watchedChats[chat] = transcript.title ?? "Hermes" }
        case .turnFinished(let chat, let title, let text):
            store.watchedChats[chat] = nil
            if preferences.haptics { Haptic.success() }
            if preferences.notifyOnFinish { notifier.turnFinished(chat: chat, title: title, text: text) }
            if preferences.speakReplies, chat == currentChat { Task { await Voice.shared.speak(text, using: self) } }
            LiveActivityBridge.shared.end(chat: chat, text: text)
            Task { await refreshSessions() }
        case .needsAttention(let chat, let title, let request):
            if preferences.haptics { Haptic.warning() }
            if preferences.notifyOnApproval { notifier.needsAttention(chat: chat, title: title, request: request) }
        case .event(let event):
            lastEvent = event
            if event.type == "sessions.changed" { Task { await refreshSessions() } }
            if event.type == "pet.changed" { Task { await loadPet() } }
        case .prefill(let chat, let text):
            composerPrefill[chat] = text
        }
        if let chat = currentChat, let t = transcripts[chat], t.busy {
            LiveActivityBridge.shared.update(chat: chat, title: t.title ?? "Hermes", status: t.status ?? "Working")
        }
    }

    // MARK: Connection

    func save(profile: ServerProfile) {
        self.profile = profile
        store.profile = profile
    }

    func connect() async {
        guard let profile else { return }
        if preferences.lockWithFaceID, !(await Biometrics.authenticate(reason: "Unlock your SSH key to connect to \(profile.name)")) {
            connection = .failed("Face ID is required to use the SSH key.")
            return
        }
        let options = HermesClient.Options(target: profile.target, identity: identity, hostKeys: store,
                                           ownershipID: store.ownershipID, desktopMode: preferences.desktopBackend)
        await engine.connect(options)
    }

    func disconnect() async {
        await engine.disconnect()
    }

    /// Back from the background: the SSH socket was probably suspended.
    func resumeFromBackground() async {
        guard profile != nil, preferences.autoReconnect else { return }
        let client = await engine.client
        let healthy = client != nil && client?.ssh.isActive == true && client?.rpc.closed == false
        if !healthy {
            switch connection {
            case .connected, .reconnecting:
                await engine.reconnectNow(reason: "Back online")
            case .failed:
                return
            case .idle, .connecting:
                await connect()
            }
        }
        await refreshSessions()
    }

    func forgetHostKey() {
        guard let profile else { return }
        store.forgetHostKey(for: profile.target.hostID)
        toast = "Trusted server key cleared. The next connection will trust the key it sees."
    }

    func regenerateKey() {
        identity = store.regenerateIdentity()
    }

    func client() async throws -> HermesClient {
        guard let client = await engine.client else { throw RPCError.disconnected }
        return client
    }

    // MARK: Sessions

    func refreshSessions() async {
        do {
            let result = try await engine.call(nil, "session.list", ["limit": 200])
            sessions = (result["sessions"]?.arrayValue ?? []).compactMap(SessionSummary.init)
            sessionsError = nil
        } catch {
            sessionsError = error.localizedDescription
        }
    }

    func newChat() async {
        do {
            let chat = try await engine.newChat()
            currentChat = chat
            store.lastChat = chat
            selectedTab = .chat
        } catch {
            toast = error.localizedDescription
        }
    }

    func open(session: SessionSummary) async {
        await open(chatID: session.id)
    }

    func open(chatID: String) async {
        do {
            try await engine.open(chatID)
            currentChat = chatID
            store.lastChat = chatID
            selectedTab = .chat
        } catch {
            toast = error.localizedDescription
        }
    }

    private func restoreLastChat() async {
        if let last = store.lastChat, (try? await engine.open(last)) != nil {
            currentChat = last
        }
    }

    func delete(session: SessionSummary) async {
        guard !session.isReadOnly else { toast = "Brainbox doesn't delete \(session.source.capitalized) history."; return }
        do {
            _ = try await engine.call(nil, "session.delete", ["session_id": .string(session.id)])
            if currentChat == session.id {
                await engine.closeChat(session.id)
                currentChat = nil
            }
            await refreshSessions()
        } catch {
            toast = error.localizedDescription
        }
    }

    func rename(chat: String, to title: String) async {
        _ = try? await engine.call(chat, "session.title", ["title": .string(title)])
        await refreshSessions()
    }

    // MARK: Chat actions

    func send(_ text: String, attachments: [Attachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if currentChat == nil { await newChat() }
        guard let chat = currentChat else { return }
        if preferences.haptics { Haptic.tap() }
        do {
            if trimmed.hasPrefix("/"), attachments.isEmpty {
                try await runCommand(trimmed, in: chat)
            } else {
                try await engine.send(chat, text: trimmed, attachments: attachments)
                LiveActivityBridge.shared.start(chat: chat, title: transcripts[chat]?.title ?? "Hermes", prompt: trimmed)
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    /// App-level commands first (like Desktop's local handlers), then Hermes.
    private func runCommand(_ line: String, in chat: String) async throws {
        let name = String(line.dropFirst().split(separator: " ").first ?? "").lowercased()
        let arg = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        switch name {
        case "new", "clear":
            await newChat()
        case "bg", "background":
            guard !arg.isEmpty else { toast = "Usage: /bg <task>"; return }
            try await engine.background(chat, arg)
        case "btw":
            guard !arg.isEmpty else { toast = "Usage: /btw <question>"; return }
            try await engine.btw(chat, arg)
        case "stop":
            try await engine.interrupt(chat)
        case "sessions":
            selectedTab = .sessions
        default:
            _ = try await engine.slash(chat, line)
        }
    }

    func stop() async {
        guard let chat = currentChat else { return }
        try? await engine.interrupt(chat)
    }

    func respond(_ request: PendingRequest, answer: String, questionID: String? = nil, chat: String? = nil) async {
        guard let chat = chat ?? currentChat else { return }
        do {
            try await engine.respond(chat, request: request, answer: answer, questionID: questionID)
        } catch {
            toast = error.localizedDescription
        }
    }

    func setModel(_ value: String) async {
        guard let chat = currentChat else { return }
        do {
            _ = try await engine.call(chat, "config.set", ["key": "model", "value": .string(value)])
            toast = "Model set to \(value.split(separator: " ").first ?? "")"
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: Pet

    func loadPet() async {
        guard let meta = try? await engine.call(nil, "pet.info.meta"), meta["enabled"]?.boolValue == true else {
            pet = nil
            return
        }
        if let pet, pet.revision == meta["spritesheetRevision"]?.stringValue, pet.slug == meta["slug"]?.stringValue { return }
        guard let info = try? await engine.call(nil, "pet.info", timeout: 60) else { return }
        pet = PetSprite(info)
    }
}
