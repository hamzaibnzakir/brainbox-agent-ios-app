import BrainboxCore
import Foundation

/// What the app persists for the engine (Keychain/UserDefaults in the app, memory in tests).
public protocol EnginePersistence: AnyObject, Sendable {
    func loadBackend(for hostID: String) -> RemoteBackendRecord?
    func saveBackend(_ record: RemoteBackendRecord?, for hostID: String)
}

public final class MemoryEnginePersistence: EnginePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: RemoteBackendRecord] = [:]
    public init() {}
    public func loadBackend(for hostID: String) -> RemoteBackendRecord? { lock.withLock { records[hostID] } }
    public func saveBackend(_ record: RemoteBackendRecord?, for hostID: String) { lock.withLock { records[hostID] = record } }
}

public struct ServerInfo: Equatable, Sendable {
    public var target: SSHTarget
    public var hostFingerprint: String
    public var version: String?
    public var hermesPath: String
    public var reusedBackend: Bool
    public var skinAccent: String?
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting(String)
    case connected(ServerInfo)
    case reconnecting(attempt: Int, reason: String)
    case failed(String)

    public var isConnected: Bool { if case .connected = self { return true }; return false }
}

public enum EngineUpdate: Sendable {
    case state(ConnectionState)
    case transcript(chat: String, Transcript)
    /// A turn finished (for notifications while the app is away).
    case turnFinished(chat: String, title: String, text: String)
    /// Hermes is waiting on the user.
    case needsAttention(chat: String, title: String, request: PendingRequest)
    /// Every gateway event, for screens that watch one (sub-agents, voice, pets).
    case event(GatewayEvent)
    /// Composer text Hermes asks the client to prefill (`/undo`, `/prompt`).
    case prefill(chat: String, text: String)
}

/// A file or photo to send with the next message.
public struct Attachment: Sendable, Hashable {
    public var filename: String
    public var data: Data
    public var isImage: Bool

    public init(filename: String, data: Data, isImage: Bool) {
        self.filename = filename
        self.data = data
        self.isImage = isImage
    }
}

/// The phone's Hermes engine: one SSH connection, the gateway, and the chats open on it.
///
/// Chats are keyed by Hermes' stored session id, which survives reconnects; the live
/// gateway id can change and is mapped internally. After any drop the engine
/// reconnects, re-attaches each open chat with `session.resume` and fills the gap
/// from `session.events.since`, skipping events it already applied (by `seq`).
public actor HermesEngine {
    public nonisolated let updates: AsyncStream<EngineUpdate>
    private let continuation: AsyncStream<EngineUpdate>.Continuation
    private let persistence: EnginePersistence

    public private(set) var state: ConnectionState = .idle
    public private(set) var client: HermesClient?
    private var options: HermesClient.Options?
    private var wantConnected = false
    private var pump: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private struct Chat {
        var liveID: String
        var transcript = Transcript()
    }
    private var chats: [String: Chat] = [:]
    private var liveToChat: [String: String] = [:]

    public init(persistence: EnginePersistence) {
        self.persistence = persistence
        (updates, continuation) = AsyncStream.makeStream(of: EngineUpdate.self, bufferingPolicy: .unbounded)
    }

    private func setState(_ new: ConnectionState) {
        state = new
        continuation.yield(.state(new))
    }

    // MARK: Connection

    public func connect(_ options: HermesClient.Options) async {
        self.options = options
        wantConnected = true
        reconnectTask?.cancel()
        await establish(isReconnect: false)
    }

    public func disconnect() {
        wantConnected = false
        reconnectTask?.cancel()
        pump?.cancel()
        client?.close()
        client = nil
        setState(.idle)
    }

    /// Stops the backend this phone started on the server, then disconnects.
    public func stopBackend() async {
        if let client, let options {
            await RemoteBackend(ssh: client.ssh, ownershipID: options.ownershipID).stop(client.backend.record)
            persistence.saveBackend(nil, for: options.target.hostID)
        }
        disconnect()
    }

    /// Drop and rebuild the connection now (app returned to foreground, network changed).
    public func reconnectNow(reason: String = "Reconnecting") async {
        guard wantConnected else { return }
        client?.close()
        client = nil
        await establish(isReconnect: true, reason: reason)
    }

    private func establish(isReconnect: Bool, reason: String = "") async {
        guard var options else { return }
        options.knownBackend = persistence.loadBackend(for: options.target.hostID)
        setState(isReconnect ? .reconnecting(attempt: 1, reason: reason) : .connecting("Connecting over SSH"))
        do {
            let client = try await HermesClient.connect(options) { [weak self] step in
                guard let self else { return }
                Task { await self.progress(step, isReconnect: isReconnect) }
            }
            persistence.saveBackend(client.backend.record, for: options.target.hostID)
            self.client = client
            let info = ServerInfo(target: options.target, hostFingerprint: client.ssh.hostKeyFingerprint,
                                  version: client.backend.version, hermesPath: client.backend.record.hermesPath,
                                  reusedBackend: client.backend.reused,
                                  skinAccent: client.ready?.payload["skin"]?["colors"]?["ui_accent"]?.stringValue)
            startPump(client)
            await reattachChats()
            setState(.connected(info))
        } catch {
            client = nil
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if case SSHError.hostKeyChanged = error {
                wantConnected = false
                setState(.failed(message))
                return
            }
            if case SSHError.authenticationFailed = error {
                wantConnected = false
                setState(.failed(message))
                return
            }
            if isReconnect || state.isConnected {
                scheduleReconnect(reason: message, attempt: 1)
            } else {
                setState(.failed(message))
            }
        }
    }

    private func progress(_ step: HermesClient.Step, isReconnect: Bool) {
        guard !isReconnect else { return }
        switch step {
        case .ssh: setState(.connecting("Connecting over SSH"))
        case .backend(let text): setState(.connecting(text))
        case .gateway: setState(.connecting("Opening Hermes"))
        }
    }

    private func scheduleReconnect(reason: String, attempt: Int) {
        guard wantConnected else { return }
        setState(.reconnecting(attempt: attempt, reason: reason))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let delay = min(30.0, pow(2.0, Double(min(attempt, 5))) * 0.5)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.retry(attempt: attempt)
        }
    }

    private func retry(attempt: Int) async {
        guard wantConnected else { return }
        await establish(isReconnect: true, reason: "Reconnecting")
        if !state.isConnected, case .reconnecting = state { scheduleReconnect(reason: "Still reconnecting", attempt: attempt + 1) }
    }

    private func startPump(_ client: HermesClient) {
        pump?.cancel()
        let events = client.rpc.subscribe()
        pump = Task { [weak self] in
            for await event in events {
                await self?.route(event)
            }
            await self?.lost(client)
        }
    }

    private func lost(_ dropped: HermesClient) {
        guard client === dropped else { return }
        client = nil
        dropped.close()
        scheduleReconnect(reason: "Connection lost", attempt: 1)
    }

    // MARK: Events

    private func route(_ event: GatewayEvent) {
        continuation.yield(.event(event))
        guard let live = event.sessionID, let key = liveToChat[live], var chat = chats[key] else { return }
        let wasBusy = chat.transcript.busy
        let before = chat.transcript.pendingRequests.map(\.requestID)
        guard chat.transcript.apply(event) else { return }
        chats[key] = chat
        continuation.yield(.transcript(chat: key, chat.transcript))
        let title = chat.transcript.title ?? "Hermes"
        if event.type == "message.complete", wasBusy {
            continuation.yield(.turnFinished(chat: key, title: title, text: chat.transcript.lastCompletedText ?? ""))
        }
        for request in chat.transcript.pendingRequests where !before.contains(request.requestID) {
            continuation.yield(.needsAttention(chat: key, title: title, request: request))
        }
        // Desktop-only tool UIs (preview, window reads) can't run on a phone: answer so the agent moves on.
        if let method = Self.unsupportedRequestReply[event.type], let rid = event.payload["request_id"]?.stringValue, let client {
            Task { try? await client.rpc.call(method.0, ["request_id": .string(rid), method.1: ""]) }
        }
    }

    static let unsupportedRequestReply: [String: (String, String)] = [
        "terminal.read.request": ("terminal.read.respond", "text"),
        "preview.read.request": ("preview.read.respond", "text"),
        "preview.act.request": ("preview.act.respond", "text"),
        "window.read.request": ("window.read.respond", "text"),
        "tour.request": ("tour.respond", "text"),
    ]

    private func reattachChats() async {
        guard let client else { return }
        for (key, chat) in chats {
            do {
                let resumed = try await client.rpc.call("session.resume", ["session_id": .string(key)], timeout: 60)
                let live = resumed["session_id"]?.stringValue ?? chat.liveID
                liveToChat[chat.liveID] = nil
                liveToChat[live] = key
                var updated = chat
                updated.liveID = live
                let since = try await client.rpc.call("session.events.since",
                                                      ["session_id": .string(live), "last_seen": .number(Double(chat.transcript.lastSeq))])
                for raw in since["events"]?.arrayValue ?? [] {
                    if let event = GatewayEvent(json: raw) { updated.transcript.apply(event) }
                }
                // A turn that ended while we were away and isn't in the replay window.
                if updated.transcript.busy, resumed["running"]?.boolValue == false, resumed["inflight"]?.boolValue != true {
                    updated.transcript.busy = false
                    updated.transcript.status = nil
                    updated.transcript.hydrate(messages: resumed["messages"]?.arrayValue ?? [])
                }
                chats[key] = updated
                continuation.yield(.transcript(chat: key, updated.transcript))
            } catch {
                continue
            }
        }
    }

    // MARK: Chats

    private func requireClient() throws -> HermesClient {
        guard let client else { throw RPCError.disconnected }
        return client
    }

    public func transcript(_ chat: String) -> Transcript? { chats[chat]?.transcript }

    /// Starts a new Hermes session and returns its chat key.
    public func newChat() async throws -> String {
        let client = try requireClient()
        let result = try await client.rpc.call("session.create", [:])
        guard let live = result["session_id"]?.stringValue else { throw RPCError(code: -1, message: "Hermes didn't create a session.") }
        let key = result["stored_session_id"]?.stringValue ?? live
        var chat = Chat(liveID: live)
        chat.transcript.model = result["info"]?["model"]?.stringValue
        chats[key] = chat
        liveToChat[live] = key
        continuation.yield(.transcript(chat: key, chat.transcript))
        return key
    }

    /// Opens an existing session (any source) and loads its history.
    @discardableResult
    public func open(_ stored: String) async throws -> Transcript {
        let client = try requireClient()
        if let chat = chats[stored] { return chat.transcript }
        let result = try await client.rpc.call("session.resume", ["session_id": .string(stored)], timeout: 90)
        guard let live = result["session_id"]?.stringValue else { throw RPCError(code: -1, message: "Hermes couldn't open that session.") }
        var chat = Chat(liveID: live)
        chat.transcript.hydrate(messages: result["messages"]?.arrayValue ?? [])
        chat.transcript.model = result["info"]?["model"]?.stringValue
        chat.transcript.busy = result["running"]?.boolValue == true || result["inflight"]?.boolValue == true
        chats[stored] = chat
        liveToChat[live] = stored
        continuation.yield(.transcript(chat: stored, chat.transcript))
        return chat.transcript
    }

    /// Forgets a chat locally (the Hermes session keeps running/stays saved).
    public func closeChat(_ key: String) async {
        guard let chat = chats.removeValue(forKey: key) else { return }
        liveToChat[chat.liveID] = nil
        if !chat.transcript.busy, let client { _ = try? await client.rpc.call("session.close", ["session_id": .string(chat.liveID)]) }
    }

    private func mutate(_ key: String, _ body: (inout Transcript) -> Void) {
        guard var chat = chats[key] else { return }
        body(&chat.transcript)
        chats[key] = chat
        continuation.yield(.transcript(chat: key, chat.transcript))
    }

    private func liveID(_ key: String) throws -> String {
        guard let live = chats[key]?.liveID else { throw RPCError(code: -1, message: "That chat isn't open.") }
        return live
    }

    public func send(_ key: String, text: String, attachments: [Attachment] = []) async throws {
        let client = try requireClient()
        let live = try liveID(key)
        for attachment in attachments {
            if attachment.isImage {
                let ext = (attachment.filename as NSString).pathExtension.lowercased()
                try await client.rpc.call("image.attach_bytes", ["session_id": .string(live), "data": .string(attachment.data.base64EncodedString()),
                                                                 "ext": .string(ext.isEmpty ? "jpg" : ext), "filename": .string(attachment.filename)], timeout: 120)
            } else {
                let url = "data:application/octet-stream;base64," + attachment.data.base64EncodedString()
                try await client.rpc.call("file.attach", ["session_id": .string(live), "data_url": .string(url), "name": .string(attachment.filename)], timeout: 120)
            }
        }
        mutate(key) { $0.addUser(text, attachments: attachments.map(\.filename)) }
        do {
            try await client.rpc.call("prompt.submit", ["session_id": .string(live), "text": .string(text)], timeout: 60)
        } catch {
            mutate(key) { $0.addError((error as? LocalizedError)?.errorDescription ?? "Couldn't send.") }
            throw error
        }
    }

    public func interrupt(_ key: String) async throws {
        let client = try requireClient()
        try await client.rpc.call("session.interrupt", ["session_id": .string(try liveID(key))])
        mutate(key) { $0.status = "Stopping" }
    }

    /// Answers an approval/clarify/sudo/secret card.
    public func respond(_ key: String, request: PendingRequest, answer: String, questionID: String? = nil) async throws {
        let client = try requireClient()
        let live = try liveID(key)
        var params: [String: JSONValue] = ["session_id": .string(live), "request_id": .string(request.requestID)]
        switch request.kind {
        case .approval: params["choice"] = .string(answer)
        case .clarify, .clarifyBatch:
            params["answer"] = .string(answer)
            if let questionID { params["question_id"] = .string(questionID) }
        case .sudo: params["password"] = .string(answer)
        case .secret: params["value"] = .string(answer)
        }
        let result = try await client.rpc.call(request.respondMethod, params)
        let label: String
        switch request.kind {
        case .approval: label = answer == "deny" ? "Denied" : "Approved (\(answer))"
        case .sudo, .secret: label = answer.isEmpty ? "Skipped" : "Sent"
        default: label = answer
        }
        if result["status"]?.stringValue == "expired" { mutate(key) { $0.resolve(requestID: request.requestID, as: "Expired") } }
        else if questionID == nil || (result["remaining"]?.arrayValue?.isEmpty ?? true) {
            mutate(key) { $0.resolve(requestID: request.requestID, as: label) }
        }
    }

    public enum SlashOutcome: Sendable, Equatable {
        case output(String)
        case sent
        case prefill(String)
        case local
    }

    /// Runs a slash command the way Desktop does: Hermes executes it; skill and queue
    /// commands come back as a message to send.
    public func slash(_ key: String, _ commandLine: String) async throws -> SlashOutcome {
        let client = try requireClient()
        let live = try liveID(key)
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        let name = String(trimmed.dropFirst().split(separator: " ", maxSplits: 1).first ?? "")
        let arg = trimmed.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        var result: JSONValue
        do {
            result = try await client.rpc.call("slash.exec", ["session_id": .string(live), "command": .string(trimmed)], timeout: 120)
        } catch let error as RPCError where error.code == 4018 || error.code == 4004 && !arg.isEmpty {
            result = try await client.rpc.call("command.dispatch", ["session_id": .string(live), "name": .string(name), "arg": .string(arg)], timeout: 120)
        }
        if result["type"]?.stringValue == "alias", let target = result["target"]?.stringValue {
            return try await slash(key, target.hasPrefix("/") ? target : "/" + target)
        }
        if let notice = result["notice"]?.stringValue, !notice.isEmpty {
            mutate(key) { $0.items.append(ChatItem(kind: .notice(text: notice, level: "info"))) }
        }
        switch result["type"]?.stringValue {
        case "send":
            let message = result["message"]?.stringValue ?? ""
            if !message.isEmpty {
                mutate(key) { $0.addUser(trimmed) }
                try await client.rpc.call("prompt.submit", ["session_id": .string(live), "text": .string(message)])
            }
            return .sent
        case "prefill":
            let text = result["message"]?.stringValue ?? ""
            continuation.yield(.prefill(chat: key, text: text))
            return .prefill(text)
        default:
            let output = result["output"]?.stringValue ?? result.displayText
            mutate(key) { $0.addCommand(trimmed, output: Self.stripBoxDrawing(output)) }
            return .output(output)
        }
    }

    /// `/bg` — runs a separate agent; its answer lands in this chat when done.
    public func background(_ key: String, _ text: String) async throws {
        let client = try requireClient()
        let result = try await client.rpc.call("prompt.background", ["session_id": .string(try liveID(key)), "text": .string(text)])
        let task = result["task_id"]?.stringValue ?? UUID().uuidString
        mutate(key) { $0.addSide(id: "bg-" + task, label: "background", title: text) }
    }

    /// `/btw` — a side question that doesn't touch the main conversation.
    public func btw(_ key: String, _ text: String) async throws {
        let client = try requireClient()
        try await client.rpc.call("prompt.btw", ["session_id": .string(try liveID(key)), "text": .string(text)])
        mutate(key) { $0.status = "Answering your side question" }
    }

    /// Calls any gateway method for this chat's live session.
    public func call(_ key: String?, _ method: String, _ params: [String: JSONValue] = [:], timeout: TimeInterval = 60) async throws -> JSONValue {
        let client = try requireClient()
        var p = params
        if let key, p["session_id"] == nil { p["session_id"] = .string(try liveID(key)) }
        return try await client.rpc.call(method, p, timeout: timeout)
    }

    /// Hermes' CLI output uses box-drawing banners; keep the text readable on a phone.
    static func stripBoxDrawing(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !line.allSatisfy { "+-=|─━═ ".contains($0) } || line.isEmpty }
            .map { line -> String in
                var s = String(line)
                if s.hasPrefix("|"), s.hasSuffix("|") { s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
                return s
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
