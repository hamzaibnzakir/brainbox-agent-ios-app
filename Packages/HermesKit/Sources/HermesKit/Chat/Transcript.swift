import BrainboxCore
import Foundation

/// A tool call as the chat shows it.
public struct ToolActivity: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable { case running, done, failed }
    public var id: String
    public var name: String
    public var context: String
    public var args: JSONValue
    public var status: Status
    public var duration: Double?
    public var output: String
    public var inlineDiff: String?
    public var approvalNote: String?

    public init(id: String, name: String, context: String, args: JSONValue, status: Status, duration: Double?,
                output: String, inlineDiff: String?, approvalNote: String?) {
        self.id = id
        self.name = name
        self.context = context
        self.args = args
        self.status = status
        self.duration = duration
        self.output = output
        self.inlineDiff = inlineDiff
        self.approvalNote = approvalNote
    }
}

/// Something Hermes is waiting on the user for.
public struct PendingRequest: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Dangerous command: choices like once/session/always/deny.
        case approval(command: String, description: String, choices: [String])
        /// The clarify tool: a question with optional choices.
        case clarify(question: String, choices: [String], multiSelect: Bool)
        /// Several clarify questions at once.
        case clarifyBatch([ClarifyQuestion])
        case sudo
        case secret(prompt: String, envVar: String)
    }

    public var requestID: String
    public var kind: Kind
    /// Set once answered (or expired) so the card shows the outcome.
    public var resolution: String?
    /// Newer Hermes asks with a JSON-RPC request (answered by id) instead of an event + `*.respond`.
    public var serverRequestID: JSONValue?
    /// The clarify question id when the server request carries one question.
    public var questionID: String?

    public init(requestID: String, kind: Kind, resolution: String? = nil, serverRequestID: JSONValue? = nil, questionID: String? = nil) {
        self.requestID = requestID
        self.kind = kind
        self.resolution = resolution
        self.serverRequestID = serverRequestID
        self.questionID = questionID
    }

    public var respondMethod: String {
        switch kind {
        case .approval: return "approval.respond"
        case .clarify, .clarifyBatch: return "clarify.respond"
        case .sudo: return "sudo.respond"
        case .secret: return "secret.respond"
        }
    }

    public var isSensitive: Bool {
        switch kind { case .sudo, .secret: return true; default: return false }
    }
}

public struct ClarifyQuestion: Hashable, Sendable {
    public var id: String
    public var question: String
    public var choices: [String]
    public var multiSelect: Bool

    public init(id: String, question: String, choices: [String], multiSelect: Bool) {
        self.id = id
        self.question = question
        self.choices = choices
        self.multiSelect = multiSelect
    }
}

public struct ChatItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case user(text: String, attachments: [String])
        case assistant(text: String, reasoning: String?, streaming: Bool)
        case tool(ToolActivity)
        case request(PendingRequest)
        /// Output of a slash command Hermes ran.
        case command(name: String, output: String)
        /// A side answer: `/btw` (question) or `/bg` (task).
        case side(label: String, title: String, text: String, done: Bool)
        case notice(text: String, level: String)
        case error(String)
    }

    public var id: String
    public var kind: Kind
    public var date: Date

    public init(id: String = UUID().uuidString, kind: Kind, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.date = date
    }
}

public struct TodoItem: Hashable, Sendable {
    public var id: String
    public var content: String
    public var status: String

    public init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = status
    }
}

public struct UsageInfo: Hashable, Sendable {
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?
    public var calls: Int
    public var costUSD: Double?

    init?(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        model = json["model"]?.stringValue
        inputTokens = json["input"]?.intValue ?? json["prompt"]?.intValue ?? 0
        outputTokens = json["output"]?.intValue ?? json["completion"]?.intValue ?? 0
        totalTokens = json["total"]?.intValue ?? inputTokens + outputTokens
        contextUsed = json["context_used"]?.intValue
        contextMax = json["context_max"]?.intValue
        contextPercent = json["context_percent"]?.intValue
        calls = json["calls"]?.intValue ?? 0
        costUSD = json["cost_usd"]?.doubleValue ?? json["cost"]?.doubleValue
    }
}

/// One chat's state, built only from what Hermes reports.
public struct Transcript: Hashable, Sendable {
    public var items: [ChatItem] = []
    public var title: String?
    /// A turn is in flight (message.start … message.complete / error).
    public var busy = false
    /// Short live status ("thinking", "preparing terminal", Hermes' own status text).
    public var status: String?
    public var todos: [TodoItem] = []
    public var usage: UsageInfo?
    public var model: String?
    public var lastSeq = 0
    public var lastCompletedText: String?
    /// The pet's mood, mirroring agent/pet/state.py's priority order.
    public var petMood: PetMood = .idle

    private var streamingID: String?
    private var seenSeqs: Set<Int> = []

    public init() {}

    public var pendingRequests: [PendingRequest] {
        items.compactMap { if case .request(let r) = $0.kind, r.resolution == nil { return r }; return nil }
    }

    // MARK: Hydrate from history

    /// Rebuilds from `session.resume`'s `messages` (role/text/name/context/args rows).
    public mutating func hydrate(messages: [JSONValue]) {
        items.removeAll()
        streamingID = nil
        for (index, m) in messages.enumerated() {
            let role = m["role"]?.stringValue ?? ""
            let text = m["text"]?.stringValue ?? m["content"]?.stringValue ?? ""
            let date = m["timestamp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let id = m["row_id"].map { "row-\($0.displayText)" } ?? "h-\(index)"
            switch role {
            case "user":
                items.append(ChatItem(id: id, kind: .user(text: text, attachments: []), date: date))
            case "assistant":
                guard !text.isEmpty else { continue }
                items.append(ChatItem(id: id, kind: .assistant(text: text, reasoning: m["reasoning"]?.stringValue, streaming: false), date: date))
            case "tool":
                let tool = ToolActivity(id: id, name: m["name"]?.stringValue ?? "tool", context: m["context"]?.stringValue ?? "",
                                        args: m["args"] ?? .null, status: .done, duration: nil, output: text,
                                        inlineDiff: nil, approvalNote: nil)
                items.append(ChatItem(id: id, kind: .tool(tool), date: date))
            case "system":
                if !text.isEmpty { items.append(ChatItem(id: id, kind: .notice(text: text, level: "info"), date: date)) }
            default:
                continue
            }
        }
    }

    // MARK: Live events

    /// Applies one event. Returns false for a duplicate (already-applied `seq`).
    @discardableResult
    public mutating func apply(_ event: GatewayEvent) -> Bool {
        if let seq = event.seq {
            if seenSeqs.contains(seq) { return false }
            seenSeqs.insert(seq)
            if seenSeqs.count > 4000 { seenSeqs = Set(seenSeqs.sorted().suffix(2000)) }
            lastSeq = max(lastSeq, seq)
        }
        let p = event.payload
        switch event.type {
        case "message.start":
            busy = true
            status = "Thinking"
            petMood = .busy
        case "thinking.delta":
            let text = p["text"]?.stringValue ?? ""
            status = text.isEmpty ? (busy ? "Working" : nil) : Self.cleanStatus(text)
        case "reasoning.delta":
            appendReasoning(p["text"]?.stringValue ?? "")
            petMood = .reasoning
        case "message.delta":
            appendText(p["text"]?.stringValue ?? "")
            status = "Responding"
            petMood = .busy
        case "message.interim":
            // Commentary between tool calls; when already streamed, the deltas carried it.
            if p["already_streamed"]?.boolValue != true, let text = p["text"]?.stringValue, !text.isEmpty {
                appendText(text)
            }
            finishStreaming()
        case "reasoning.available":
            if let text = p["text"]?.stringValue, !text.isEmpty { setReasoning(text) }
        case "message.complete":
            let text = p["text"]?.stringValue ?? ""
            completeAssistant(text)
            if let usage = UsageInfo(p["usage"]) { self.usage = usage }
            busy = false
            status = nil
            lastCompletedText = text
            petMood = p["interrupted"]?.boolValue == true ? .idle : .done
        case "tool.generating":
            finishStreaming()
            status = "Preparing \(p["name"]?.stringValue ?? "a tool")"
        case "tool.start":
            finishStreaming()
            let id = p["tool_id"]?.stringValue ?? UUID().uuidString
            let tool = ToolActivity(id: id, name: p["name"]?.stringValue ?? "tool", context: p["context"]?.stringValue ?? "",
                                    args: p["args"] ?? .null, status: .running, duration: nil, output: "",
                                    inlineDiff: nil, approvalNote: nil)
            upsert(ChatItem(id: "tool-" + id, kind: .tool(tool)))
            status = "Running \(tool.name)"
            petMood = .tool
        case "tool.progress":
            if let id = p["tool_id"]?.stringValue { updateTool(id) { $0.output += p["text"]?.stringValue ?? p["preview"]?.stringValue ?? "" } }
        case "tool.complete":
            let id = p["tool_id"]?.stringValue ?? ""
            let result = p["result"] ?? .null
            let failed = (result["error"].map { !$0.isNull && !$0.displayText.isEmpty } ?? false)
                || (result["exit_code"]?.intValue).map { $0 != 0 } == true
            let output = result["output"]?.stringValue ?? (result.isNull ? "" : result.displayText)
            let found = updateTool(id) {
                $0.status = failed ? .failed : .done
                $0.duration = p["duration_s"]?.doubleValue
                $0.output = output
                $0.inlineDiff = p["inline_diff"]?.stringValue
                $0.approvalNote = result["approval"]?.stringValue
            }
            if !found {
                let tool = ToolActivity(id: id, name: p["name"]?.stringValue ?? "tool", context: "", args: p["args"] ?? .null,
                                        status: failed ? .failed : .done, duration: p["duration_s"]?.doubleValue, output: output,
                                        inlineDiff: p["inline_diff"]?.stringValue, approvalNote: result["approval"]?.stringValue)
                items.append(ChatItem(id: "tool-" + id, kind: .tool(tool)))
            }
            status = busy ? "Working" : nil
            if failed { petMood = .failed }
        case "approval.request":
            finishStreaming()
            let request = PendingRequest(requestID: p["request_id"]?.stringValue ?? UUID().uuidString,
                                         kind: .approval(command: p["command"]?.stringValue ?? "",
                                                         description: p["description"]?.stringValue ?? "",
                                                         choices: p["choices"]?.arrayValue?.compactMap(\.stringValue) ?? ["once", "deny"]))
            upsert(ChatItem(id: "req-" + request.requestID, kind: .request(request)))
            status = "Waiting for your approval"
            petMood = .waiting
        case "clarify.request":
            finishStreaming()
            let rid = p["request_id"]?.stringValue ?? UUID().uuidString
            let kind: PendingRequest.Kind
            if let questions = p["questions"]?.arrayValue {
                kind = .clarifyBatch(questions.map {
                    ClarifyQuestion(id: $0["qid"]?.stringValue ?? UUID().uuidString, question: $0["question"]?.stringValue ?? "",
                                    choices: $0["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                    multiSelect: $0["multi_select"]?.boolValue ?? false)
                })
            } else {
                kind = .clarify(question: p["question"]?.stringValue ?? "", choices: p["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                multiSelect: p["multi_select"]?.boolValue ?? false)
            }
            upsert(ChatItem(id: "req-" + rid, kind: .request(PendingRequest(requestID: rid, kind: kind))))
            status = "Hermes has a question"
            petMood = .waiting
        case "sudo.request":
            let rid = p["request_id"]?.stringValue ?? UUID().uuidString
            upsert(ChatItem(id: "req-" + rid, kind: .request(PendingRequest(requestID: rid, kind: .sudo))))
            petMood = .waiting
        case "secret.request":
            let rid = p["request_id"]?.stringValue ?? UUID().uuidString
            upsert(ChatItem(id: "req-" + rid, kind: .request(PendingRequest(
                requestID: rid, kind: .secret(prompt: p["prompt"]?.stringValue ?? "", envVar: p["env_var"]?.stringValue ?? "")))))
            petMood = .waiting
        case "server.request":
            finishStreaming()
            guard let id = p["id"], let method = p["method"]?.stringValue else { break }
            let params = p["params"] ?? .null
            let rid = id.displayText
            var request: PendingRequest?
            switch method {
            case "approval":
                request = PendingRequest(requestID: rid, kind: .approval(command: params["command"]?.stringValue ?? "",
                                                                         description: params["description"]?.stringValue ?? "",
                                                                         choices: params["choices"]?.arrayValue?.compactMap(\.stringValue) ?? ["once", "deny"]),
                                         serverRequestID: id)
                status = "Waiting for your approval"
            case "clarify":
                let questions = (params["questions"]?.arrayValue ?? []).map {
                    ClarifyQuestion(id: $0["qid"]?.stringValue ?? UUID().uuidString, question: $0["question"]?.stringValue ?? "",
                                    choices: $0["choices"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                    multiSelect: $0["multi_select"]?.boolValue ?? false)
                }
                if questions.count == 1, let q = questions.first {
                    request = PendingRequest(requestID: rid, kind: .clarify(question: q.question, choices: q.choices, multiSelect: q.multiSelect),
                                             serverRequestID: id, questionID: q.id)
                } else {
                    request = PendingRequest(requestID: rid, kind: .clarifyBatch(questions), serverRequestID: id)
                }
                status = "Hermes has a question"
            case "sudo":
                request = PendingRequest(requestID: rid, kind: .sudo, serverRequestID: id)
            case "secret":
                request = PendingRequest(requestID: rid, kind: .secret(prompt: params["prompt"]?.stringValue ?? "",
                                                                       envVar: params["env_var"]?.stringValue ?? ""), serverRequestID: id)
            default:
                break
            }
            if let request {
                upsert(ChatItem(id: "req-" + rid, kind: .request(request)))
                petMood = .waiting
            }
        case "request.cancel":
            if let rid = p["id"]?.displayText { resolve(requestID: rid, as: "Withdrawn") }
        case "clarify.expire", "approval.expire":
            if let rid = p["request_id"]?.stringValue { resolve(requestID: rid, as: "Expired") }
        case "status.update":
            if let text = p["text"]?.stringValue, !text.isEmpty { status = Self.cleanStatus(text) }
        case "todo.updated":
            let list = p["todos"]?.arrayValue ?? p.arrayValue ?? []
            todos = list.enumerated().map { i, t in
                TodoItem(id: t["id"]?.displayText ?? "\(i)", content: t["content"]?.stringValue ?? t["text"]?.stringValue ?? "",
                         status: t["status"]?.stringValue ?? "pending")
            }
        case "session.title":
            if let t = p["title"]?.stringValue, !t.isEmpty { title = t }
        case "session.usage":
            if let usage = UsageInfo(p["usage"] ?? p) { self.usage = usage }
        case "session.info":
            if let m = p["model"]?.stringValue, !m.isEmpty { model = m }
        case "btw.complete":
            items.append(ChatItem(kind: .side(label: "btw", title: p["question"]?.stringValue ?? "Side question",
                                              text: p["text"]?.stringValue ?? "", done: true)))
        case "background.complete":
            let task = p["task_id"]?.stringValue ?? ""
            if let index = items.lastIndex(where: { $0.id == "bg-" + task }) {
                if case .side(let label, let title, _, _) = items[index].kind {
                    items[index].kind = .side(label: label, title: title, text: p["text"]?.stringValue ?? "", done: true)
                }
            } else {
                items.append(ChatItem(id: "bg-" + task, kind: .side(label: "background", title: "Background task",
                                                                    text: p["text"]?.stringValue ?? "", done: true)))
            }
        case "notification.show", "notice":
            if let text = p["text"]?.stringValue, !text.isEmpty {
                items.append(ChatItem(kind: .notice(text: text, level: p["level"]?.stringValue ?? "info")))
            }
        case "error":
            finishStreaming()
            items.append(ChatItem(kind: .error(p["message"]?.stringValue ?? p["text"]?.stringValue ?? "Hermes reported an error.")))
            busy = false
            status = nil
            petMood = .failed
        case "reaction":
            petMood = .celebrate
        default:
            break
        }
        return true
    }

    // MARK: Local echoes

    public mutating func addUser(_ text: String, attachments: [String] = []) {
        finishStreaming()
        items.append(ChatItem(kind: .user(text: text, attachments: attachments)))
        busy = true
        status = "Sending"
        petMood = .busy
    }

    public mutating func addCommand(_ name: String, output: String) {
        items.append(ChatItem(kind: .command(name: name, output: output)))
    }

    public mutating func addSide(id: String, label: String, title: String) {
        items.append(ChatItem(id: id, kind: .side(label: label, title: title, text: "", done: false)))
    }

    public mutating func addError(_ text: String) {
        items.append(ChatItem(kind: .error(text)))
        busy = false
        status = nil
    }

    public mutating func resolve(requestID: String, as resolution: String) {
        guard let index = items.firstIndex(where: { $0.id == "req-" + requestID }),
              case .request(var request) = items[index].kind else { return }
        request.resolution = resolution
        items[index].kind = .request(request)
        if pendingRequests.isEmpty, busy { status = "Working"; petMood = .busy }
    }

    // MARK: Internals

    private mutating func appendText(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let id = streamingID, let index = items.firstIndex(where: { $0.id == id }),
           case .assistant(let text, let reasoning, _) = items[index].kind {
            items[index].kind = .assistant(text: text + delta, reasoning: reasoning, streaming: true)
        } else {
            let id = "a-" + UUID().uuidString
            streamingID = id
            items.append(ChatItem(id: id, kind: .assistant(text: delta.trimmingLeadingNewlines, reasoning: nil, streaming: true)))
        }
    }

    private mutating func appendReasoning(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let id = streamingID, let index = items.firstIndex(where: { $0.id == id }),
           case .assistant(let text, let reasoning, let streaming) = items[index].kind {
            items[index].kind = .assistant(text: text, reasoning: (reasoning ?? "") + delta, streaming: streaming)
        } else {
            let id = "a-" + UUID().uuidString
            streamingID = id
            items.append(ChatItem(id: id, kind: .assistant(text: "", reasoning: delta, streaming: true)))
        }
    }

    private mutating func setReasoning(_ text: String) {
        // Some providers report the answer itself as "reasoning"; don't duplicate it.
        guard let index = lastAssistantIndex(), case .assistant(let body, let old, let streaming) = items[index].kind else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == body.trimmingCharacters(in: .whitespacesAndNewlines) { return }
        if old == nil || old?.isEmpty == true { items[index].kind = .assistant(text: body, reasoning: text, streaming: streaming) }
    }

    private func lastAssistantIndex() -> Int? {
        if let id = streamingID, let index = items.firstIndex(where: { $0.id == id }) { return index }
        guard let last = items.indices.last, case .assistant = items[last].kind else { return nil }
        return last
    }

    private mutating func finishStreaming() {
        guard let id = streamingID else { return }
        streamingID = nil
        if let index = items.firstIndex(where: { $0.id == id }), case .assistant(let text, let reasoning, _) = items[index].kind {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && (reasoning ?? "").isEmpty { items.remove(at: index) }
            else { items[index].kind = .assistant(text: trimmed, reasoning: reasoning, streaming: false) }
        }
    }

    /// `message.complete`'s text is the turn's final answer — authoritative for the last segment.
    private mutating func completeAssistant(_ final: String) {
        let finalTrimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = streamingID, let index = items.firstIndex(where: { $0.id == id }),
           case .assistant(let text, let reasoning, _) = items[index].kind {
            let body = finalTrimmed.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : finalTrimmed
            items[index].kind = .assistant(text: body, reasoning: reasoning, streaming: false)
        } else if !finalTrimmed.isEmpty, !turnAlreadyShows(finalTrimmed) {
            items.append(ChatItem(kind: .assistant(text: finalTrimmed, reasoning: nil, streaming: false)))
        }
        streamingID = nil
    }

    private func turnAlreadyShows(_ text: String) -> Bool {
        for item in items.reversed() {
            if case .user = item.kind { return false }
            if case .assistant(let body, _, _) = item.kind, body.trimmingCharacters(in: .whitespacesAndNewlines) == text { return true }
        }
        return false
    }

    private mutating func upsert(_ item: ChatItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
    }

    @discardableResult
    private mutating func updateTool(_ id: String, _ change: (inout ToolActivity) -> Void) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == "tool-" + id }), case .tool(var tool) = items[index].kind else { return false }
        change(&tool)
        items[index].kind = .tool(tool)
        return true
    }

    static func cleanStatus(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}

/// Mirrors `agent/pet/state.py`: what the companion pet should be doing.
public enum PetMood: String, Hashable, Sendable {
    case idle, busy, reasoning, tool, waiting, done, failed, celebrate

    /// The sprite-sheet row Hermes' pets use for this mood.
    public var spriteState: String {
        switch self {
        case .idle: return "idle"
        case .busy, .reasoning: return "run"
        case .tool: return "run"
        case .waiting: return "waiting"
        case .done: return "wave"
        case .failed: return "failed"
        case .celebrate: return "jump"
        }
    }
}

private extension String {
    var trimmingLeadingNewlines: String {
        String(drop { $0 == "\n" || $0 == "\r" })
    }
}
