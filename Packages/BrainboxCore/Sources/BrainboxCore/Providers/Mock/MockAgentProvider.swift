import Foundation

/// Development-only agent. It simulates streaming text, tool calls,
/// long-running tasks, errors and connection loss so the whole UI can be
/// built and tested without any backend.
///
/// It is NOT Hermes and never pretends to be: its descriptor, its replies
/// and the UI badge all say "Mock".
public final class MockAgentProvider: AgentProvider, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var connectDelay: TimeInterval
        public var thinkingDelay: TimeInterval
        public var tokenDelay: TimeInterval
        public var toolStepDelay: TimeInterval

        public init(connectDelay: TimeInterval, thinkingDelay: TimeInterval, tokenDelay: TimeInterval, toolStepDelay: TimeInterval) {
            self.connectDelay = connectDelay
            self.thinkingDelay = thinkingDelay
            self.tokenDelay = tokenDelay
            self.toolStepDelay = toolStepDelay
        }

        public static let standard = Configuration(connectDelay: 0.6, thinkingDelay: 0.7, tokenDelay: 0.028, toolStepDelay: 0.35)
        public static let instant = Configuration(connectDelay: 0, thinkingDelay: 0, tokenDelay: 0, toolStepDelay: 0)
    }

    private let configuration: Configuration
    private let connection = Broadcaster<ConnectionState>(initial: .disconnected)
    private let status = Broadcaster<AgentStatus>(initial: .offline)
    private let inFlight = Locked<[UUID: Task<Void, Never>]>([:])

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public var descriptor: AgentDescriptor {
        AgentDescriptor(id: "mock", name: "Mock Agent", kind: .mock, version: "dev", summary: "Simulated in-app agent for development")
    }

    public var capabilities: Set<ProviderCapability> {
        [.streaming, .cancellation, .toolExecution, .terminal, .fileSystem, .serverMetrics, .serviceControl, .logs]
    }

    public func connect() async throws {
        if connection.value == .connected { return }
        connection.send(.connecting)
        try await sleep(configuration.connectDelay)
        connection.send(.connected)
        status.send(.ready)
    }

    public func disconnect() async {
        let tasks = inFlight.withLock { all -> [Task<Void, Never>] in
            let values = Array(all.values)
            all.removeAll()
            return values
        }
        tasks.forEach { $0.cancel() }
        connection.send(.disconnected)
        status.send(.offline)
    }

    public func connectionUpdates() -> AsyncStream<ConnectionState> { connection.subscribe() }
    public func statusUpdates() -> AsyncStream<AgentStatus> { status.subscribe() }
    public func currentStatus() async -> AgentStatus { status.value }

    public func send(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(request, into: continuation)
                _ = self.inFlight.withLock { $0.removeValue(forKey: request.requestID) }
            }
            self.inFlight.withLock { $0[request.requestID] = task }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    public func cancel(requestID: UUID) async {
        inFlight.withLock { $0[requestID]?.cancel() }
    }

    public func conversationHistory() async throws -> [ConversationSummary] {
        // The mock keeps no server-side history; the app's local store is the source of truth.
        []
    }

    public func executeTool(_ invocation: ToolInvocation) async throws -> ToolResult {
        try await sleep(configuration.toolStepDelay)
        switch invocation.kind {
        case .terminal:
            let command = invocation.arguments["command"] ?? ""
            return MockShell.collect(MockShell.script(for: command, cwd: MockFileSystemProvider.homeRoot))
        case .service:
            let name = invocation.arguments["name"] ?? "service"
            let action = invocation.arguments["action"] ?? "status"
            return ToolResult(output: "\(action) \(name): ok (simulated)", exitCode: 0)
        default:
            return ToolResult(output: "\(invocation.name) is simulated by the mock provider.", exitCode: 0)
        }
    }

    // MARK: Simulation

    private func run(_ request: AgentRequest, into continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        let scenario = MockScenario.match(request.content)
        do {
            if connection.value != .connected { try await connect() }
            continuation.yield(.accepted(requestID: request.requestID))
            emitStatus(.thinking, continuation)
            try await sleep(configuration.thinkingDelay)

            if let title = scenario.title { continuation.yield(.conversationTitle(title)) }

            for step in scenario.steps {
                switch step {
                case .text(let text):
                    emitStatus(.streaming, continuation)
                    for chunk in MockScenario.chunks(text) {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(chunk))
                        try await sleep(configuration.tokenDelay)
                    }
                case .tool(let call, let outputLines, let result, let status):
                    emitStatus(.runningTool(name: call.kind.displayName), continuation)
                    continuation.yield(.toolStarted(call))
                    try await sleep(configuration.toolStepDelay)
                    for line in outputLines {
                        try Task.checkCancellation()
                        continuation.yield(.toolOutput(toolCallID: call.id, chunk: line))
                        try await sleep(configuration.toolStepDelay / 2)
                    }
                    continuation.yield(.toolFinished(toolCallID: call.id, result: result, status: status))
                case .pause(let seconds):
                    try await sleep(seconds * (configuration.toolStepDelay > 0 ? 1 : 0))
                case .fail(let error):
                    emitStatus(.ready, continuation)
                    continuation.yield(.failed(error))
                    continuation.finish()
                    return
                case .dropConnection:
                    emitStatus(.offline, continuation)
                    connection.send(.reconnecting(attempt: 1, retryIn: 1.5))
                    continuation.yield(.failed(.webSocketDisconnected))
                    continuation.finish()
                    let delay = configuration.connectDelay > 0 ? 1.8 : 0
                    Task {
                        try? await self.sleep(delay)
                        self.connection.send(.connected)
                        self.status.send(.ready)
                    }
                    return
                }
            }
            emitStatus(.ready, continuation)
            continuation.yield(.completed)
            continuation.finish()
        } catch {
            emitStatus(.ready, continuation)
            continuation.yield(.failed(error.asAgentError))
            continuation.finish()
        }
    }

    private func emitStatus(_ value: AgentStatus, _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) {
        status.send(value)
        continuation.yield(.status(value))
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if seconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } else {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

/// Scripted mock conversations, selected by keywords in the prompt.
public struct MockScenario: Sendable {
    public enum Step: Sendable {
        case text(String)
        case tool(ToolCall, output: [String], result: ToolResult, status: ToolStatus)
        case pause(TimeInterval)
        case fail(AgentError)
        case dropConnection
    }

    public var title: String?
    public var steps: [Step]

    public static func match(_ prompt: String) -> MockScenario {
        let p = prompt.lowercased()
        if p.contains("disconnect") || p.contains("connection loss") { return connectionLoss }
        if p.contains("error") || p.contains("fail") { return failure }
        if p.contains("deploy") || p.contains("long") { return longTask }
        if p.contains("status") || p.contains("server") || p.contains("health") { return serverStatus }
        if p.contains("config") || p.contains("file") || p.contains("yaml") { return configFile }
        if p.contains("code") || p.contains("python") || p.contains("script") { return code }
        return general(prompt)
    }

    /// Splits text into small word chunks, preserving whitespace, so the
    /// stream looks like real token output.
    public static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var wordCount = 0
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                wordCount += 1
                if wordCount >= 2 || character == "\n" {
                    result.append(current)
                    current = ""
                    wordCount = 0
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func tool(_ kind: ToolKind, _ name: String, _ title: String, _ input: String) -> ToolCall {
        ToolCall(id: "mock_" + UUID().uuidString.prefix(8).lowercased(), kind: kind, name: name, title: title, input: input)
    }

    static let serverStatus = MockScenario(title: "Server health check", steps: [
        .text("Checking the server now (this is the **mock agent**, so all values are simulated).\n\n"),
        .tool(tool(.terminal, "terminal.run", "Checking gateway service", "systemctl status brainbox-gateway"),
              output: ["● brainbox-gateway.service - Brainbox gateway (mock)\n", "     Active: active (running) since Mon 2026-09-28 01:12:04 UTC\n", "   Main PID: 1342\n"],
              result: ToolResult(output: "active (running)", exitCode: 0), status: .succeeded),
        .tool(tool(.system, "system.metrics", "Reading system metrics", "cpu · memory · disk"),
              output: ["cpu 31%  mem 58%  disk 44%\n"],
              result: ToolResult(output: "cpu 31%  mem 58%  disk 44%", exitCode: 0), status: .succeeded),
        .text("Everything looks healthy:\n\n- **Gateway** is running (PID 1342)\n- **CPU** 31%, **memory** 58%, **disk** 44%\n- Uptime is 12 days\n\nWant me to tail the gateway logs next?")
    ])

    static let configFile = MockScenario(title: "Gateway configuration", steps: [
        .tool(tool(.file, "fs.read", "Reading configuration", "/etc/brainbox/gateway.yaml"),
              output: [], result: ToolResult(output: "18 lines", exitCode: 0), status: .succeeded),
        .text("Here's the relevant part of `gateway.yaml` (mock file system):\n\n```yaml\nserver:\n  listen: 100.64.0.10:8443\n  tls: true\n  heartbeat_seconds: 20\n\nauth:\n  mode: bearer\n  token_env: BRAINBOX_GATEWAY_TOKEN\n```\n\nThe gateway only listens on the Tailscale address, which is what we want. You can open it in **Files → /etc/brainbox** to edit it.")
    ])

    static let code = MockScenario(title: "Health check script", steps: [
        .text("Here's a small Python health check you could run on the VPS:\n\n```python\nimport json, shutil, os\n\ndef disk_usage(path=\"/\"):\n    total, used, _ = shutil.disk_usage(path)\n    return round(used / total, 3)\n\nif __name__ == \"__main__\":\n    load = os.getloadavg()[0]\n    print(json.dumps({\"disk\": disk_usage(), \"load\": load}))\n```\n\nIt prints one JSON line, which makes it easy for the agent to parse later.")
    ])

    static let longTask = MockScenario(title: "Deploy gateway", steps: [
        .text("Starting a simulated deploy. Nothing is actually changed.\n\n"),
        .tool(tool(.git, "git.pull", "Pulling latest changes", "git pull --ff-only"),
              output: ["Updating 3f2a9c1..8e41d07\n", "Fast-forward\n", " server.js | 14 ++++++++------\n"],
              result: ToolResult(output: "1 file changed", exitCode: 0), status: .succeeded),
        .tool(tool(.code, "build", "Installing dependencies", "npm ci --omit=dev"),
              output: ["added 112 packages in 6s\n", "found 0 vulnerabilities\n"],
              result: ToolResult(output: "ok", exitCode: 0), status: .succeeded),
        .pause(0.8),
        .tool(tool(.service, "service.restart", "Restarting service", "systemctl restart brainbox-gateway"),
              output: ["Stopping brainbox-gateway…\n", "Starting brainbox-gateway…\n", "Health check passed\n"],
              result: ToolResult(output: "restarted", exitCode: 0), status: .succeeded),
        .text("Deploy finished (simulated):\n\n1. Pulled `8e41d07`\n2. Installed dependencies\n3. Restarted **brainbox-gateway** — health check passed")
    ])

    static let failure = MockScenario(title: "Simulated failure", steps: [
        .tool(tool(.terminal, "terminal.run", "Running command", "cat /root/secrets"),
              output: ["cat: /root/secrets: Permission denied\n"],
              result: ToolResult(output: "Permission denied", exitCode: 1, isError: true), status: .failed),
        .text("That path is outside what the gateway exposes. "),
        .fail(.remote(code: "mock_error", message: "Simulated agent failure — use Retry to try again"))
    ])

    static let connectionLoss = MockScenario(title: "Connection loss test", steps: [
        .text("Simulating a dropped connection in 3… 2… 1…"),
        .dropConnection
    ])

    static func general(_ prompt: String) -> MockScenario {
        MockScenario(title: nil, steps: [
            .text("I'm the **mock agent** that ships with Brainbox Agent for development, so this reply is scripted rather than generated.\n\nTry asking me to:\n\n- check **server status**\n- show the gateway **config** file\n- write a **python** script\n- run a **long deploy** (streams several tools)\n- trigger an **error** or a **disconnect**\n\nOnce the Brainbox gateway is running, switch to *Remote Agent* in Settings and the same screen will talk to your real agent.")
        ])
    }
}
