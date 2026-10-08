import Foundation

// MARK: - Server

public struct ServerInfo: Codable, Hashable, Sendable {
    public var hostname: String
    public var operatingSystem: String
    public var kernel: String
    public var architecture: String
    public var cpuCores: Int
    public var bootedAt: Date
    public var privateAddress: String?

    public init(hostname: String, operatingSystem: String, kernel: String, architecture: String, cpuCores: Int, bootedAt: Date, privateAddress: String? = nil) {
        self.hostname = hostname
        self.operatingSystem = operatingSystem
        self.kernel = kernel
        self.architecture = architecture
        self.cpuCores = cpuCores
        self.bootedAt = bootedAt
        self.privateAddress = privateAddress
    }

    public func uptime(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(bootedAt) }
}

public struct ServerMetrics: Codable, Hashable, Sendable {
    /// 0...1
    public var cpuUsage: Double
    public var memoryUsedBytes: Int64
    public var memoryTotalBytes: Int64
    public var diskUsedBytes: Int64
    public var diskTotalBytes: Int64
    public var networkRxBytesPerSecond: Double
    public var networkTxBytesPerSecond: Double
    public var loadAverage: [Double]
    public var timestamp: Date

    public init(cpuUsage: Double, memoryUsedBytes: Int64, memoryTotalBytes: Int64, diskUsedBytes: Int64, diskTotalBytes: Int64, networkRxBytesPerSecond: Double, networkTxBytesPerSecond: Double, loadAverage: [Double], timestamp: Date = Date()) {
        self.cpuUsage = cpuUsage
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.diskUsedBytes = diskUsedBytes
        self.diskTotalBytes = diskTotalBytes
        self.networkRxBytesPerSecond = networkRxBytesPerSecond
        self.networkTxBytesPerSecond = networkTxBytesPerSecond
        self.loadAverage = loadAverage
        self.timestamp = timestamp
    }

    public var memoryUsage: Double { ratio(memoryUsedBytes, memoryTotalBytes) }
    public var diskUsage: Double { ratio(diskUsedBytes, diskTotalBytes) }

    private func ratio(_ used: Int64, _ total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    /// Simple overall health derived from the metrics.
    public var health: ServerHealth {
        let peak = max(cpuUsage, memoryUsage, diskUsage)
        if peak >= 0.92 { return .critical }
        if peak >= 0.78 { return .degraded }
        return .healthy
    }
}

public enum ServerHealth: String, Codable, Sendable, Hashable {
    case healthy, degraded, critical, unknown

    public var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .degraded: return "Under pressure"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }
}

/// A cached snapshot so the VPS screen is useful while offline.
public struct ServerSnapshot: Codable, Hashable, Sendable {
    public var info: ServerInfo
    public var metrics: ServerMetrics
    public var services: [ServiceStatus]
    public var capturedAt: Date

    public init(info: ServerInfo, metrics: ServerMetrics, services: [ServiceStatus], capturedAt: Date = Date()) {
        self.info = info
        self.metrics = metrics
        self.services = services
        self.capturedAt = capturedAt
    }
}

public enum ServiceState: String, Codable, Sendable, Hashable {
    case running, stopped, failed, restarting, unknown
}

public struct ServiceStatus: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var summary: String
    public var state: ServiceState
    public var pid: Int?
    public var since: Date?
    public var memoryBytes: Int64?

    public init(name: String, summary: String, state: ServiceState, pid: Int? = nil, since: Date? = nil, memoryBytes: Int64? = nil) {
        self.name = name
        self.summary = summary
        self.state = state
        self.pid = pid
        self.since = since
        self.memoryBytes = memoryBytes
    }
}

public enum ServiceAction: String, Codable, Sendable, CaseIterable {
    case start, stop, restart

    public var isDestructive: Bool { self != .start }
}

public struct ProcessEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: Int { pid }
    public var pid: Int
    public var name: String
    public var user: String
    public var cpu: Double
    public var memoryBytes: Int64

    public init(pid: Int, name: String, user: String, cpu: Double, memoryBytes: Int64) {
        self.pid = pid
        self.name = name
        self.user = user
        self.cpu = cpu
        self.memoryBytes = memoryBytes
    }
}

// MARK: - Logs

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case debug, info, notice, warning, error, critical

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        case .critical: return 5
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    public var shortLabel: String {
        switch self {
        case .debug: return "DBG"
        case .info: return "INF"
        case .notice: return "NTC"
        case .warning: return "WRN"
        case .error: return "ERR"
        case .critical: return "CRT"
        }
    }
}

public enum LogCategory: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case agent, server, gateway, system, api, services
    public var id: String { rawValue }
    public var displayName: String { rawValue == "api" ? "API" : rawValue.capitalized }
}

public struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var level: LogLevel
    public var category: LogCategory
    public var source: String
    public var message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, category: LogCategory, source: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.source = source
        self.message = message
    }
}

/// Client-side filter. Clearing the viewer only clears the local buffer;
/// it never sends anything that could delete logs on the server.
public struct LogFilter: Hashable, Sendable {
    public var categories: Set<LogCategory>
    public var minimumLevel: LogLevel
    public var query: String

    public init(categories: Set<LogCategory> = Set(LogCategory.allCases), minimumLevel: LogLevel = .debug, query: String = "") {
        self.categories = categories
        self.minimumLevel = minimumLevel
        self.query = query
    }

    public func matches(_ entry: LogEntry) -> Bool {
        guard categories.contains(entry.category), entry.level >= minimumLevel else { return false }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return entry.message.localizedCaseInsensitiveContains(q) || entry.source.localizedCaseInsensitiveContains(q)
    }
}

// MARK: - Files

public struct FileEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedAt: Date
    public var permissions: String?
    public var isReadOnly: Bool

    public init(path: String, isDirectory: Bool, size: Int64 = 0, modifiedAt: Date = Date(), permissions: String? = nil, isReadOnly: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.isReadOnly = isReadOnly
    }

    public var name: String { FilePath.lastComponent(of: path) }
    public var fileExtension: String {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
    public var language: CodeLanguage { isDirectory ? .plainText : CodeLanguage.detect(fileName: name) }
}

public struct FileContent: Codable, Hashable, Sendable {
    public var path: String
    public var text: String
    /// Opaque version used for optimistic concurrency (etag / mtime / hash).
    public var version: String

    public init(path: String, text: String, version: String) {
        self.path = path
        self.text = text
        self.version = version
    }
}

public enum FileSortOrder: String, CaseIterable, Sendable, Identifiable {
    case name, modified, size
    public var id: String { rawValue }

    public func sort(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch self {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: return a.modifiedAt > b.modifiedAt
            case .size: return a.size > b.size
            }
        }
    }
}

public enum FilePath {
    public static func lastComponent(of path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == "/" { return "/" }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    public static func parent(of path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    public static func join(_ directory: String, _ name: String) -> String {
        let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if directory.hasSuffix("/") { return directory + cleanName }
        return directory + "/" + cleanName
    }

    /// Normalises `.` / `..` and duplicate slashes. Never escapes above `/`.
    public static func normalize(_ path: String) -> String {
        var stack: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = stack.popLast(); continue }
            stack.append(part)
        }
        return "/" + stack.joined(separator: "/")
    }

    /// True when `path` is equal to or inside `root` after normalisation.
    public static func isPath(_ path: String, inside root: String) -> Bool {
        let p = normalize(path)
        let r = normalize(root)
        if r == "/" { return true }
        return p == r || p.hasPrefix(r + "/")
    }

    /// A valid single path component (no slashes, not . or ..).
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/") && !trimmed.contains("\0")
    }
}

// MARK: - Terminal

public enum TerminalSessionState: String, Codable, Sendable, Hashable {
    case idle, running, closed
}

public struct TerminalSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var workingDirectory: String
    public var createdAt: Date
    public var state: TerminalSessionState

    public init(id: UUID = UUID(), title: String, workingDirectory: String, createdAt: Date = Date(), state: TerminalSessionState = .idle) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.state = state
    }
}

public enum TerminalOutput: Hashable, Sendable, Codable {
    case stdout(String)
    case stderr(String)
    case exit(code: Int)
}

/// Bounded command history with shell-like up/down navigation.
public struct CommandHistory: Sendable, Codable, Hashable {
    public private(set) var entries: [String] = []
    public var limit: Int
    private var cursor: Int?

    public init(limit: Int = 200) { self.limit = limit }

    public mutating func record(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        cursor = nil
        guard !trimmed.isEmpty else { return }
        if entries.last == trimmed { return }
        entries.append(trimmed)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// Older entry (arrow up).
    public mutating func previous() -> String? {
        guard !entries.isEmpty else { return nil }
        let next = (cursor ?? entries.count) - 1
        guard next >= 0 else { return entries.first }
        cursor = next
        return entries[next]
    }

    /// Newer entry (arrow down). Returns "" past the newest entry.
    public mutating func next() -> String? {
        guard let current = cursor else { return nil }
        let next = current + 1
        if next >= entries.count { cursor = nil; return "" }
        cursor = next
        return entries[next]
    }
}
