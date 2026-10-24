import Foundation

// Slash commands in the chat composer.
//
// Hermes' API server never interprets slash commands — `/v1/runs` passes `input`
// straight to the model (hermes-agent 284d220). So a typed command is routed here,
// never sent to the model as text:
//
// * Brainbox commands: performed by the app through real API calls (stop, steer,
//   queue, title, model, approvals, …).
// * Hermes skill commands (`/<skill> …`): Hermes builds the message from the skill's
//   files (proxy → `build_skill_invocation_message`), and that message is what runs.
// * Other Hermes commands (`/compress`, `/yolo`, …): recognised from Hermes' own
//   registry and refused with an explanation — they only work in the CLI or Telegram.
// * `//text` sends "/text" literally.

/// Hermes' registry and skills, as listed by the proxy (`GET /brainbox/commands`).
public struct HermesCommandCatalog: Decodable, Hashable, Sendable {
    public struct Native: Decodable, Hashable, Sendable {
        public var name: String
        public var description: String
        public var category: String
        public var aliases: [String]
        public var argsHint: String
        public var cliOnly: Bool

        enum CodingKeys: String, CodingKey {
            case name, description, category, aliases
            case argsHint = "args_hint"
            case cliOnly = "cli_only"
        }

        public init(name: String, description: String, category: String = "", aliases: [String] = [], argsHint: String = "", cliOnly: Bool = false) {
            self.name = name
            self.description = description
            self.category = category
            self.aliases = aliases
            self.argsHint = argsHint
            self.cliOnly = cliOnly
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = (try? c.decode(String.self, forKey: .description)) ?? ""
            category = (try? c.decode(String.self, forKey: .category)) ?? ""
            aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
            argsHint = (try? c.decode(String.self, forKey: .argsHint)) ?? ""
            cliOnly = (try? c.decode(Bool.self, forKey: .cliOnly)) ?? false
        }
    }

    public struct Skill: Decodable, Hashable, Sendable {
        public var name: String
        public var description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
        enum CodingKeys: String, CodingKey { case name, description }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = (try? c.decode(String.self, forKey: .description)) ?? ""
        }
    }

    public var native: [Native]
    public var skills: [Skill]

    public init(native: [Native] = [], skills: [Skill] = []) {
        self.native = native
        self.skills = skills
    }

    enum CodingKeys: String, CodingKey { case native, skills }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        native = (try? c.decode([Native].self, forKey: .native)) ?? []
        skills = (try? c.decode([Skill].self, forKey: .skills)) ?? []
    }
}

/// Commands Brainbox performs itself, each through a real app or API action.
public enum AppCommand: String, CaseIterable, Sendable {
    case new, stop, steer, queue, retry, title, model, approve, deny, status
    case agents, sessions, skills, help, archive, files, terminal, parallel

    public var aliases: [String] {
        switch self {
        case .new: return ["reset"]
        case .queue: return ["q"]
        case .agents: return ["tasks"]
        case .help: return ["commands"]
        default: return []
        }
    }

    public var argsHint: String {
        switch self {
        case .steer, .queue: return "<instruction>"
        case .title: return "<name>"
        case .model: return "[model]"
        case .parallel: return "<task> | <task> | …"
        default: return ""
        }
    }

    public var requiresArgument: Bool { [.steer, .queue, .title, .parallel].contains(self) }

    public var summary: String {
        switch self {
        case .new: return "Start a new chat"
        case .stop: return "Stop the running reply (waits for Hermes to confirm)"
        case .steer: return "Give the running agent new guidance without stopping it"
        case .queue: return "Send this after the current reply ends"
        case .retry: return "Run the last message again"
        case .title: return "Rename this chat"
        case .model: return "Choose the model for this chat, or list models"
        case .approve: return "Approve the action the agent is waiting on (once)"
        case .deny: return "Deny the action the agent is waiting on"
        case .status: return "Connection, run and model status"
        case .agents: return "Open the Agent Workspace"
        case .sessions: return "Browse all Hermes sessions"
        case .skills: return "List the skills Hermes has"
        case .help: return "List the commands you can use here"
        case .archive: return "Archive this chat"
        case .files: return "Open the server's Brainbox files"
        case .terminal: return "Open the VPS terminal"
        case .parallel: return "Run several tasks as independent agents at once"
        }
    }
}

public enum ParsedCommand: Equatable, Sendable {
    /// Plain text for the agent (including `//escaped` text, already unescaped).
    case text(String)
    case app(AppCommand, argument: String)
    case skill(name: String, instruction: String)
    /// A real Hermes command the API can't run (CLI / messaging only).
    case unavailable(name: String, description: String, cliOnly: Bool)
    case missingArgument(AppCommand)
    case unknown(name: String, suggestion: String?)
}

public struct CommandSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case brainbox, skill, unavailable }
    public var name: String
    public var argsHint: String
    public var detail: String
    public var kind: Kind
    public var id: String { "\(kind)-\(name)" }

    public init(name: String, argsHint: String, detail: String, kind: Kind) {
        self.name = name
        self.argsHint = argsHint
        self.detail = detail
        self.kind = kind
    }

    /// What the composer becomes when the suggestion is picked.
    public var completion: String { "/\(name)" + (argsHint.isEmpty && kind != .skill ? "" : " ") }
}

public enum SlashCommandRouter {
    private static let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))

    /// `/name rest…` → (name, rest); nil when the text isn't shaped like a command
    /// (e.g. "/etc/hosts is broken" — the first token contains another slash).
    static func split(_ text: String) -> (name: String, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") else { return nil }
        let body = trimmed.dropFirst()
        let token = body.prefix { !$0.isWhitespace }
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else { return nil }
        let argument = body.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (token.lowercased(), argument)
    }

    public static func appCommand(named name: String) -> AppCommand? {
        AppCommand.allCases.first { $0.rawValue == name || $0.aliases.contains(name) }
    }

    public static func parse(_ text: String, catalog: HermesCommandCatalog?) -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") { return .text(String(trimmed.dropFirst())) }
        guard let parts = split(trimmed) else { return .text(trimmed) }
        let name = parts.name
        let argument = parts.argument
        if let command = appCommand(named: name) {
            if command.requiresArgument && argument.isEmpty { return .missingArgument(command) }
            return .app(command, argument: argument)
        }
        let skillKey = name.replacingOccurrences(of: "_", with: "-")
        if let skill = catalog?.skills.first(where: { $0.name == skillKey }) {
            return .skill(name: skill.name, instruction: argument)
        }
        if let native = catalog?.native.first(where: { $0.name == name || $0.aliases.contains(name) }) {
            return .unavailable(name: native.name, description: native.description, cliOnly: native.cliOnly)
        }
        return .unknown(name: name, suggestion: closest(to: name, catalog: catalog))
    }

    /// Autocomplete for a composer that starts with "/" (empty when it doesn't).
    public static func suggestions(for text: String, catalog: HermesCommandCatalog?, limit: Int = 8) -> [CommandSuggestion] {
        guard text.hasPrefix("/"), !text.hasPrefix("//"), !text.contains(" "), !text.contains("\n") else { return [] }
        let prefix = String(text.dropFirst()).lowercased()
        var out: [CommandSuggestion] = []
        for command in AppCommand.allCases where command.rawValue.hasPrefix(prefix) || command.aliases.contains(where: { $0.hasPrefix(prefix) }) {
            out.append(CommandSuggestion(name: command.rawValue, argsHint: command.argsHint, detail: command.summary, kind: .brainbox))
        }
        let skillPrefix = prefix.replacingOccurrences(of: "_", with: "-")
        for skill in catalog?.skills ?? [] where skill.name.hasPrefix(skillPrefix) {
            out.append(CommandSuggestion(name: skill.name, argsHint: "[instruction]", detail: skill.description, kind: .skill))
        }
        let taken = Set(out.map(\.name))
        if !prefix.isEmpty {
            for native in catalog?.native ?? [] where native.name.hasPrefix(prefix) && !taken.contains(native.name) && appCommand(named: native.name) == nil {
                out.append(CommandSuggestion(name: native.name, argsHint: native.argsHint,
                                             detail: "Hermes CLI/Telegram only — not available here", kind: .unavailable))
            }
        }
        return Array(out.prefix(limit))
    }

    /// Nearest command name (edit distance ≤ 2) for "did you mean".
    static func closest(to name: String, catalog: HermesCommandCatalog?) -> String? {
        var candidates = AppCommand.allCases.map(\.rawValue)
        candidates += catalog?.skills.map(\.name) ?? []
        let scored = candidates.map { ($0, distance(name, $0)) }.filter { $0.1 <= 2 }
        return scored.min { $0.1 < $1.1 }?.0
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// The error shown for commands that can't run, without sending anything.
    public static func explanation(for parsed: ParsedCommand) -> String? {
        switch parsed {
        case .unavailable(let name, let description, let cliOnly):
            return "/\(name) (\(description.isEmpty ? "Hermes command" : description)) only works in the Hermes \(cliOnly ? "CLI" : "CLI or Telegram"). The API Brainbox uses doesn't run commands, so nothing was sent."
        case .missingArgument(let command):
            return "/\(command.rawValue) needs \(command.argsHint) — e.g. /\(command.rawValue) \(command == .title ? "Trip plan" : "focus on the failing test")."
        case .unknown(let name, let suggestion):
            let hint = suggestion.map { " Did you mean /\($0)?" } ?? ""
            return "There's no /\(name) command.\(hint) Type / to see what's available, or start with // to send text that begins with a slash."
        default:
            return nil
        }
    }

    /// `/parallel a | b | c` → ["a", "b", "c"] (empty parts dropped).
    public static func parallelTasks(_ argument: String) -> [String] {
        argument.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

extension HermesAPIClient {
    /// Hermes' command registry and skill commands, via the Brainbox proxy.
    public func commandCatalog() async throws -> HermesCommandCatalog {
        let request = authorizedRequest("GET", "/brainbox/commands", extraHeaders: ["Accept": "application/json"], timeout: 30)
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        return try decode(HermesCommandCatalog.self, from: response)
    }

    /// The message Hermes builds for `/<skill> <instruction>` (sent as the run input).
    public func skillInvocation(name: String, instruction: String) async throws -> String {
        var request = authorizedRequest("POST", "/brainbox/commands/skill", extraHeaders: ["Content-Type": "application/json", "Accept": "application/json"], timeout: 30)
        request.body = try JSONEncoder().encode(JSONValue.object(["name": .string(name), "instruction": .string(instruction)]))
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        let json = try JSONDecoder().decode(JSONValue.self, from: response.body)
        guard let message = json["message"]?.stringValue, !message.isEmpty else {
            throw AgentError.protocolViolation(detail: "Hermes returned an empty skill message.")
        }
        return message
    }
}
