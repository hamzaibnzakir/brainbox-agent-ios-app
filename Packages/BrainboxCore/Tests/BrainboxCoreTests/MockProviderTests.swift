import Foundation
import XCTest
@testable import BrainboxCore

final class MockAgentProviderTests: XCTestCase {
    func testIdentifiesItselfAsMockNeverHermes() {
        let provider = MockAgentProvider(configuration: .instant)
        XCTAssertEqual(provider.descriptor.kind, .mock)
        XCTAssertFalse(provider.descriptor.name.localizedCaseInsensitiveContains("hermes"))
    }

    func testStreamsToolsAndTextThenCompletes() async throws {
        let provider = MockAgentProvider(configuration: .instant)
        try await provider.connect()
        let request = AgentRequest(conversationID: UUID(), content: "check server status")
        let events = try await collect(provider.send(request))

        XCTAssertEqual(events.first, .accepted(requestID: request.requestID))
        XCTAssertEqual(events.last, .completed)
        XCTAssertTrue(events.contains { if case .toolStarted(let call) = $0 { return call.kind == .terminal }; return false })
        XCTAssertTrue(events.contains { if case .conversationTitle = $0 { return true }; return false })

        var message = Message(role: .assistant, content: "", state: .streaming)
        events.forEach { ChatReducer.apply($0, to: &message) }
        XCTAssertTrue(message.plainText.contains("mock agent"))
        XCTAssertEqual(message.segments.filter { if case .tool = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(message.toolCalls.count, 2)
        XCTAssertTrue(message.toolCalls.allSatisfy { $0.status == .succeeded })
        XCTAssertEqual(message.state, .complete)
        let status = await provider.currentStatus()
        XCTAssertEqual(status, .ready)
    }

    func testErrorScenarioFails() async throws {
        let provider = MockAgentProvider(configuration: .instant)
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "trigger an error")))
        guard case .failed(let error) = events.last else { return XCTFail("Expected failure") }
        XCTAssertEqual(error, .remote(code: "mock_error", message: "Simulated agent failure — use Retry to try again"))
    }

    func testDisconnectScenarioSimulatesConnectionLossAndRecovery() async throws {
        let provider = MockAgentProvider(configuration: .instant)
        try await provider.connect()
        let states = provider.connectionUpdates()
        let events = try await collect(provider.send(AgentRequest(conversationID: UUID(), content: "simulate disconnect")))
        XCTAssertEqual(events.last, .failed(.webSocketDisconnected))
        _ = try await waitFor(states) { if case .reconnecting = $0 { return true }; return false }
        _ = try await waitFor(provider.connectionUpdates()) { $0 == .connected }
    }

    func testCancellationStopsGeneration() async throws {
        let provider = MockAgentProvider(configuration: .standard)
        try await provider.connect()
        let request = AgentRequest(conversationID: UUID(), content: "long deploy please")
        let stream = provider.send(request)
        let collector = Task { try await self.collect(stream, timeout: 10) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await provider.cancel(requestID: request.requestID)
        let events = try await collector.value
        XCTAssertEqual(events.last, .failed(.cancelled))
        XCTAssertFalse(events.contains(.completed))
    }

    func testExecuteToolRunsMockShell() async throws {
        let provider = MockAgentProvider(configuration: .instant)
        let result = try await provider.executeTool(ToolInvocation(kind: .terminal, name: "terminal.run", arguments: ["command": "whoami"]))
        XCTAssertEqual(result.output, "brainbox\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testHermesProviderIsClearlyPending() async {
        let hermes = HermesProvider()
        XCTAssertTrue(hermes.capabilities.isEmpty)
        do {
            try await hermes.connect()
            XCTFail("Hermes must not pretend to connect")
        } catch {
            guard case .notImplemented = error.asAgentError else { return XCTFail("Unexpected \(error)") }
        }
        let events = (try? await collect(hermes.send(AgentRequest(conversationID: UUID(), content: "hi")))) ?? []
        guard case .failed(.notImplemented) = events.last else { return XCTFail("Expected notImplemented") }
        XCTAssertFalse(ProviderKind.hermes.isAvailable)
    }

    func testChunksPreserveText() {
        let text = "Hello there, this is\na **streaming** test."
        XCTAssertEqual(MockScenario.chunks(text).joined(), text)
        XCTAssertGreaterThan(MockScenario.chunks(text).count, 3)
    }
}

final class MockSystemProviderTests: XCTestCase {
    func testFileSystemCRUDAndPermissions() async throws {
        let fs = MockFileSystemProvider(latency: 0)
        let roots = try await fs.roots()
        XCTAssertEqual(roots.map(\.path), [MockFileSystemProvider.homeRoot, MockFileSystemProvider.configRoot, MockFileSystemProvider.logRoot])

        let config = try await fs.read("/etc/brainbox/gateway.yaml")
        XCTAssertTrue(config.text.contains("heartbeat_seconds"))

        let saved = try await fs.write(config.path, text: config.text + "\n# edited", expectedVersion: config.version)
        XCTAssertNotEqual(saved.version, config.version)

        do {
            _ = try await fs.write(config.path, text: "stale", expectedVersion: config.version)
            XCTFail("Expected conflict")
        } catch { XCTAssertEqual(error.asAgentError, .fileConflict(path: config.path)) }

        do {
            _ = try await fs.list("/root")
            XCTFail("Expected permission denied")
        } catch { guard case .permissionDenied = error.asAgentError else { return XCTFail("\(error)") } }

        do {
            _ = try await fs.write("/var/log/brainbox/gateway.log", text: "x", expectedVersion: nil)
            XCTFail("Logs are read-only")
        } catch { guard case .permissionDenied = error.asAgentError else { return XCTFail("\(error)") } }

        do {
            _ = try await fs.read("/home/brainbox/../../etc/shadow")
            XCTFail("Path traversal must be blocked")
        } catch { guard case .permissionDenied = error.asAgentError else { return XCTFail("\(error)") } }

        _ = try await fs.createDirectory(at: "/home/brainbox/new")
        _ = try await fs.createFile(at: "/home/brainbox/new/a.json")
        let renamed = try await fs.rename("/home/brainbox/new", to: "renamed")
        XCTAssertEqual(renamed.path, "/home/brainbox/renamed")
        let inside = try await fs.list("/home/brainbox/renamed")
        XCTAssertEqual(inside.map(\.name), ["a.json"])

        let found = try await fs.search("deploy", in: "/home/brainbox")
        XCTAssertEqual(found.map(\.name), ["deploy.sh"])

        try await fs.delete("/home/brainbox/renamed")
        let home = try await fs.list("/home/brainbox")
        XCTAssertFalse(home.contains { $0.name == "renamed" })

        do {
            try await fs.delete(MockFileSystemProvider.homeRoot)
            XCTFail("Roots cannot be deleted")
        } catch { guard case .permissionDenied = error.asAgentError else { return XCTFail("\(error)") } }
    }

    func testTerminalRunsAndTracksDirectory() async throws {
        let terminal = MockTerminalProvider(stepDelay: 0)
        let session = try await terminal.openSession()
        var output = ""
        var exit: Int?
        for try await chunk in terminal.run("pwd", in: session.id) {
            switch chunk {
            case .stdout(let s), .stderr(let s): output += s
            case .exit(let code): exit = code
            }
        }
        XCTAssertEqual(output, "/home/brainbox\n")
        XCTAssertEqual(exit, 0)

        for try await _ in terminal.run("cd /etc/brainbox", in: session.id) {}
        XCTAssertEqual(terminal.workingDirectory(of: session.id), "/etc/brainbox")

        var codes: [Int] = []
        for try await chunk in terminal.run("cd /root", in: session.id) { if case .exit(let c) = chunk { codes.append(c) } }
        for try await chunk in terminal.run("nonsense", in: session.id) { if case .exit(let c) = chunk { codes.append(c) } }
        for try await chunk in terminal.run("rm -rf /", in: session.id) { if case .exit(let c) = chunk { codes.append(c) } }
        XCTAssertEqual(codes, [1, 127, 1])
    }

    func testTerminalCancelInterruptsLongCommand() async throws {
        let terminal = MockTerminalProvider(stepDelay: 0.08)
        let session = try await terminal.openSession()
        let collector = Task { () -> [TerminalOutput] in
            var all: [TerminalOutput] = []
            for try await chunk in terminal.run("sleep 30", in: session.id) { all.append(chunk) }
            return all
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        await terminal.cancel(sessionID: session.id)
        let outputs = try await collector.value
        XCTAssertEqual(outputs.last, .exit(code: 130))
    }

    func testVPSServiceActionsAndMetrics() async throws {
        let vps = MockVPSProvider(latency: 0)
        let services = try await vps.services()
        XCTAssertTrue(services.contains { $0.name == "postgresql" && $0.state == .stopped })
        let started = try await vps.perform(.start, service: "postgresql")
        XCTAssertEqual(started.state, .running)
        let stopped = try await vps.perform(.stop, service: "nginx")
        XCTAssertEqual(stopped.state, .stopped)

        let metrics = try await vps.metrics()
        XCTAssertTrue((0...1).contains(metrics.cpuUsage))
        XCTAssertTrue((0...1).contains(metrics.memoryUsage))

        var count = 0
        for try await _ in vps.metricsStream(interval: 0.01) {
            count += 1
            if count == 3 { break }
        }
        XCTAssertEqual(count, 3)
    }

    func testLogStreamRespectsCategories() async throws {
        let logs = MockLogProvider(interval: 0.001)
        var seen: [LogEntry] = []
        for try await entry in logs.stream(categories: [.agent]) {
            seen.append(entry)
            if seen.count == 5 { break }
        }
        XCTAssertTrue(seen.allSatisfy { $0.category == .agent })
        let recent = try await logs.recent(limit: 20)
        XCTAssertEqual(recent.count, 20)
    }
}
