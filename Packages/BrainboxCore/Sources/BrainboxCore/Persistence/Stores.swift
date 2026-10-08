import Foundation

/// Local conversation history so chats are readable offline.
/// Conversations are stored as one JSON file each; no secrets are stored.
public protocol ConversationStore: AnyObject, Sendable {
    func loadAll() throws -> [Conversation]
    func save(_ conversation: Conversation) throws
    func delete(_ id: UUID) throws
    func deleteAll() throws
}

public final class FileConversationStore: ConversationStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Application Support/Conversations, created on demand.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BrainboxAgent", isDirectory: true).appendingPathComponent("Conversations", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    public func loadAll() throws -> [Conversation] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = WireCoding.decoder
        let conversations = files.compactMap { file -> Conversation? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(Conversation.self, from: data)
        }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ conversation: Conversation) throws {
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        let data = try WireCoding.encoder.encode(conversation)
        #if os(iOS)
        try data.write(to: url(for: conversation.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(for: conversation.id), options: [.atomic])
        #endif
    }

    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

public final class InMemoryConversationStore: ConversationStore, @unchecked Sendable {
    private let items = Locked<[UUID: Conversation]>([:])
    public init(_ initial: [Conversation] = []) {
        items.withLock { all in initial.forEach { all[$0.id] = $0 } }
    }
    public func loadAll() throws -> [Conversation] { items.withLock { Array($0.values) }.sorted { $0.updatedAt > $1.updatedAt } }
    public func save(_ conversation: Conversation) throws { items.withLock { $0[conversation.id] = conversation } }
    public func delete(_ id: UUID) throws { items.withLock { _ = $0.removeValue(forKey: id) } }
    public func deleteAll() throws { items.withLock { $0.removeAll() } }
}

/// Small typed JSON cache (e.g. last server snapshot, last directory
/// listing) used for offline viewing.
public final class JSONFileCache<Value: Codable>: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL(named name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BrainboxAgent", isDirectory: true).appendingPathComponent(name + ".json")
    }

    public func load() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? WireCoding.decoder.decode(Value.self, from: data)
    }

    public func store(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try WireCoding.encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Cache writes are best-effort; the live data is still shown.
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
