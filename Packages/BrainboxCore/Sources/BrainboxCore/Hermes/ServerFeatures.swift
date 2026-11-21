import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Client side of the Brainbox proxy's own endpoints (not Hermes): server overview,
// workspace files, the direct terminal and push registration. All of them use the
// same device token as every other request; none of them can reach anything the
// proxy doesn't explicitly allow.

// MARK: - Feature flags (from /brainbox/info)

public struct BrainboxFeatures: Decodable, Hashable, Sendable {
    public struct Push: Decodable, Hashable, Sendable {
        public var enabled: Bool
        public var ready: Bool
        public init(enabled: Bool = false, ready: Bool = false) {
            self.enabled = enabled
            self.ready = ready
        }
    }

    public var chatManagement: Bool
    /// The proxy lists Hermes' commands and builds skill messages.
    public var commands: Bool
    public var files: Bool
    public var diagnostics: Bool
    public var terminal: Bool
    public var push: Push
    /// Resumable, sequenced run events (`/brainbox/runs/{id}/events`).
    public var runRelay = false
    /// Hermes command handlers + /btw on the proxy.
    public var commandExec = false
    /// Telegram-vs-API parity report.
    public var parity = false
    /// The proxy adds Telegram's gateway prompt to runs.
    public var gatewayPrompt = false

    enum CodingKeys: String, CodingKey {
        case files, diagnostics, terminal, push, commands, parity
        case chatManagement = "chat_management"
        case runRelay = "run_relay"
        case commandExec = "command_exec"
        case gatewayPrompt = "gateway_prompt"
    }

    public init(chatManagement: Bool = false, commands: Bool = false, files: Bool = false, diagnostics: Bool = false, terminal: Bool = false, push: Push = Push()) {
        self.chatManagement = chatManagement
        self.commands = commands
        self.files = files
        self.diagnostics = diagnostics
        self.terminal = terminal
        self.push = push
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatManagement = (try? c.decode(Bool.self, forKey: .chatManagement)) ?? false
        commands = (try? c.decode(Bool.self, forKey: .commands)) ?? false
        files = (try? c.decode(Bool.self, forKey: .files)) ?? false
        diagnostics = (try? c.decode(Bool.self, forKey: .diagnostics)) ?? false
        terminal = (try? c.decode(Bool.self, forKey: .terminal)) ?? false
        push = (try? c.decode(Push.self, forKey: .push)) ?? Push()
        runRelay = (try? c.decode(Bool.self, forKey: .runRelay)) ?? false
        commandExec = (try? c.decode(Bool.self, forKey: .commandExec)) ?? false
        parity = (try? c.decode(Bool.self, forKey: .parity)) ?? false
        gatewayPrompt = (try? c.decode(Bool.self, forKey: .gatewayPrompt)) ?? false
    }
}

/// How the app's API path differs from Telegram's (`GET /brainbox/parity`). Never prompt text.
public struct HermesParityReport: Decodable, Hashable, Sendable {
    public struct Toolsets: Decodable, Hashable, Sendable {
        public var onlyTelegram: [String]
        public var onlyAPIServer: [String]
        public var explicitTelegram: Bool
        public var explicitAPIServer: Bool
        enum CodingKeys: String, CodingKey {
            case onlyTelegram = "only_telegram"
            case onlyAPIServer = "only_api_server"
            case explicitTelegram = "explicit_telegram"
            case explicitAPIServer = "explicit_api_server"
        }
    }
    public var toolsets: Toolsets
    public var model: String
    public var personaPromptChars: Int
    public var providerRouting: Bool
    public var prefillMessages: Int
    public var gatewayPromptApplied: Bool
    /// What Telegram does with a message sent while the agent works: interrupt | queue | steer.
    public var busyInputMode: String?
    public var hermesVersion: String?

    enum CodingKeys: String, CodingKey {
        case toolsets, model
        case busyInputMode = "busy_input_mode"
        case hermesVersion = "hermes_version"
        case personaPromptChars = "persona_prompt_chars"
        case providerRouting = "provider_routing"
        case prefillMessages = "prefill_messages"
        case gatewayPromptApplied = "gateway_prompt_applied"
    }

    /// Differences that remain after the app's and proxy's fixes, in plain words.
    public var remainingDifferences: [String] {
        var out: [String] = []
        if !toolsets.onlyTelegram.isEmpty {
            out.append("Tools only Telegram has: " + toolsets.onlyTelegram.joined(separator: ", ")
                       + (toolsets.explicitTelegram ? " (you configured Telegram's list explicitly)" : " (Hermes' default for the API server)"))
        }
        if personaPromptChars > 0 && !gatewayPromptApplied { out.append("Telegram's personality/system prompt isn't added to app runs (proxy setting off).") }
        if providerRouting { out.append("Provider routing preferences apply in Telegram but Hermes' API server doesn't pass them.") }
        if prefillMessages > 0 { out.append("\(prefillMessages) prefill message(s) apply in Telegram but not over the API.") }
        return out
    }
}

extension HermesAPIClient {
    public func parityReport() async throws -> HermesParityReport {
        let response = try await send(authorizedRequest("GET", "/brainbox/parity", extraHeaders: ["Accept": "application/json"], timeout: 60))
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        return try decode(HermesParityReport.self, from: response)
    }
}

// MARK: - Server overview (/brainbox/system)

public struct BrainboxSystemOverview: Decodable, Hashable, Sendable {
    public struct Memory: Decodable, Hashable, Sendable {
        public var totalBytes: Int64
        public var availableBytes: Int64
        enum CodingKeys: String, CodingKey { case totalBytes = "total_bytes", availableBytes = "available_bytes" }
        public var usedFraction: Double { totalBytes > 0 ? Double(totalBytes - availableBytes) / Double(totalBytes) : 0 }
    }

    public struct Disk: Decodable, Hashable, Sendable, Identifiable {
        public var path: String
        public var totalBytes: Int64
        public var usedBytes: Int64
        public var freeBytes: Int64
        public var id: String { path }
        enum CodingKeys: String, CodingKey { case path, totalBytes = "total_bytes", usedBytes = "used_bytes", freeBytes = "free_bytes" }
        public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    public struct Host: Decodable, Hashable, Sendable {
        public var hostname: String?
        public var os: String?
        public var kernel: String?
        public var uptimeSeconds: Double?
        public var loadAverage: [Double]?
        public var cpuCount: Int?
        public var memory: Memory?
        public var disks: [Disk]
        public var sampledAt: Double?

        enum CodingKeys: String, CodingKey {
            case hostname, os, kernel, memory, disks
            case uptimeSeconds = "uptime_seconds"
            case loadAverage = "load_average"
            case cpuCount = "cpu_count"
            case sampledAt = "sampled_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hostname = try? c.decodeIfPresent(String.self, forKey: .hostname)
            os = try? c.decodeIfPresent(String.self, forKey: .os)
            kernel = try? c.decodeIfPresent(String.self, forKey: .kernel)
            uptimeSeconds = HermesDecoding.number(c, .uptimeSeconds)
            loadAverage = try? c.decodeIfPresent([Double].self, forKey: .loadAverage)
            cpuCount = HermesDecoding.number(c, .cpuCount).map { Int($0) }
            memory = try? c.decodeIfPresent(Memory.self, forKey: .memory)
            disks = (try? c.decodeIfPresent([Disk].self, forKey: .disks)) ?? []
            sampledAt = HermesDecoding.number(c, .sampledAt)
        }
    }

    public struct Hermes: Decodable, Hashable, Sendable {
        public var reachable: Bool
        public var httpStatus: Int?
        public var latencyMs: Double?
        public var status: String?
        public var keyConfigured: Bool

        enum CodingKeys: String, CodingKey {
            case reachable, status
            case httpStatus = "http_status"
            case latencyMs = "latency_ms"
            case keyConfigured = "key_configured"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reachable = (try? c.decode(Bool.self, forKey: .reachable)) ?? false
            httpStatus = HermesDecoding.number(c, .httpStatus).map { Int($0) }
            latencyMs = HermesDecoding.number(c, .latencyMs)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            keyConfigured = (try? c.decode(Bool.self, forKey: .keyConfigured)) ?? false
        }
    }

    public struct Proxy: Decodable, Hashable, Sendable {
        public var version: String?
        public var uptimeSeconds: Double?
        public var features: BrainboxFeatures?
        enum CodingKeys: String, CodingKey { case version, features, uptimeSeconds = "uptime_seconds" }
    }

    public var host: Host
    public var hermes: Hermes
    public var proxy: Proxy
}

// MARK: - Workspace files (/brainbox/files)

public struct WorkspaceEntry: Decodable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case file, directory }
    public var name: String
    public var path: String
    public var kind: Kind
    public var size: Int64?
    public var modified: Double?
    public var mime: String?
    /// Stable server id (`f_…`) for files; nil for folders and older proxies.
    public var fileID: String?
    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, kind, size, modified, mime
        case fileID = "id"
    }

    public init(name: String, path: String, kind: Kind, size: Int64? = nil, modified: Double? = nil, mime: String? = nil, fileID: String? = nil) {
        self.fileID = fileID
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.mime = mime
    }

    public var isImage: Bool { mime?.hasPrefix("image/") ?? false }
    public var modifiedDate: Date? { modified.map { Date(timeIntervalSince1970: $0) } }
}

public struct WorkspaceListing: Decodable, Hashable, Sendable {
    public var path: String
    public var entries: [WorkspaceEntry]
    public var maxUploadBytes: Int64?
    public var allowedExtensions: [String]

    enum CodingKeys: String, CodingKey {
        case path, data
        case maxUploadBytes = "max_upload_bytes"
        case allowedExtensions = "allowed_extensions"
    }

    public init(path: String, entries: [WorkspaceEntry], maxUploadBytes: Int64? = nil, allowedExtensions: [String] = []) {
        self.path = path
        self.entries = entries
        self.maxUploadBytes = maxUploadBytes
        self.allowedExtensions = allowedExtensions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        entries = (try? c.decode([WorkspaceEntry].self, forKey: .data)) ?? []
        maxUploadBytes = HermesDecoding.number(c, .maxUploadBytes).map { Int64($0) }
        allowedExtensions = (try? c.decode([String].self, forKey: .allowedExtensions)) ?? []
    }
}

public struct WorkspaceUpload: Decodable, Hashable, Sendable {
    public var file: WorkspaceEntry
    /// Where the file lives on the server — what the agent is told to open.
    public var absolutePath: String?
    enum CodingKeys: String, CodingKey { case file, absolutePath = "absolute_path" }

    public init(file: WorkspaceEntry, absolutePath: String?) {
        self.file = file
        self.absolutePath = absolutePath
    }
}

/// Client-side checks that mirror the proxy's (the server checks again).
public enum WorkspacePolicy {
    public static let defaultMaxUploadBytes: Int64 = 25_000_000
    public static let defaultExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "pdf", "txt", "md", "csv", "tsv", "json", "yaml", "yml",
        "toml", "xml", "html", "log", "docx", "xlsx", "pptx", "rtf", "odt", "ods", "py", "js", "ts", "swift", "go", "rs",
        "java", "kt", "c", "h", "cpp", "rb", "php", "sh", "sql", "css", "zip", "tar", "gz", "mp3", "m4a", "wav", "mp4", "mov",
    ]

    /// Last path component, no control or shell-special characters, no leading dots.
    public static func safeName(_ raw: String) -> String? {
        let last = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._()+,@-"))
        var cleaned = String(String.UnicodeScalarView(last.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            return allowed.contains(scalar) ? scalar : "_"
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != "." , cleaned != ".." else { return nil }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            cleaned = ext.isEmpty || ext.count > 10 ? String(cleaned.prefix(120)) : String(stem.prefix(120 - ext.count - 1)) + "." + ext
        }
        return cleaned
    }

    public enum Problem: Error, Equatable, Sendable {
        case badName
        case typeNotAllowed(String)
        case tooLarge(limit: Int64)
        case empty

        public var message: String {
            switch self {
            case .badName: return "That file name can't be used."
            case .typeNotAllowed(let ext): return ext.isEmpty ? "Files without an extension aren't accepted." : "“.\(ext)” files aren't accepted by your server."
            case .tooLarge(let limit): return "Files can be at most \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))."
            case .empty: return "The file is empty."
            }
        }
    }

    public static func check(name: String, size: Int64, allowed: Set<String> = defaultExtensions,
                             maxBytes: Int64 = defaultMaxUploadBytes) -> Result<String, Problem> {
        guard let clean = safeName(name) else { return .failure(.badName) }
        let ext = (clean as NSString).pathExtension.lowercased()
        let stem = (clean as NSString).deletingPathExtension
        guard !ext.isEmpty, !stem.isEmpty, allowed.contains(ext) else { return .failure(.typeNotAllowed(ext)) }
        guard size > 0 else { return .failure(.empty) }
        guard size <= maxBytes else { return .failure(.tooLarge(limit: maxBytes)) }
        return .success(clean)
    }
}

/// How a chat message refers to files sent along with it. Attachments are uploaded
/// to the workspace inbox first; the agent opens them from there with its own tools.
public enum AttachmentPrompt {
    public struct Item: Hashable, Sendable {
        public var name: String
        public var serverPath: String
        public var isImage: Bool
        public init(name: String, serverPath: String, isImage: Bool) {
            self.name = name
            self.serverPath = serverPath
            self.isImage = isImage
        }
    }

    public static func compose(_ text: String, attachments: [Item]) -> String {
        guard !attachments.isEmpty else { return text }
        let plural: String = attachments.count == 1 ? "" : "s"
        var lines: [String] = []
        for item in attachments {
            let suffix: String = item.isImage ? " (image)" : ""
            lines.append("- " + item.serverPath + suffix)
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead: String = body.isEmpty ? "Please look at the attached file\(plural)." : body
        let header: String = "\n\n[Attached file\(plural) on the server]\n"
        return lead + header + lines.joined(separator: "\n")
    }
}

// MARK: - Push (/brainbox/push)

public struct BrainboxPushStatus: Decodable, Hashable, Sendable {
    public var enabled: Bool
    public var ready: Bool
    public var problems: [String]
    public var environment: String?
    public var registeredTokens: Int
    public var prefs: [String: Bool]
    public var events: [String]

    enum CodingKeys: String, CodingKey {
        case enabled, ready, problems, environment, prefs, events
        case registeredTokens = "registered_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        ready = (try? c.decode(Bool.self, forKey: .ready)) ?? false
        problems = (try? c.decode([String].self, forKey: .problems)) ?? []
        environment = try? c.decodeIfPresent(String.self, forKey: .environment)
        registeredTokens = (try? c.decode(Int.self, forKey: .registeredTokens)) ?? 0
        prefs = (try? c.decode([String: Bool].self, forKey: .prefs)) ?? [:]
        events = (try? c.decode([String].self, forKey: .events)) ?? []
    }
}

public enum PushEventKind: String, CaseIterable, Sendable, Identifiable {
    case jobDone = "job_done", jobFailed = "job_failed", longTask = "long_task", approval, connection
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .jobDone: return "Scheduled task finished"
        case .jobFailed: return "Scheduled task failed"
        case .longTask: return "Long task finished"
        case .approval: return "Approval needed"
        case .connection: return "Hermes not responding"
        }
    }
}

// MARK: - Terminal (/brainbox/terminal)

public struct BrainboxTerminalStatus: Decodable, Hashable, Sendable {
    public struct Session: Decodable, Hashable, Sendable, Identifiable {
        public var id: String
        public var created: Double?
        public var attached: Bool
        public var cols: Int?
        public var rows: Int?
    }

    public var available: Bool
    public var reason: String?
    public var code: String?
    public var user: String?
    public var sessions: [Session]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? false
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        user = try? c.decodeIfPresent(String.self, forKey: .user)
        sessions = (try? c.decodeIfPresent([Session].self, forKey: .sessions)) ?? []
    }

    enum CodingKeys: String, CodingKey { case available, reason, code, user, sessions }
}

public enum TerminalServerFrame: Equatable, Sendable {
    case ready(session: String, user: String, reattached: Bool, cols: Int, rows: Int)
    case output(String)
    case exit(code: Int)
    case error(code: String, message: String)

    public static func decode(_ text: String) -> TerminalServerFrame? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), let type = json["type"]?.stringValue else { return nil }
        switch type {
        case "ready":
            guard let id = json["session"]?.stringValue else { return nil }
            let user: String = json["user"]?.stringValue ?? ""
            let reattached: Bool = json["reattached"]?.boolValue ?? false
            let cols: Double = json["cols"]?.doubleValue ?? 80
            let rows: Double = json["rows"]?.doubleValue ?? 24
            return .ready(session: id, user: user, reattached: reattached, cols: Int(cols), rows: Int(rows))
        case "output":
            guard let data = json["data"]?.stringValue else { return nil }
            return .output(data)
        case "exit":
            let code: Double = json["code"]?.doubleValue ?? -1
            return .exit(code: Int(code))
        case "error":
            let code: String = json["code"]?.stringValue ?? "error"
            let message: String = json["message"]?.stringValue ?? "Terminal error"
            return .error(code: code, message: message)
        default: return nil
        }
    }
}

public enum TerminalClientFrame: Equatable, Sendable {
    case input(String)
    case resize(cols: Int, rows: Int)
    case interrupt
    case close

    public var json: String {
        let value: JSONValue
        switch self {
        case .input(let text): value = .object(["type": "input", "data": .string(text)])
        case .resize(let cols, let rows): value = .object(["type": "resize", "cols": .number(Double(cols)), "rows": .number(Double(rows))])
        case .interrupt: value = .object(["type": "interrupt"])
        case .close: value = .object(["type": "close"])
        }
        return String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }
}

/// Warns (never blocks) before sending a command that is commonly destructive.
public enum CommandRisk {
    private static let patterns: [(String, String)] = [
        (#"\bmkfs(\.\w+)?\b"#, "formats a disk"),
        (#"\bdd\b.*\bof=/dev/"#, "writes directly to a disk device"),
        (#"(^|[;&|]\s*|\bsudo\s+|\bsystemctl\s+)(shutdown|poweroff|halt|reboot)\b"#, "turns off or restarts the server"),
        (#"\bchmod\s+(-R\s+)?[0-7]?777\s+/(\s|$)"#, "opens permissions on the whole filesystem"),
        (#"\bchown\s+-R\s+\S+\s+/(\s|$)"#, "changes ownership of the whole filesystem"),
        (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "is a fork bomb"),
        (#">\s*/dev/sd[a-z]"#, "overwrites a disk device"),
        (#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba)?sh\b"#, "runs a script straight from the internet"),
        (#"\bsystemctl\s+(stop|disable|mask)\s+(ssh|sshd|tailscaled)\b"#, "can cut off your remote access"),
        (#"\biptables\s+-F\b|\bufw\s+(reset|disable)\b"#, "changes the firewall"),
    ]

    private static let criticalTargets: Set<String> = ["/", "/*", "~", "~/", "*", "$HOME", "/home", "/etc", "/var", "/usr", "/root", "/boot", "/opt"]

    /// `rm -r…` (any flag spelling) aimed at the filesystem root, home or a system folder.
    static func removesCriticalTree(_ line: String) -> Bool {
        for segment in line.split(whereSeparator: { ";|&\n".contains($0) }) {
            let tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let index = tokens.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { continue }
            let args = tokens[(index + 1)...]
            let shortFlags = args.filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }.joined()
            let recursive = shortFlags.contains("r") || shortFlags.contains("R") || args.contains("--recursive")
            if recursive, args.contains(where: { criticalTargets.contains($0) }) { return true }
        }
        return false
    }

    /// A short reason when the command looks high-risk, else nil.
    public static func warning(for command: String) -> String? {
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if removesCriticalTree(line) { return "This command deletes a whole system or home folder." }
        for (pattern, reason) in patterns where line.range(of: pattern, options: .regularExpression) != nil {
            return "This command \(reason)."
        }
        return nil
    }
}

// MARK: - Deep links (brainbox://…)

public enum BrainboxDeepLink: Equatable, Sendable {
    case chat(sessionID: String)
    case job(id: String)
    case run(id: String)
    case server
    case settings
    case files
    case terminal
    case agents(taskID: UUID?)

    public static func parse(_ url: URL) -> BrainboxDeepLink? {
        guard url.scheme?.lowercased() == "brainbox" else { return nil }
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        let idOK: (String) -> Bool = { $0.range(of: #"^[A-Za-z0-9_.:\-]{1,128}$"#, options: .regularExpression) != nil }
        switch (host, parts.count) {
        case ("chat", 1) where AppSessionID.isValid(parts[0]): return .chat(sessionID: parts[0])
        case ("tasks", 2) where parts[0] == "job" && idOK(parts[1]): return .job(id: parts[1])
        case ("tasks", 2) where parts[0] == "run" && idOK(parts[1]): return .run(id: parts[1])
        case ("server", 0): return .server
        case ("settings", 0): return .settings
        case ("files", 0): return .files
        case ("terminal", 0): return .terminal
        case ("agents", 0): return .agents(taskID: nil)
        case ("agents", 1): return UUID(uuidString: parts[0]).map { .agents(taskID: $0) }
        default: return nil
        }
    }
}

// MARK: - Client

extension HermesAPIClient {
    /// A ready-to-send request for the proxy's own endpoints (used by the app's
    /// URLSession upload/download tasks so it can show progress and cancel).
    public func authorizedRequest(_ method: String, _ path: String, query: [String: String] = [:],
                                  extraHeaders: [String: String] = [:], timeout: TimeInterval = 300) -> HTTPRequest {
        var headers = extraHeaders
        if let token = tokenProvider(), !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, url: gatewayURL(path, query: query), headers: headers, timeout: timeout)
    }

    /// Brainbox endpoints always live at the proxy root, never under a profile prefix.
    func gatewayURL(_ path: String, query: [String: String] = [:]) -> URL {
        with(profile: nil).url(path, query: query)
    }

    /// The terminal WebSocket (wss://…/brainbox/terminal) and its auth header.
    public func terminalSocket(session: String?, cols: Int, rows: Int) -> (url: URL, headers: [String: String]) {
        var query = ["cols": String(cols), "rows": String(rows)]
        if let session { query["session"] = session }
        let http = gatewayURL("/brainbox/terminal", query: query)
        var components = URLComponents(url: http, resolvingAgainstBaseURL: false)
        components?.scheme = http.scheme == "http" ? "ws" : "wss"
        var headers: [String: String] = [:]
        if let token = tokenProvider(), !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return (components?.url ?? http, headers)
    }

    private func gatewayCall(_ method: String, _ path: String, query: [String: String] = [:], body: JSONValue? = nil,
                             timeout: TimeInterval? = nil) async throws -> HTTPResponse {
        var request = HTTPRequest(method: method, url: gatewayURL(path, query: query), headers: [:], timeout: timeout ?? configuration.requestTimeout)
        request.headers["Accept"] = "application/json"
        if let token = tokenProvider(), !token.isEmpty { request.headers["Authorization"] = "Bearer \(token)" }
        if let body {
            request.headers["Content-Type"] = "application/json"
            request.body = try JSONEncoder().encode(body)
        }
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        return response
    }

    public func systemOverview() async throws -> BrainboxSystemOverview {
        try decode(BrainboxSystemOverview.self, from: try await gatewayCall("GET", "/brainbox/system", timeout: 15))
    }

    public func workspaceList(path: String = "") async throws -> WorkspaceListing {
        try decode(WorkspaceListing.self, from: try await gatewayCall("GET", "/brainbox/files", query: path.isEmpty ? [:] : ["path": path]))
    }

    public func workspaceDelete(path: String) async throws {
        _ = try await gatewayCall("DELETE", "/brainbox/files", query: ["path": path])
    }

    /// Small uploads in one request (the app uses `authorizedRequest` + URLSession for progress).
    public func workspaceUpload(name: String, data: Data) async throws -> WorkspaceUpload {
        var request = authorizedRequest("POST", "/brainbox/files/upload", query: ["area": "inbox", "name": name],
                                        extraHeaders: ["Content-Type": "application/octet-stream", "Accept": "application/json"])
        request.body = data
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        return try decode(WorkspaceUpload.self, from: response)
    }

    public func pushStatus() async throws -> BrainboxPushStatus {
        try decode(BrainboxPushStatus.self, from: try await gatewayCall("GET", "/brainbox/push"))
    }

    public func registerPush(token: String, environment: String, preferences: [String: Bool]) async throws {
        let prefs = JSONValue.object(preferences.mapValues { .bool($0) })
        _ = try await gatewayCall("POST", "/brainbox/push/register",
                                  body: .object(["token": .string(token), "environment": .string(environment), "preferences": prefs]))
    }

    public func unregisterPush() async throws {
        _ = try await gatewayCall("DELETE", "/brainbox/push/register")
    }

    /// Asks the server to send a test notification. Returns how many were accepted by Apple.
    public func sendTestPush() async throws -> Int {
        let response = try await gatewayCall("POST", "/brainbox/push/test", timeout: 30)
        let json = try JSONDecoder().decode(JSONValue.self, from: response.body)
        return Int(json["sent"]?.doubleValue ?? 0)
    }

    public func terminalStatus() async throws -> BrainboxTerminalStatus {
        try decode(BrainboxTerminalStatus.self, from: try await gatewayCall("GET", "/brainbox/terminal/status"))
    }
}

// MARK: - Request log (Diagnostics)

public struct RequestLogEntry: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var date: Date
    public var method: String
    /// Path only — never the query, headers or body.
    public var path: String
    public var status: Int?
    public var durationMs: Int
    public var error: String?
    public var streamed: Bool

    public var isFailure: Bool { error != nil || (status.map { $0 >= 400 } ?? false) }
}

/// Wraps a transport and remembers the last requests for the Diagnostics screen.
public final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let inner: HTTPTransport
    private let entries = Locked<[RequestLogEntry]>([])
    private let capacity: Int

    public init(_ inner: HTTPTransport, capacity: Int = 200) {
        self.inner = inner
        self.capacity = capacity
    }

    public var log: [RequestLogEntry] { entries.withLock { Array($0.reversed()) } }
    public func clear() { entries.withLock { $0.removeAll() } }

    private func record(_ request: HTTPRequest, start: Date, status: Int?, error: Error?, streamed: Bool) {
        let entry = RequestLogEntry(date: start, method: request.method, path: request.url.path, status: status,
                                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                                    error: error.map { ($0 as? AgentError)?.title ?? "Network error" }, streamed: streamed)
        entries.withLock { list in
            list.append(entry)
            if list.count > capacity { list.removeFirst(list.count - capacity) }
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let start = Date()
        do {
            let response = try await inner.send(request)
            record(request, start: start, status: response.status, error: nil, streamed: false)
            return response
        } catch {
            record(request, start: start, status: nil, error: error, streamed: false)
            throw error
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let start = Date()
        do {
            let response = try await inner.stream(request)
            record(request, start: start, status: response.status, error: nil, streamed: true)
            return response
        } catch {
            record(request, start: start, status: nil, error: error, streamed: true)
            throw error
        }
    }
}
