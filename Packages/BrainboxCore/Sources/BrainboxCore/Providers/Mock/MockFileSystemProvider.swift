import Foundation

/// In-memory file system for development. Exposes only a few allowed
/// roots (like a real gateway would) and enforces read-only areas so the
/// permission-denied UI paths can be exercised.
public final class MockFileSystemProvider: FileSystemProvider, @unchecked Sendable {
    struct Node {
        var isDirectory: Bool
        var text: String
        var modifiedAt: Date
        var isReadOnly: Bool
        var revision: Int
    }

    public static let homeRoot = "/home/brainbox"
    public static let configRoot = "/etc/brainbox"
    public static let logRoot = "/var/log/brainbox"

    private let nodes: Locked<[String: Node]>
    private let latency: TimeInterval
    private let readOnlyRoots: [String]
    public let allowedRoots: [String]

    public init(latency: TimeInterval = 0.12) {
        self.latency = latency
        self.allowedRoots = [Self.homeRoot, Self.configRoot, Self.logRoot]
        self.readOnlyRoots = [Self.logRoot]
        self.nodes = Locked(Self.seed())
    }

    // MARK: FileSystemProvider

    public func roots() async throws -> [FileEntry] {
        try await pause()
        return try allowedRoots.map { try entry(for: $0) }
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try await pause()
        let dir = try authorize(path)
        let snapshot = nodes.current
        guard let node = snapshot[dir] else { throw AgentError.fileUnavailable(path: dir) }
        guard node.isDirectory else { throw AgentError.fileUnavailable(path: dir) }
        let children = snapshot.keys.filter { FilePath.parent(of: $0) == dir && $0 != dir }
        return try children.map { try entry(for: $0) }
    }

    public func read(_ path: String) async throws -> FileContent {
        try await pause()
        let p = try authorize(path)
        guard let node = nodes.current[p], !node.isDirectory else { throw AgentError.fileUnavailable(path: p) }
        return FileContent(path: p, text: node.text, version: "r\(node.revision)")
    }

    @discardableResult
    public func write(_ path: String, text: String, expectedVersion: String?) async throws -> FileContent {
        try await pause()
        let p = try authorize(path, writing: true)
        return try nodes.withLock { all -> FileContent in
            guard var node = all[p], !node.isDirectory else { throw AgentError.fileUnavailable(path: p) }
            guard !node.isReadOnly else { throw AgentError.permissionDenied(detail: "\(p) is read-only.") }
            if let expectedVersion, expectedVersion != "r\(node.revision)" { throw AgentError.fileConflict(path: p) }
            node.text = text
            node.revision += 1
            node.modifiedAt = Date()
            all[p] = node
            return FileContent(path: p, text: text, version: "r\(node.revision)")
        }
    }

    public func createFile(at path: String) async throws -> FileEntry {
        try await create(path, directory: false)
    }

    public func createDirectory(at path: String) async throws -> FileEntry {
        try await create(path, directory: true)
    }

    public func rename(_ path: String, to newName: String) async throws -> FileEntry {
        try await pause()
        guard FilePath.isValidName(newName) else { throw AgentError.permissionDenied(detail: "“\(newName)” is not a valid name.") }
        let source = try authorize(path, writing: true)
        guard !allowedRoots.contains(source) else { throw AgentError.permissionDenied(detail: "Roots cannot be renamed.") }
        let destination = FilePath.join(FilePath.parent(of: source), newName)
        _ = try authorize(destination, writing: true)
        try nodes.withLock { all in
            guard all[source] != nil else { throw AgentError.fileUnavailable(path: source) }
            guard all[destination] == nil else { throw AgentError.permissionDenied(detail: "\(newName) already exists.") }
            let affected = all.keys.filter { $0 == source || $0.hasPrefix(source + "/") }
            for key in affected {
                let suffix = key.dropFirst(source.count)
                all[destination + suffix] = all.removeValue(forKey: key)
            }
        }
        return try entry(for: destination)
    }

    public func delete(_ path: String) async throws {
        try await pause()
        let p = try authorize(path, writing: true)
        guard !allowedRoots.contains(p) else { throw AgentError.permissionDenied(detail: "Roots cannot be deleted.") }
        try nodes.withLock { all in
            guard all[p] != nil else { throw AgentError.fileUnavailable(path: p) }
            for key in all.keys where key == p || key.hasPrefix(p + "/") { all.removeValue(forKey: key) }
        }
    }

    public func search(_ query: String, in path: String) async throws -> [FileEntry] {
        try await pause()
        let base = try authorize(path)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let matches = nodes.current.keys.filter {
            $0 != base && FilePath.isPath($0, inside: base) && FilePath.lastComponent(of: $0).localizedCaseInsensitiveContains(q)
        }
        return try matches.sorted().map { try entry(for: $0) }
    }

    // MARK: Helpers

    private func pause() async throws {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
    }

    private func authorize(_ path: String, writing: Bool = false) throws -> String {
        let normalized = FilePath.normalize(path)
        guard allowedRoots.contains(where: { FilePath.isPath(normalized, inside: $0) }) else {
            throw AgentError.permissionDenied(detail: "The gateway does not expose \(normalized).")
        }
        if writing, readOnlyRoots.contains(where: { FilePath.isPath(normalized, inside: $0) }) {
            throw AgentError.permissionDenied(detail: "\(normalized) is read-only.")
        }
        return normalized
    }

    private func create(_ path: String, directory: Bool) async throws -> FileEntry {
        try await pause()
        let name = FilePath.lastComponent(of: path)
        guard FilePath.isValidName(name) else { throw AgentError.permissionDenied(detail: "“\(name)” is not a valid name.") }
        let p = try authorize(path, writing: true)
        try nodes.withLock { all in
            guard all[FilePath.parent(of: p)]?.isDirectory == true else { throw AgentError.fileUnavailable(path: FilePath.parent(of: p)) }
            guard all[p] == nil else { throw AgentError.permissionDenied(detail: "\(name) already exists.") }
            all[p] = Node(isDirectory: directory, text: "", modifiedAt: Date(), isReadOnly: false, revision: 1)
        }
        return try entry(for: p)
    }

    private func entry(for path: String) throws -> FileEntry {
        guard let node = nodes.current[path] else { throw AgentError.fileUnavailable(path: path) }
        let readOnly = node.isReadOnly || readOnlyRoots.contains(where: { FilePath.isPath(path, inside: $0) })
        return FileEntry(
            path: path,
            isDirectory: node.isDirectory,
            size: Int64(node.text.utf8.count),
            modifiedAt: node.modifiedAt,
            permissions: node.isDirectory ? "drwxr-xr-x" : (readOnly ? "-r--r--r--" : "-rw-r--r--"),
            isReadOnly: readOnly
        )
    }

    // MARK: Seed data

    private static func seed() -> [String: Node] {
        let now = Date()
        func dir(_ minutesAgo: Double = 600) -> Node {
            Node(isDirectory: true, text: "", modifiedAt: now.addingTimeInterval(-minutesAgo * 60), isReadOnly: false, revision: 1)
        }
        func file(_ text: String, _ minutesAgo: Double, readOnly: Bool = false) -> Node {
            Node(isDirectory: false, text: text, modifiedAt: now.addingTimeInterval(-minutesAgo * 60), isReadOnly: readOnly, revision: 1)
        }
        return [
            homeRoot: dir(),
            homeRoot + "/projects": dir(240),
            homeRoot + "/projects/brainbox-gateway": dir(30),
            homeRoot + "/projects/brainbox-gateway/README.md": file(MockSamples.readme, 30),
            homeRoot + "/projects/brainbox-gateway/healthcheck.py": file(MockSamples.python, 95),
            homeRoot + "/projects/brainbox-gateway/package.json": file(MockSamples.packageJSON, 400),
            homeRoot + "/scripts": dir(1200),
            homeRoot + "/scripts/deploy.sh": file(MockSamples.deploy, 1200),
            homeRoot + "/notes.txt": file("Mock workspace.\nNothing here touches a real server.\n", 15),
            configRoot: dir(),
            configRoot + "/gateway.yaml": file(MockSamples.gatewayYAML, 60),
            configRoot + "/agent.json": file(MockSamples.agentJSON, 180),
            configRoot + "/settings.jsonc": file(MockSamples.settingsJSONC, 2880),
            logRoot: dir(1),
            logRoot + "/gateway.log": file(MockSamples.gatewayLog, 1, readOnly: true)
        ]
    }
}

enum MockSamples {
    static let readme = """
    # Brainbox Gateway (mock)

    This README lives in the **mock file system**. It exists so the editor,
    preview and diff screens can be tested without a server.

    ## Run

    ```bash
    npm install
    npm run start
    ```

    - Speaks the Brainbox Agent Protocol v1
    - Listens only on the Tailscale interface
    """

    static let python = """
    #!/usr/bin/env python3
    \"\"\"Mock health check used by the development provider.\"\"\"
    import json
    import time

    THRESHOLD = 0.85


    def check(metrics: dict) -> bool:
        # Healthy when every resource is under the threshold
        return all(value < THRESHOLD for value in metrics.values())


    if __name__ == "__main__":
        sample = {"cpu": 0.31, "memory": 0.58, "disk": 0.44}
        print(json.dumps({"healthy": check(sample), "ts": time.time()}))
    """

    static let packageJSON = """
    {
      "name": "brainbox-gateway",
      "version": "0.1.0",
      "private": true,
      "scripts": {
        "start": "node server.js",
        "test": "node --test"
      }
    }
    """

    static let deploy = """
    #!/usr/bin/env bash
    # Mock deploy script — never executed by the mock provider.
    set -euo pipefail

    SERVICE="brainbox-gateway"
    echo "Deploying ${SERVICE}..."
    git pull --ff-only
    npm ci --omit=dev
    sudo systemctl restart "${SERVICE}"
    echo "Done"
    """

    static let gatewayYAML = """
    # Brainbox gateway configuration (mock)
    server:
      listen: 100.64.0.10:8443
      tls: true
      heartbeat_seconds: 20

    auth:
      mode: bearer
      token_env: BRAINBOX_GATEWAY_TOKEN

    agent:
      provider: pending
      max_concurrent_requests: 4

    exposed_paths:
      - /home/brainbox
      - /etc/brainbox
      - /var/log/brainbox
    """

    static let agentJSON = """
    {
      "name": "Mock Agent",
      "streaming": true,
      "tools": ["terminal", "file", "service", "git"],
      "limits": {
        "max_tokens": 4096,
        "tool_timeout_seconds": 120
      }
    }
    """

    static let settingsJSONC = """
    {
      // Comments are allowed in JSONC
      "theme": "dark",
      "telemetry": false, /* never on */
      "retry": { "initial_ms": 500, "max_ms": 30000 }
    }
    """

    static let gatewayLog = """
    2026-10-08T03:12:44Z INFO  gateway listening on 100.64.0.10:8443
    2026-10-08T03:12:45Z INFO  auth mode=bearer
    2026-10-08T03:20:02Z WARN  client heartbeat late by 4.2s
    2026-10-08T03:20:03Z INFO  client resumed session
    """
}
