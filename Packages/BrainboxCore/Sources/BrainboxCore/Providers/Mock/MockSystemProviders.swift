import Foundation

/// Simulated VPS with gently drifting metrics and controllable services.
public final class MockVPSProvider: VPSProvider, @unchecked Sendable {
    private struct State {
        var cpu = 0.31
        var memory = 0.58
        var rx = 182_000.0
        var tx = 64_000.0
        var services: [ServiceStatus]
    }

    private let state: Locked<State>
    private let latency: TimeInterval
    private static let simulatedUptime: TimeInterval = 1_049_460 // 12d 3h 41m
    private let bootedAt = Date().addingTimeInterval(-MockVPSProvider.simulatedUptime)

    public init(latency: TimeInterval = 0.25) {
        self.latency = latency
        let since = Date().addingTimeInterval(-10 * 86_400)
        self.state = Locked(State(services: [
            ServiceStatus(name: "brainbox-gateway", summary: "Brainbox Agent Protocol gateway (mock)", state: .running, pid: 1342, since: since, memoryBytes: 88_000_000),
            ServiceStatus(name: "agent-runtime", summary: "Agent runtime placeholder (mock)", state: .running, pid: 1410, since: since, memoryBytes: 412_000_000),
            ServiceStatus(name: "tailscaled", summary: "Tailscale node agent (mock)", state: .running, pid: 611, since: since, memoryBytes: 41_000_000),
            ServiceStatus(name: "nginx", summary: "Reverse proxy (mock)", state: .running, pid: 902, since: since, memoryBytes: 12_000_000),
            ServiceStatus(name: "postgresql", summary: "Database (mock)", state: .stopped),
            ServiceStatus(name: "backup.timer", summary: "Nightly backups (mock)", state: .failed)
        ]))
    }

    public func serverInfo() async throws -> ServerInfo {
        try await pause()
        return ServerInfo(hostname: "mock-vps", operatingSystem: "Ubuntu 24.04 LTS (mock)", kernel: "6.8.0-45-generic", architecture: "x86_64", cpuCores: 4, bootedAt: bootedAt, privateAddress: "100.64.0.10")
    }

    public func metrics() async throws -> ServerMetrics {
        try await pause()
        return tick()
    }

    public func metricsStream(interval: TimeInterval) -> AsyncThrowingStream<ServerMetrics, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(self.tick())
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(interval, 0.05) * 1_000_000_000))
                    } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func services() async throws -> [ServiceStatus] {
        try await pause()
        return state.withLock { $0.services }
    }

    public func processes() async throws -> [ProcessEntry] {
        try await pause()
        return [
            ProcessEntry(pid: 1410, name: "agent-runtime", user: "brainbox", cpu: 12.4, memoryBytes: 412_000_000),
            ProcessEntry(pid: 1342, name: "brainbox-gateway", user: "brainbox", cpu: 3.1, memoryBytes: 88_000_000),
            ProcessEntry(pid: 611, name: "tailscaled", user: "root", cpu: 0.8, memoryBytes: 41_000_000),
            ProcessEntry(pid: 902, name: "nginx", user: "www-data", cpu: 0.2, memoryBytes: 12_000_000),
            ProcessEntry(pid: 1, name: "systemd", user: "root", cpu: 0.0, memoryBytes: 11_000_000)
        ]
    }

    public func perform(_ action: ServiceAction, service name: String) async throws -> ServiceStatus {
        guard state.withLock({ s in s.services.contains { $0.name == name } }) else {
            throw AgentError.fileUnavailable(path: name)
        }
        try await Task.sleep(nanoseconds: UInt64(max(latency * 3, 0) * 1_000_000_000))
        return state.withLock { s -> ServiceStatus in
            let index = s.services.firstIndex { $0.name == name }!
            var service = s.services[index]
            switch action {
            case .start, .restart:
                service.state = .running
                service.pid = Int.random(in: 2_000...9_000)
                service.since = Date()
            case .stop:
                service.state = .stopped
                service.pid = nil
                service.since = nil
            }
            s.services[index] = service
            return service
        }
    }

    private func pause() async throws {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
    }

    private func tick() -> ServerMetrics {
        state.withLock { s -> ServerMetrics in
            s.cpu = drift(s.cpu, by: 0.07, in: 0.08...0.88)
            s.memory = drift(s.memory, by: 0.015, in: 0.45...0.8)
            s.rx = drift(s.rx, by: 40_000, in: 20_000...900_000)
            s.tx = drift(s.tx, by: 20_000, in: 5_000...400_000)
            let total: Int64 = 8 * 1_073_741_824
            return ServerMetrics(
                cpuUsage: s.cpu,
                memoryUsedBytes: Int64(Double(total) * s.memory),
                memoryTotalBytes: total,
                diskUsedBytes: 35 * 1_073_741_824,
                diskTotalBytes: 80 * 1_073_741_824,
                networkRxBytesPerSecond: s.rx,
                networkTxBytesPerSecond: s.tx,
                loadAverage: [s.cpu * 4 * 0.9, s.cpu * 4 * 0.8, s.cpu * 4 * 0.7]
            )
        }
    }

    private func drift(_ value: Double, by step: Double, in range: ClosedRange<Double>) -> Double {
        min(max(value + Double.random(in: -step...step), range.lowerBound), range.upperBound)
    }
}

/// Generates a believable live log stream across all categories.
public final class MockLogProvider: LogStreamProvider, @unchecked Sendable {
    private let interval: TimeInterval

    public init(interval: TimeInterval = 0.7) {
        self.interval = interval
    }

    public func recent(limit: Int) async throws -> [LogEntry] {
        let now = Date()
        return (0..<max(limit, 0)).map { i in
            Self.makeEntry(seed: i, at: now.addingTimeInterval(-Double(limit - i) * 7))
        }
    }

    public func stream(categories: Set<LogCategory>) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var seed = Int.random(in: 0...1_000)
                while !Task.isCancelled {
                    let entry = Self.makeEntry(seed: seed, at: Date())
                    seed += 1
                    if categories.contains(entry.category) { continuation.yield(entry) }
                    let jitter = Double.random(in: 0.5...1.5)
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(self.interval * jitter, 0.01) * 1_000_000_000))
                    } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func makeEntry(seed: Int, at date: Date) -> LogEntry {
        let templates: [(LogLevel, LogCategory, String, String)] = [
            (.info, .agent, "agent", "Request completed in 1.84s (mock)"),
            (.debug, .gateway, "gateway", "heartbeat ok rtt=38ms"),
            (.info, .api, "api", "GET /v1/health 200 3ms"),
            (.notice, .services, "systemd", "brainbox-gateway.service: watchdog ok"),
            (.warning, .system, "kernel", "CPU frequency scaled to 2.1GHz"),
            (.info, .server, "sshd", "Accepted publickey for brainbox from 100.64.0.2"),
            (.info, .agent, "agent", "Tool call terminal.run finished exit=0"),
            (.warning, .gateway, "gateway", "client heartbeat late by 2.9s"),
            (.error, .services, "backup", "backup.timer failed: destination unreachable (mock)"),
            (.debug, .api, "api", "POST /v1/rpc vps.metrics 200 9ms"),
            (.info, .system, "cron", "Running hourly maintenance (mock)"),
            (.critical, .server, "disk", "Simulated alert: inode usage 91% on /var (mock)")
        ]
        let t = templates[abs(seed) % templates.count]
        return LogEntry(timestamp: date, level: t.0, category: t.1, source: t.2, message: t.3)
    }
}

public extension ProviderSuite {
    /// Everything simulated in-process. Clearly labelled as Mock in the UI.
    static func mock(fast: Bool = false) -> ProviderSuite {
        ProviderSuite(
            agent: MockAgentProvider(configuration: fast ? .instant : .standard),
            vps: MockVPSProvider(latency: fast ? 0 : 0.25),
            terminal: MockTerminalProvider(stepDelay: fast ? 0 : 0.08),
            files: MockFileSystemProvider(latency: fast ? 0 : 0.12),
            logs: MockLogProvider(interval: fast ? 0.01 : 0.7)
        )
    }

    /// Hermes is pending: only the agent slot exists, and it reports
    /// itself unavailable.
    static func hermesPending() -> ProviderSuite {
        ProviderSuite(agent: HermesProvider(), vps: nil, terminal: nil, files: nil, logs: nil)
    }
}
