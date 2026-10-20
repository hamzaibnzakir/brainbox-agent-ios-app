import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where and how to reach a Hermes API Server.
///
/// `baseURL` may include a path prefix. Two deployments are supported:
///   * Brainbox gateway proxy (recommended): `https://vps.tailnet.ts.net:8443/hermes`
///     with a per-device token. The real `API_SERVER_KEY` never leaves the VPS.
///   * Direct (development, private network only): `http://100.x.y.z:8642`
///     with the server's bearer key.
public struct HermesConfiguration: Hashable, Sendable {
    public var baseURL: URL
    /// Optional Hermes profile for multiplexed gateways (`/p/<profile>/...`).
    public var profile: String?
    public var requestTimeout: TimeInterval
    /// Interval used when polling run status after a stream drops.
    public var pollInterval: TimeInterval

    public init(baseURL: URL, profile: String? = nil, requestTimeout: TimeInterval = 30, pollInterval: TimeInterval = 1.5) {
        self.baseURL = baseURL
        self.profile = profile
        self.requestTimeout = requestTimeout
        self.pollInterval = pollInterval
    }

    /// Profile names are validated client-side as well as server-side.
    public static func isValidProfileName(_ name: String) -> Bool {
        guard (1...32).contains(name.count) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard let first = name.first, first.isLetter, first.isLowercase else { return false }
        return name.allSatisfy { allowed.contains($0) }
    }
}

/// Typed client for the Hermes API Server routes verified in v0.21.2.
/// No endpoint outside that verified set is called.
public final class HermesAPIClient: @unchecked Sendable {
    public let configuration: HermesConfiguration
    private let transport: HTTPTransport
    private let tokenProvider: @Sendable () -> String?

    public init(configuration: HermesConfiguration, transport: HTTPTransport, tokenProvider: @escaping @Sendable () -> String?) {
        self.configuration = configuration
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    // MARK: URL building

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var prefix = configuration.baseURL.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if let profile = configuration.profile, !profile.isEmpty, profile != "default" {
            prefix += "/p/\(profile)"
        }
        var components = URLComponents(string: prefix + path) ?? URLComponents()
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        return components.url ?? configuration.baseURL
    }

    static func escape(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    private func headers(json: Bool, extra: [String: String] = [:]) -> [String: String] {
        var headers = extra
        headers["Accept"] = headers["Accept"] ?? "application/json"
        if json { headers["Content-Type"] = "application/json" }
        if let token = tokenProvider(), !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    // MARK: Core request helpers

    @discardableResult
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil,
                 headers extra: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> HTTPResponse {
        let data = try body.map { try JSONEncoder().encode($0) }
        let request = HTTPRequest(method: method, url: url(path, query: query), headers: headers(json: body != nil, extra: extra),
                                  body: data, timeout: timeout ?? configuration.requestTimeout)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw error.asAgentError
        }
        guard (200..<300).contains(response.status) else {
            throw Self.error(status: response.status, body: response.body)
        }
        return response
    }

    func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw AgentError.protocolViolation(detail: "Hermes returned an unexpected \(T.self) payload.")
        }
    }

    /// Maps Hermes error bodies (OpenAI-style `{"error":{...}}` or `{"error":"..."}`)
    /// to `AgentError`. Never includes request headers or tokens.
    static func error(status: Int, body: Data) -> AgentError {
        var message = "HTTP \(status)"
        var code = "http_\(status)"
        if let json = try? JSONDecoder().decode(JSONValue.self, from: body) {
            if let error = json["error"] {
                if let text = error.stringValue {
                    message = text
                } else {
                    message = error["message"]?.stringValue ?? message
                    code = error["code"]?.stringValue ?? error["type"]?.stringValue ?? code
                }
            } else if let text = json["message"]?.stringValue {
                message = text
            }
        }
        switch status {
        case 401:
            return .authenticationFailed(detail: "Hermes rejected the access token. Check the token in Settings → Connection.")
        case 403:
            return .permissionDenied(detail: message)
        case 404 where code == "http_404":
            return .remote(code: "not_found", message: "This Hermes server does not provide that endpoint.")
        case 429:
            return .remote(code: "rate_limited", message: "Too many requests. Try again in a moment.")
        case 502, 503, 504:
            return .serverUnavailable
        default:
            return .remote(code: code, message: message)
        }
    }

    // MARK: Discovery

    public func capabilities() async throws -> HermesCapabilities {
        try decode(HermesCapabilities.self, from: try await request("GET", "/v1/capabilities"))
    }

    /// Public liveness probe (no auth needed server-side).
    public func health() async throws -> Bool {
        let response = try await request("GET", "/health", timeout: 10)
        let json = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        return json?["status"]?.stringValue == "ok"
    }

    public func models() async throws -> [HermesModelInfo] {
        try decode(HermesListEnvelope<HermesModelInfo>.self, from: try await request("GET", "/v1/models")).data
    }

    public func skills() async throws -> [HermesSkill] {
        try decode(HermesListEnvelope<HermesSkill>.self, from: try await request("GET", "/v1/skills")).data
    }

    public func toolsets() async throws -> [HermesToolset] {
        try decode(HermesListEnvelope<HermesToolset>.self, from: try await request("GET", "/v1/toolsets")).data
    }

    // MARK: Sessions

    public func sessions(limit: Int = 50, offset: Int = 0, source: String? = nil) async throws -> HermesSessionPage {
        var query = ["limit": String(limit), "offset": String(offset)]
        if let source { query["source"] = source }
        return try decode(HermesSessionPage.self, from: try await request("GET", "/api/sessions", query: query))
    }

    public func session(id: String) async throws -> HermesSession {
        try decode(HermesSessionEnvelope.self, from: try await request("GET", "/api/sessions/\(Self.escape(id))")).session
    }

    /// Creates an empty session. App sessions always use the `ios_` prefix
    /// and source `api_server`, so they never collide with Telegram sessions.
    public func createSession(id: String, title: String? = nil, systemPrompt: String? = nil) async throws -> HermesSession {
        var body: [String: JSONValue] = ["id": .string(id), "source": "api_server"]
        if let title { body["title"] = .string(title) }
        if let systemPrompt { body["system_prompt"] = .string(systemPrompt) }
        return try decode(HermesSessionEnvelope.self, from: try await request("POST", "/api/sessions", body: .object(body))).session
    }

    public func updateSession(id: String, title: String? = nil, archived: Bool? = nil, pinned: Bool? = nil) async throws -> HermesSession {
        var body: [String: JSONValue] = [:]
        if let title { body["title"] = .string(title) }
        if let archived { body["archived"] = .bool(archived) }
        if let pinned { body["pinned"] = .bool(pinned) }
        return try decode(HermesSessionEnvelope.self, from: try await request("PATCH", "/api/sessions/\(Self.escape(id))", body: .object(body))).session
    }

    public func deleteSession(id: String) async throws {
        try await request("DELETE", "/api/sessions/\(Self.escape(id))")
    }

    /// Message history. `order` is "oldest" or "latest" (server default: latest page).
    public func messages(sessionID: String, limit: Int? = nil, offset: Int = 0, order: String? = nil) async throws -> HermesMessagePage {
        var query = ["offset": String(offset)]
        if let limit { query["limit"] = String(limit) }
        if let order { query["order"] = order }
        return try decode(HermesMessagePage.self, from: try await request("GET", "/api/sessions/\(Self.escape(sessionID))/messages", query: query))
    }

    /// Branches a session (CLI `/branch` semantics). Used to continue a
    /// Telegram conversation in the app without writing into the original.
    public func forkSession(id: String, title: String? = nil) async throws -> HermesSession {
        var body: [String: JSONValue] = [:]
        if let title { body["title"] = .string(title) }
        let response = try await request("POST", "/api/sessions/\(Self.escape(id))/fork", body: .object(body))
        if let envelope = try? JSONDecoder().decode(HermesSessionEnvelope.self, from: response.body) { return envelope.session }
        // Some versions return the new id at the top level.
        let json = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        if let newID = json?["session_id"]?.stringValue ?? json?["id"]?.stringValue {
            return HermesSession(id: newID, source: "api_server", title: title)
        }
        throw AgentError.protocolViolation(detail: "Hermes did not return the forked session.")
    }

    // MARK: Runs

    public struct RunOptions: Hashable, Sendable {
        public var sessionID: String?
        public var instructions: String?
        public var model: String?
        public var provider: String?
        public var idempotencyKey: String?
        /// Stable long-term memory scope (`X-Hermes-Session-Key`).
        public var sessionKey: String?

        public init(sessionID: String? = nil, instructions: String? = nil, model: String? = nil, provider: String? = nil,
                    idempotencyKey: String? = nil, sessionKey: String? = nil) {
            self.sessionID = sessionID
            self.instructions = instructions
            self.model = model
            self.provider = provider
            self.idempotencyKey = idempotencyKey
            self.sessionKey = sessionKey
        }
    }

    public func createRun(input: String, options: RunOptions = RunOptions()) async throws -> HermesRunAccepted {
        var body: [String: JSONValue] = ["input": .string(input)]
        if let sessionID = options.sessionID { body["session_id"] = .string(sessionID) }
        if let instructions = options.instructions, !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if let model = options.model, !model.isEmpty { body["model"] = .string(model) }
        if let provider = options.provider, !provider.isEmpty { body["provider"] = .string(provider) }
        var headers: [String: String] = [:]
        if let key = options.idempotencyKey { headers["Idempotency-Key"] = key }
        if let sessionKey = options.sessionKey { headers["X-Hermes-Session-Key"] = sessionKey }
        let response = try await request("POST", "/v1/runs", body: .object(body), headers: headers)
        return try decode(HermesRunAccepted.self, from: response)
    }

    public func runStatus(id: String) async throws -> HermesRunStatus {
        try decode(HermesRunStatus.self, from: try await request("GET", "/v1/runs/\(Self.escape(id))"))
    }

    /// Subscribes to a run's structured events. Hermes keeps one consumer
    /// per run and drops the buffer when that consumer disconnects, so a
    /// dropped stream is recovered by polling `runStatus`, never by
    /// re-subscribing (see `HermesAgentProvider`).
    public func runEvents(id: String) -> AsyncThrowingStream<HermesRunEvent, Error> {
        let request = HTTPRequest(method: "GET", url: url("/v1/runs/\(Self.escape(id))/events"),
                                  headers: headers(json: false, extra: ["Accept": "text/event-stream"]),
                                  timeout: 60 * 60)
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await transport.stream(request)
                    guard (200..<300).contains(response.status) else {
                        var body = Data()
                        for try await chunk in response.chunks { body.append(chunk); if body.count > 8192 { break } }
                        throw Self.error(status: response.status, body: body)
                    }
                    var parser = SSEParser()
                    var seen = Set<String>()
                    for try await chunk in response.chunks {
                        for event in parser.feed(chunk) {
                            if Self.emit(event, seen: &seen, into: continuation) { continuation.finish(); return }
                        }
                    }
                    for event in parser.finish() {
                        if Self.emit(event, seen: &seen, into: continuation) { continuation.finish(); return }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? AgentError.cancelled : error.asAgentError)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns true when the event was terminal.
    private static func emit(_ sse: SSEEvent, seen: inout Set<String>, into continuation: AsyncThrowingStream<HermesRunEvent, Error>.Continuation) -> Bool {
        // De-duplicate on event ids when the server provides them.
        if let id = sse.id {
            if seen.contains(id) { return false }
            seen.insert(id)
        }
        guard let event = HermesRunEvent.parse(data: sse.data) else { return false }
        continuation.yield(event)
        return event.isTerminal
    }

    @discardableResult
    public func stopRun(id: String) async throws -> HermesRunState {
        let response = try await request("POST", "/v1/runs/\(Self.escape(id))/stop", body: .object([:]))
        let json = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        return HermesRunState(raw: json?["status"]?.stringValue)
    }

    public func steerRun(id: String, text: String) async throws {
        try await request("POST", "/v1/runs/\(Self.escape(id))/steer", body: ["input": .string(text)])
    }

    /// Resolves one pending approval. Returns how many prompts were resolved.
    @discardableResult
    public func respondToApproval(runID: String, choice: HermesApprovalChoice, requestID: String? = nil) async throws -> Int {
        var body: [String: JSONValue] = ["choice": .string(choice.rawValue)]
        if let requestID { body["request_id"] = .string(requestID) }
        let response = try await request("POST", "/v1/runs/\(Self.escape(runID))/approval", body: .object(body))
        let json = try? JSONDecoder().decode(JSONValue.self, from: response.body)
        return json?["resolved"]?.intValue ?? 1
    }

    // MARK: Jobs

    public func jobs(includeDisabled: Bool = true) async throws -> [HermesJob] {
        let response = try await request("GET", "/api/jobs", query: includeDisabled ? ["include_disabled": "true"] : [:])
        return try decode(HermesJobsEnvelope.self, from: response).jobs
    }

    public func createJob(_ draft: HermesJobDraft) async throws -> HermesJob {
        let body = try JSONValue(encodingPlain: draft)
        return try decode(HermesJobEnvelope.self, from: try await request("POST", "/api/jobs", body: body)).job
    }

    public func updateJob(id: String, fields: [String: JSONValue]) async throws -> HermesJob {
        try decode(HermesJobEnvelope.self, from: try await request("PATCH", "/api/jobs/\(Self.escape(id))", body: .object(fields))).job
    }

    public func deleteJob(id: String) async throws {
        try await request("DELETE", "/api/jobs/\(Self.escape(id))")
    }

    @discardableResult
    public func pauseJob(id: String) async throws -> HermesJob {
        try decode(HermesJobEnvelope.self, from: try await request("POST", "/api/jobs/\(Self.escape(id))/pause", body: .object([:]))).job
    }

    @discardableResult
    public func resumeJob(id: String) async throws -> HermesJob {
        try decode(HermesJobEnvelope.self, from: try await request("POST", "/api/jobs/\(Self.escape(id))/resume", body: .object([:]))).job
    }

    @discardableResult
    public func runJobNow(id: String) async throws -> HermesJob {
        try decode(HermesJobEnvelope.self, from: try await request("POST", "/api/jobs/\(Self.escape(id))/run", body: .object([:]))).job
    }

    // MARK: Brainbox gateway admin (only when connected through the proxy)

    public func gatewayProfiles() async throws -> [BrainboxProfileInfo] {
        try decode(BrainboxProfileList.self, from: try await request("GET", "/brainbox/profiles")).profiles
    }

    public func gatewayCreateProfile(name: String, description: String?, cloneFromDefault: Bool) async throws -> BrainboxProfileInfo {
        guard HermesConfiguration.isValidProfileName(name) else {
            throw AgentError.permissionDenied(detail: "Profile names use lowercase letters, digits, - and _ (max 32), starting with a letter.")
        }
        var body: [String: JSONValue] = ["name": .string(name), "clone": .bool(cloneFromDefault)]
        if let description, !description.isEmpty { body["description"] = .string(description) }
        return try decode(BrainboxProfileEnvelope.self, from: try await request("POST", "/brainbox/profiles", body: .object(body), timeout: 90)).profile
    }

    public func gatewayInfo() async throws -> BrainboxGatewayInfo {
        try decode(BrainboxGatewayInfo.self, from: try await request("GET", "/brainbox/info", timeout: 10))
    }
}

// MARK: - Brainbox proxy admin models

public struct BrainboxProfileInfo: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String?
    public var hasAPIKey: Bool
    public var routable: Bool
    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, description, hasAPIKey = "has_api_key", routable }

    public init(name: String, description: String? = nil, hasAPIKey: Bool = false, routable: Bool = false) {
        self.name = name
        self.description = description
        self.hasAPIKey = hasAPIKey
        self.routable = routable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        hasAPIKey = (try? c.decode(Bool.self, forKey: .hasAPIKey)) ?? false
        routable = (try? c.decode(Bool.self, forKey: .routable)) ?? false
    }
}

struct BrainboxProfileList: Decodable { var profiles: [BrainboxProfileInfo] }
struct BrainboxProfileEnvelope: Decodable { var profile: BrainboxProfileInfo }

public struct BrainboxGatewayInfo: Decodable, Hashable, Sendable {
    public var service: String
    public var version: String?
    public var profileAdmin: Bool
    public var deviceName: String?

    enum CodingKeys: String, CodingKey { case service, version, profileAdmin = "profile_admin", deviceName = "device_name" }

    public init(service: String, version: String? = nil, profileAdmin: Bool = false, deviceName: String? = nil) {
        self.service = service
        self.version = version
        self.profileAdmin = profileAdmin
        self.deviceName = deviceName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        service = (try? c.decode(String.self, forKey: .service)) ?? "unknown"
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        profileAdmin = (try? c.decode(Bool.self, forKey: .profileAdmin)) ?? false
        deviceName = try? c.decodeIfPresent(String.self, forKey: .deviceName)
    }
}

extension JSONValue {
    /// Encodes with a plain JSONEncoder (snake_case keys come from CodingKeys).
    init<T: Encodable>(encodingPlain value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
