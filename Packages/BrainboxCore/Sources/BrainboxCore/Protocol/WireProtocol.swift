import Foundation

/// Brainbox Agent Protocol v1 — see docs/AGENT_PROTOCOL.md.
///
/// Every frame on the WebSocket is one UTF-8 JSON envelope:
///
///     { "v": 1, "type": "message.delta", "id": "evt_…",
///       "requestId": "…", "conversationId": "…",
///       "ts": "2026-10-08T04:38:00.000Z", "payload": { … } }
public struct WireEnvelope: Codable, Hashable, Sendable {
    public var v: Int
    public var type: String
    public var id: String
    public var requestId: String?
    public var conversationId: String?
    public var ts: Date
    public var payload: JSONValue

    public init(type: String, id: String = WireEnvelope.makeID(), requestId: String? = nil, conversationId: String? = nil, ts: Date = Date(), payload: JSONValue = .object([:])) {
        self.v = BrainboxProtocol.version
        self.type = type
        self.id = id
        self.requestId = requestId
        self.conversationId = conversationId
        self.ts = ts
        self.payload = payload
    }

    public static func makeID() -> String { "evt_" + UUID().uuidString.lowercased() }

    public func encodedString() throws -> String {
        let data = try WireCoding.encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentError.protocolViolation(detail: "Envelope is not UTF-8.")
        }
        return text
    }

    public static func decode(_ text: String) throws -> WireEnvelope {
        guard let data = text.data(using: .utf8) else {
            throw AgentError.protocolViolation(detail: "Frame is not UTF-8.")
        }
        let envelope: WireEnvelope
        do {
            envelope = try WireCoding.decoder.decode(WireEnvelope.self, from: data)
        } catch {
            throw AgentError.protocolViolation(detail: "Malformed frame from gateway.")
        }
        guard envelope.v == BrainboxProtocol.version else {
            throw AgentError.protocolViolation(detail: "Gateway speaks protocol v\(envelope.v); app expects v\(BrainboxProtocol.version).")
        }
        return envelope
    }
}

public enum BrainboxProtocol {
    public static let version = 1

    /// Client → gateway frame types.
    public enum ClientType {
        public static let hello = "auth.hello"
        public static let send = "message.send"
        public static let cancel = "request.cancel"
        public static let rpc = "rpc.call"
        public static let subscribe = "stream.subscribe"
        public static let unsubscribe = "stream.unsubscribe"
        public static let ping = "ping"
    }

    /// Gateway → client frame types.
    public enum ServerType {
        public static let authOK = "auth.ok"
        public static let authError = "auth.error"
        public static let accepted = "request.accepted"
        public static let status = "agent.status"
        public static let delta = "message.delta"
        public static let completed = "message.completed"
        public static let toolStarted = "tool.started"
        public static let toolOutput = "tool.output"
        public static let toolFinished = "tool.finished"
        public static let title = "conversation.title"
        public static let rpcResult = "rpc.result"
        public static let streamData = "stream.data"
        public static let streamEnd = "stream.end"
        public static let error = "error"
        public static let pong = "pong"
    }

    /// Request ids are carried as lowercase UUID strings.
    public static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
}

// MARK: - Payloads

public struct HelloPayload: Codable, Hashable, Sendable {
    public var token: String
    public var client: String
    public var clientVersion: String
    public var platform: String
    public var protocolVersion: Int
    /// Present when re-authenticating after a reconnect.
    public var resumeSession: String?

    public init(token: String, client: String = "brainbox-agent-ios", clientVersion: String, platform: String = "ios", protocolVersion: Int = BrainboxProtocol.version, resumeSession: String? = nil) {
        self.token = token
        self.client = client
        self.clientVersion = clientVersion
        self.platform = platform
        self.protocolVersion = protocolVersion
        self.resumeSession = resumeSession
    }
}

public struct AuthOKPayload: Codable, Hashable, Sendable {
    public var session: String
    public var agent: AgentDescriptorPayload
    public var capabilities: [String]
    public var heartbeatSeconds: Double?

    public init(session: String, agent: AgentDescriptorPayload, capabilities: [String], heartbeatSeconds: Double? = nil) {
        self.session = session
        self.agent = agent
        self.capabilities = capabilities
        self.heartbeatSeconds = heartbeatSeconds
    }

    public var providerCapabilities: Set<ProviderCapability> {
        Set(capabilities.compactMap(ProviderCapability.init(rawValue:)))
    }
}

public struct AgentDescriptorPayload: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String?

    public init(id: String, name: String, version: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
    }
}

public struct ToolStartedPayload: Codable, Hashable, Sendable {
    public var toolCallId: String
    public var kind: String
    public var name: String
    public var title: String
    public var input: String

    public init(toolCallId: String, kind: ToolKind, name: String, title: String, input: String) {
        self.toolCallId = toolCallId
        self.kind = kind.rawValue
        self.name = name
        self.title = title
        self.input = input
    }
}

public struct ToolFinishedPayload: Codable, Hashable, Sendable {
    public var toolCallId: String
    public var status: String
    public var output: String
    public var exitCode: Int?
    public var isError: Bool?
    public var truncated: Bool?

    public init(toolCallId: String, status: ToolStatus, result: ToolResult) {
        self.toolCallId = toolCallId
        self.status = status.rawValue
        self.output = result.output
        self.exitCode = result.exitCode
        self.isError = result.isError
        self.truncated = result.truncated
    }
}

public struct ErrorPayload: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool?

    public init(code: String, message: String, retryable: Bool? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var agentError: AgentError {
        switch code {
        case "auth_failed", "unauthorized": return .authenticationFailed(detail: message)
        case "agent_unavailable": return .agentUnavailable
        case "server_unavailable": return .serverUnavailable
        case "permission_denied", "forbidden": return .permissionDenied(detail: message)
        case "not_found": return .fileUnavailable(path: message)
        case "conflict": return .fileConflict(path: message)
        case "timeout": return .timedOut
        case "cancelled": return .cancelled
        case "not_implemented": return .notImplemented(detail: message)
        case "command_failed": return .commandFailed(exitCode: -1, detail: message)
        default: return .remote(code: code, message: message)
        }
    }

    public init(_ error: AgentError) {
        switch error {
        case .authenticationFailed(let d): self.init(code: "auth_failed", message: d)
        case .permissionDenied(let d): self.init(code: "permission_denied", message: d)
        case .fileUnavailable(let p): self.init(code: "not_found", message: p)
        case .fileConflict(let p): self.init(code: "conflict", message: p)
        case .timedOut: self.init(code: "timeout", message: error.message, retryable: true)
        case .cancelled: self.init(code: "cancelled", message: error.message)
        case .agentUnavailable: self.init(code: "agent_unavailable", message: error.message, retryable: true)
        case .serverUnavailable: self.init(code: "server_unavailable", message: error.message, retryable: true)
        case .notImplemented(let d): self.init(code: "not_implemented", message: d)
        case .remote(let code, let message): self.init(code: code, message: message)
        default: self.init(code: "internal", message: error.message)
        }
    }
}

// MARK: - Event mapping

public enum WireCodec {
    /// Builds the `message.send` frame for a request.
    public static func sendFrame(_ request: AgentRequest) -> WireEnvelope {
        WireEnvelope(
            type: BrainboxProtocol.ClientType.send,
            requestId: BrainboxProtocol.id(request.requestID),
            conversationId: BrainboxProtocol.id(request.conversationID),
            payload: [
                "content": .string(request.content),
                "responseMessageId": .string(BrainboxProtocol.id(request.responseMessageID))
            ]
        )
    }

    public static func cancelFrame(requestID: UUID) -> WireEnvelope {
        WireEnvelope(type: BrainboxProtocol.ClientType.cancel, requestId: BrainboxProtocol.id(requestID))
    }

    public static func encodeStatus(_ status: AgentStatus) -> JSONValue {
        switch status {
        case .ready: return ["state": "ready"]
        case .thinking: return ["state": "thinking"]
        case .streaming: return ["state": "streaming"]
        case .runningTool(let name): return ["state": "tool", "tool": .string(name)]
        case .offline: return ["state": "offline"]
        case .unavailable(let reason): return ["state": "unavailable", "reason": .string(reason)]
        }
    }

    public static func decodeStatus(_ payload: JSONValue) -> AgentStatus {
        switch payload["state"]?.stringValue {
        case "ready": return .ready
        case "thinking": return .thinking
        case "streaming": return .streaming
        case "tool": return .runningTool(name: payload["tool"]?.stringValue ?? "tool")
        case "offline": return .offline
        case "unavailable": return .unavailable(reason: payload["reason"]?.stringValue ?? "Unavailable")
        default: return .ready
        }
    }

    /// Maps a gateway frame belonging to an agent request to an `AgentEvent`.
    /// Returns nil for frames that are not agent events (e.g. pong).
    public static func event(from envelope: WireEnvelope) throws -> AgentEvent? {
        typealias S = BrainboxProtocol.ServerType
        switch envelope.type {
        case S.accepted:
            guard let raw = envelope.requestId, let id = UUID(uuidString: raw) else {
                throw AgentError.protocolViolation(detail: "request.accepted without a valid requestId.")
            }
            return .accepted(requestID: id)
        case S.status:
            return .status(decodeStatus(envelope.payload))
        case S.delta:
            guard let text = envelope.payload["text"]?.stringValue else {
                throw AgentError.protocolViolation(detail: "message.delta without text.")
            }
            return .textDelta(text)
        case S.toolStarted:
            let p: ToolStartedPayload = try envelope.payload.decode()
            return .toolStarted(ToolCall(
                id: p.toolCallId,
                kind: ToolKind(rawValue: p.kind) ?? .other,
                name: p.name,
                title: p.title,
                input: p.input,
                status: .running,
                startedAt: envelope.ts
            ))
        case S.toolOutput:
            guard let id = envelope.payload["toolCallId"]?.stringValue, let chunk = envelope.payload["chunk"]?.stringValue else {
                throw AgentError.protocolViolation(detail: "tool.output missing fields.")
            }
            return .toolOutput(toolCallID: id, chunk: chunk)
        case S.toolFinished:
            let p: ToolFinishedPayload = try envelope.payload.decode()
            let status = ToolStatus(rawValue: p.status) ?? .succeeded
            let result = ToolResult(output: p.output, exitCode: p.exitCode, isError: p.isError ?? (status == .failed), truncated: p.truncated ?? false)
            return .toolFinished(toolCallID: p.toolCallId, result: result, status: status)
        case S.title:
            return envelope.payload["title"]?.stringValue.map { .conversationTitle($0) }
        case S.completed:
            return .completed
        case S.error:
            let p: ErrorPayload = try envelope.payload.decode()
            return .failed(p.agentError)
        default:
            return nil
        }
    }

    /// The inverse of `event(from:)` — used by tests and by the reference
    /// gateway docs to show exactly what a backend must emit.
    public static func envelope(for event: AgentEvent, requestID: UUID, conversationID: UUID) throws -> WireEnvelope {
        typealias S = BrainboxProtocol.ServerType
        let rid = BrainboxProtocol.id(requestID)
        let cid = BrainboxProtocol.id(conversationID)
        func frame(_ type: String, _ payload: JSONValue = .object([:])) -> WireEnvelope {
            WireEnvelope(type: type, requestId: rid, conversationId: cid, payload: payload)
        }
        switch event {
        case .accepted: return frame(S.accepted)
        case .status(let status): return frame(S.status, encodeStatus(status))
        case .textDelta(let text): return frame(S.delta, ["text": .string(text)])
        case .toolStarted(let call):
            return frame(S.toolStarted, try JSONValue(encoding: ToolStartedPayload(toolCallId: call.id, kind: call.kind, name: call.name, title: call.title, input: call.input)))
        case .toolOutput(let id, let chunk):
            return frame(S.toolOutput, ["toolCallId": .string(id), "chunk": .string(chunk)])
        case .toolFinished(let id, let result, let status):
            return frame(S.toolFinished, try JSONValue(encoding: ToolFinishedPayload(toolCallId: id, status: status, result: result)))
        case .conversationTitle(let title): return frame(S.title, ["title": .string(title)])
        case .completed: return frame(S.completed)
        case .failed(let error): return frame(S.error, try JSONValue(encoding: ErrorPayload(error)))
        }
    }

    /// Whether a frame ends the request it belongs to.
    public static func isTerminal(_ type: String) -> Bool {
        typealias S = BrainboxProtocol.ServerType
        return type == S.completed || type == S.error || type == S.rpcResult || type == S.streamEnd
    }
}
