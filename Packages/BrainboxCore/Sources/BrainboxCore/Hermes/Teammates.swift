import Foundation

// MARK: - Mascots

public enum MascotShape: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case orb, squircle, triangle, hexagon, pill, diamond
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct MascotStyle: Codable, Hashable, Sendable {
    public var shape: MascotShape
    /// 0…1 hue on the colour wheel.
    public var hue: Double

    public init(shape: MascotShape, hue: Double) {
        self.shape = shape
        self.hue = min(max(hue, 0), 1)
    }
}

/// What a mascot is expressing. Always derived from real state.
public enum MascotMood: String, Codable, CaseIterable, Hashable, Sendable {
    case idle, thinking, working, waitingApproval, happy, failed, offline
    /// The user stopped the work (confirmed by the backend).
    case interrupted

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .working: return "Running a tool"
        case .waitingApproval: return "Waiting for you"
        case .happy: return "Done"
        case .failed: return "Failed"
        case .offline: return "Offline"
        case .interrupted: return "Stopped"
        }
    }

    /// Derives the mood from agent status and the latest reply.
    ///  - `latest`: the teammate's most recent assistant message, if any.
    ///  - `celebrationWindow`: how long "happy"/"failed" linger after a reply ends.
    public static func derive(status: AgentStatus, connected: Bool, latest: Message?, isActiveTeammate: Bool,
                              now: Date = Date(), celebrationWindow: TimeInterval = 4) -> MascotMood {
        guard connected else { return .offline }
        if let latest, latest.pendingApproval != nil { return .waitingApproval }
        if isActiveTeammate, let latest, !latest.state.isTerminal || status.isBusy {
            switch status {
            case .runningTool: return .working
            case .thinking, .streaming: return .thinking
            default: return latest.state.isTerminal ? .idle : .thinking
            }
        }
        if let latest, latest.role == .assistant, now.timeIntervalSince(latest.createdAt) < 60 * 10 {
            let ended = latest.toolCalls.compactMap(\.finishedAt).max() ?? latest.createdAt
            if now.timeIntervalSince(ended) < celebrationWindow {
                switch latest.state {
                case .complete: return .happy
                case .failed: return .failed
                case .cancelled: return .interrupted
                default: break
                }
            }
        }
        return .idle
    }
}

// MARK: - Teammates

/// How far the user lets approvals for this teammate reach. Hermes decides
/// *when* an approval is needed; this only limits which of the server's
/// offered choices the app will show. It never approves anything by itself.
public enum ApprovalScopeLimit: String, Codable, CaseIterable, Hashable, Sendable {
    case onceOnly
    case allowSession
    case serverDefault

    public var title: String {
        switch self {
        case .onceOnly: return "Ask every time"
        case .allowSession: return "Allow session-wide approvals"
        case .serverDefault: return "Offer every choice Hermes allows"
        }
    }

    public func filter(_ choices: [String]) -> [String] {
        switch self {
        case .onceOnly: return choices.filter { $0 == "once" || $0 == "deny" }
        case .allowSession: return choices.filter { $0 != "always" }
        case .serverDefault: return choices
        }
    }
}

/// A named AI teammate. Teammates layer their own instructions on top of the
/// Hermes agent for every turn (`instructions` on `/v1/runs`). They share the
/// Hermes profile's tools, memory and machine unless `profile` routes them to
/// a separate Hermes profile — and even then a profile is not a sandbox.
public struct Teammate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var role: String
    public var instructions: String
    public var model: String?
    public var provider: String?
    /// Hermes profile to route to (`/p/<profile>/`). nil = default profile.
    public var profile: String?
    public var mascot: MascotStyle
    public var approvalScope: ApprovalScopeLimit
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, role: String, instructions: String, model: String? = nil, provider: String? = nil,
                profile: String? = nil, mascot: MascotStyle, approvalScope: ApprovalScopeLimit = .onceOnly,
                isArchived: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.role = role
        self.instructions = instructions
        self.model = model
        self.provider = provider
        self.profile = profile
        self.mascot = mascot
        self.approvalScope = approvalScope
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case emptyName, nameTooLong, instructionsTooLong, invalidProfile

        public var errorDescription: String? {
            switch self {
            case .emptyName: return "Give your teammate a name."
            case .nameTooLong: return "Names can be at most 40 characters."
            case .instructionsTooLong: return "Instructions can be at most 4,000 characters."
            case .invalidProfile: return "Profile names use lowercase letters, digits, - and _ and start with a letter."
            }
        }
    }

    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ValidationError.emptyName }
        if trimmed.count > 40 { throw ValidationError.nameTooLong }
        if instructions.count > 4_000 { throw ValidationError.instructionsTooLong }
        if let profile, !profile.isEmpty, profile != "default", !HermesConfiguration.isValidProfileName(profile) {
            throw ValidationError.invalidProfile
        }
    }

    /// The instructions sent with each run (role + instructions).
    public var runInstructions: String? {
        let parts = [
            role.isEmpty ? nil : "You are acting as the user's \(role) (teammate name: \(name)).",
            instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : instructions
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    public static let mainAssistantID = UUID(uuidString: "6B1A1E00-0000-4000-8000-000000000001")!

    /// Starter team. Instructions are suggestions the user can edit.
    public static var starterTeam: [Teammate] {
        [
            Teammate(id: mainAssistantID, name: "Main Assistant", role: "general assistant", instructions: "",
                     mascot: MascotStyle(shape: .orb, hue: 0.04), approvalScope: .onceOnly),
            Teammate(id: UUID(uuidString: "6B1A1E00-0000-4000-8000-000000000002")!, name: "Research Agent", role: "research analyst",
                     instructions: "Research thoroughly, cite your sources, and finish with a short summary of findings and open questions.",
                     mascot: MascotStyle(shape: .hexagon, hue: 0.58)),
            Teammate(id: UUID(uuidString: "6B1A1E00-0000-4000-8000-000000000003")!, name: "Shopify Manager", role: "Shopify store manager",
                     instructions: "Help manage the user's Shopify stores: products, collections, store design and conversion. Never change live store settings without asking first.",
                     mascot: MascotStyle(shape: .squircle, hue: 0.33)),
            Teammate(id: UUID(uuidString: "6B1A1E00-0000-4000-8000-000000000004")!, name: "Social Media Manager", role: "social media manager",
                     instructions: "Plan and draft social posts, captions and content calendars. Draft first; never publish without explicit approval.",
                     mascot: MascotStyle(shape: .pill, hue: 0.9)),
            Teammate(id: UUID(uuidString: "6B1A1E00-0000-4000-8000-000000000005")!, name: "Discord Manager", role: "Discord community manager",
                     instructions: "Help moderate and organise the user's Discord community. Draft announcements and moderation actions for review.",
                     mascot: MascotStyle(shape: .diamond, hue: 0.7))
        ]
    }
}

/// JSON-file backed teammate list.
public final class TeammateStore: @unchecked Sendable {
    private let cache: JSONFileCache<[Teammate]>?
    private let memory = Locked<[Teammate]?>(nil)

    public init(url: URL?) {
        cache = url.map { JSONFileCache<[Teammate]>(url: $0) }
    }

    public func load() -> [Teammate] {
        if let cached = memory.current { return cached }
        let loaded = cache?.load() ?? Teammate.starterTeam
        memory.withLock { $0 = loaded }
        return loaded
    }

    public func save(_ teammates: [Teammate]) {
        memory.withLock { $0 = teammates }
        cache?.store(teammates)
    }
}

// MARK: - Task (run) records

public struct RunTimelineEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case started, toolStarted, toolCompleted, toolFailed, output, reasoning, approvalRequested, approvalResolved,
             steered, subagent, completed, failed, cancelled, stopping, interrupted, info
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var title: String
    public var detail: String?

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, title: String, detail: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

/// A run started from this app, tracked by its real Hermes `run_id`.
/// Hermes has no "list runs" endpoint, so the app keeps its own index.
public struct RunRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String?
    public var conversationID: UUID?
    public var teammateID: UUID?
    public var title: String
    public var state: HermesRunState
    public var createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var error: String?
    public var outputPreview: String
    public var timeline: [RunTimelineEntry]

    public init(id: String, sessionID: String? = nil, conversationID: UUID? = nil, teammateID: UUID? = nil, title: String,
                state: HermesRunState = .queued, createdAt: Date = Date(), updatedAt: Date = Date(), finishedAt: Date? = nil,
                error: String? = nil, outputPreview: String = "", timeline: [RunTimelineEntry] = []) {
        self.id = id
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.teammateID = teammateID
        self.title = title
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.error = error
        self.outputPreview = outputPreview
        self.timeline = timeline
    }

    public static let maxTimeline = 300

    /// Applies one activity update. Pure; returns the updated record.
    public func applying(_ activity: RunActivity) -> RunRecord {
        var record = self
        record.updatedAt = activity.date
        if let sessionID = activity.sessionID { record.sessionID = sessionID }
        if let conversationID = activity.conversationID { record.conversationID = conversationID }
        if let teammateID = activity.teammateID { record.teammateID = teammateID }
        if let title = activity.title, record.title.isEmpty || record.title == "Agent run" { record.title = title }
        if let state = activity.state, !(record.state.isTerminal && !state.isTerminal) {
            record.state = state
            if state.isTerminal, record.finishedAt == nil { record.finishedAt = activity.date }
        }
        if let event = activity.event, let entry = Self.entry(for: event, at: activity.date) {
            // Coalesce streamed output into one growing entry.
            if entry.kind == .output, let last = record.timeline.last, last.kind == .output {
                record.timeline[record.timeline.count - 1].detail = String(((last.detail ?? "") + (entry.detail ?? "")).suffix(2_000))
            } else {
                record.timeline.append(entry)
                if record.timeline.count > Self.maxTimeline { record.timeline.removeFirst(record.timeline.count - Self.maxTimeline) }
            }
            if case .messageDelta(let delta) = event {
                record.outputPreview = String((record.outputPreview + delta).suffix(400))
            }
            if case .completed(let output, _, _) = event, let output, !output.isEmpty {
                record.outputPreview = String(output.suffix(400))
            }
            if case .failed(let error) = event { record.error = error }
            if case .interrupted(let error) = event { record.error = error }
        }
        return record
    }

    static func entry(for event: HermesRunEvent, at date: Date) -> RunTimelineEntry? {
        switch event {
        case .messageDelta(let delta): return RunTimelineEntry(date: date, kind: .output, title: "Writing reply", detail: delta)
        case .interim(let text, _): return RunTimelineEntry(date: date, kind: .output, title: "Update", detail: String(text.prefix(500)))
        case .queued(let message): return RunTimelineEntry(date: date, kind: .output, title: "Queued by Hermes", detail: message)
        case .toolStarted(let tool, let preview): return RunTimelineEntry(date: date, kind: .toolStarted, title: "Started \(tool)", detail: preview)
        case .toolCompleted(let tool, let duration, let isError):
            let detail = duration.map { String(format: "%.1fs", $0) }
            return RunTimelineEntry(date: date, kind: isError ? .toolFailed : .toolCompleted, title: isError ? "\(tool) failed" : "Finished \(tool)", detail: detail)
        case .reasoning(let text): return RunTimelineEntry(date: date, kind: .reasoning, title: "Reasoning", detail: String(text.prefix(500)))
        case .approvalRequest(let request): return RunTimelineEntry(date: date, kind: .approvalRequested, title: "Approval requested", detail: request.command)
        case .approvalResponded(let choice): return RunTimelineEntry(date: date, kind: .approvalResolved, title: "Approval: \(choice)")
        case .steered: return RunTimelineEntry(date: date, kind: .steered, title: "Steering accepted")
        case .subagentStarted(let goal, _): return RunTimelineEntry(date: date, kind: .subagent, title: "Delegated a subtask", detail: goal)
        case .subagentCompleted(let status, let summary, _): return RunTimelineEntry(date: date, kind: .subagent, title: "Subtask \(status ?? "finished")", detail: summary)
        case .completed: return RunTimelineEntry(date: date, kind: .completed, title: "Run completed")
        case .failed(let error): return RunTimelineEntry(date: date, kind: .failed, title: "Run failed", detail: error)
        case .cancelled: return RunTimelineEntry(date: date, kind: .cancelled, title: "Run cancelled")
        case .stopping: return RunTimelineEntry(date: date, kind: .stopping, title: "Stopping")
        case .interrupted(let error): return RunTimelineEntry(date: date, kind: .interrupted, title: "Run interrupted", detail: error)
        case .unknown: return nil
        }
    }
}
