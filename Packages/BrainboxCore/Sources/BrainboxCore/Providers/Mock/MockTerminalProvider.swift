import Foundation

/// A tiny pretend shell for development. It never executes anything on
/// the device or any server — it only returns scripted output.
public final class MockTerminalProvider: TerminalProvider, @unchecked Sendable {
    private let sessions = Locked<[UUID: String]>([:])
    private let running = Locked<[UUID: Task<Void, Never>]>([:])
    private let stepDelay: TimeInterval

    public init(stepDelay: TimeInterval = 0.08) {
        self.stepDelay = stepDelay
    }

    public func openSession() async throws -> TerminalSession {
        let session = TerminalSession(title: "mock-vps", workingDirectory: MockFileSystemProvider.homeRoot)
        sessions.withLock { $0[session.id] = session.workingDirectory }
        return session
    }

    public func closeSession(_ id: UUID) async {
        sessions.withLock { _ = $0.removeValue(forKey: id) }
        running.withLock { $0.removeValue(forKey: id)?.cancel() }
    }

    public func run(_ command: String, in sessionID: UUID) -> AsyncThrowingStream<TerminalOutput, Error> {
        AsyncThrowingStream { continuation in
            guard let cwd = self.sessions.withLock({ $0[sessionID] }) else {
                continuation.finish(throwing: AgentError.providerUnavailable(detail: "Terminal session closed."))
                return
            }
            let script = MockShell.script(for: command, cwd: cwd)
            let delay = self.stepDelay
            let task = Task {
                do {
                    for step in script.steps {
                        let pause = step.delay * (delay / 0.08)
                        if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
                        continuation.yield(step.output)
                    }
                    if let newDirectory = script.newWorkingDirectory {
                        self.sessions.withLock { $0[sessionID] = newDirectory }
                    }
                    continuation.yield(.exit(code: script.exitCode))
                    continuation.finish()
                } catch {
                    continuation.yield(.stderr("^C\n"))
                    continuation.yield(.exit(code: 130))
                    continuation.finish()
                }
                _ = self.running.withLock { $0.removeValue(forKey: sessionID) }
            }
            self.running.withLock { $0[sessionID] = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(sessionID: UUID) async {
        running.withLock { $0[sessionID]?.cancel() }
    }

    public func workingDirectory(of sessionID: UUID) -> String? {
        sessions.withLock { $0[sessionID] }
    }
}

/// Scripted command interpreter shared by the mock terminal and the mock
/// agent's tool calls.
public enum MockShell {
    public struct Step: Sendable {
        public var delay: TimeInterval
        public var output: TerminalOutput
    }

    public struct Script: Sendable {
        public var steps: [Step]
        public var exitCode: Int
        public var newWorkingDirectory: String?
    }

    public static let banner = "Brainbox mock shell — commands are simulated, nothing runs on a real server.\nType `help` to see what works.\n"

    public static func script(for rawCommand: String, cwd: String) -> Script {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = command.split(separator: " ").map(String.init)
        guard let program = parts.first else { return Script(steps: [], exitCode: 0) }
        let args = Array(parts.dropFirst())

        func out(_ text: String, after delay: TimeInterval = 0.05) -> Step { Step(delay: delay, output: .stdout(text)) }
        func err(_ text: String) -> Step { Step(delay: 0.05, output: .stderr(text)) }

        switch program {
        case "help":
            return Script(steps: [out("""
            Available mock commands:
              ls, pwd, cd <dir>, whoami, hostname, uname -a, uptime, date
              df -h, free -h, echo <text>, systemctl status <service>
              ping <host>   (streams until cancelled, or 5 packets)
              sleep <sec>   (cancellable long-running command)

            """)], exitCode: 0)
        case "pwd":
            return Script(steps: [out(cwd + "\n")], exitCode: 0)
        case "whoami":
            return Script(steps: [out("brainbox\n")], exitCode: 0)
        case "hostname":
            return Script(steps: [out("mock-vps\n")], exitCode: 0)
        case "uname":
            return Script(steps: [out("Linux mock-vps 6.8.0-45-generic #45-Ubuntu SMP x86_64 GNU/Linux\n")], exitCode: 0)
        case "date":
            return Script(steps: [out(WireCoding.formatDate(Date()) + "\n")], exitCode: 0)
        case "uptime":
            return Script(steps: [out(" 04:38:12 up 12 days,  3:41,  1 user,  load average: 0.42, 0.37, 0.31\n")], exitCode: 0)
        case "echo":
            return Script(steps: [out(args.joined(separator: " ") + "\n")], exitCode: 0)
        case "ls":
            let listing: String
            switch FilePath.normalize(cwd) {
            case MockFileSystemProvider.homeRoot: listing = "notes.txt  projects/  scripts/\n"
            case MockFileSystemProvider.configRoot: listing = "agent.json  gateway.yaml  settings.jsonc\n"
            default: listing = "\n"
            }
            return Script(steps: [out(listing)], exitCode: 0)
        case "cd":
            let target = args.first ?? MockFileSystemProvider.homeRoot
            let resolved = target.hasPrefix("/") ? FilePath.normalize(target) : FilePath.normalize(FilePath.join(cwd, target))
            let allowed = [MockFileSystemProvider.homeRoot, MockFileSystemProvider.configRoot, MockFileSystemProvider.logRoot]
            guard allowed.contains(where: { FilePath.isPath(resolved, inside: $0) }) else {
                return Script(steps: [err("cd: \(target): Permission denied\n")], exitCode: 1)
            }
            return Script(steps: [], exitCode: 0, newWorkingDirectory: resolved)
        case "df":
            return Script(steps: [out("""
            Filesystem      Size  Used Avail Use% Mounted on
            /dev/vda1        80G   35G   45G  44% /
            tmpfs           2.0G     0  2.0G   0% /dev/shm

            """)], exitCode: 0)
        case "free":
            return Script(steps: [out("""
                           total        used        free      shared  buff/cache   available
            Mem:           7.8Gi       4.5Gi       1.1Gi        12Mi       2.2Gi       3.0Gi
            Swap:          2.0Gi       128Mi       1.9Gi

            """)], exitCode: 0)
        case "systemctl":
            guard args.first == "status", let service = args.dropFirst().first else {
                return Script(steps: [err("Mock shell only supports `systemctl status <service>`. Use the Services screen to start/stop.\n")], exitCode: 1)
            }
            return Script(steps: [
                out("● \(service).service - \(service) (mock)\n", after: 0.1),
                out("     Loaded: loaded (/etc/systemd/system/\(service).service; enabled)\n", after: 0.08),
                out("     Active: active (running) since Mon 2026-09-28 01:12:04 UTC; 1 week 3 days ago\n", after: 0.08),
                out("   Main PID: 1342 (\(service))\n", after: 0.05),
                out("     Memory: 84.2M\n", after: 0.05),
                out("        CPU: 12min 8.113s\n", after: 0.05)
            ], exitCode: 0)
        case "ping":
            let host = args.last ?? "1.1.1.1"
            var steps = [out("PING \(host) 56(84) bytes of data.\n", after: 0.1)]
            for seq in 1...5 {
                let ms = String(format: "%.1f", 11.0 + Double(seq % 3) * 1.7)
                steps.append(out("64 bytes from \(host): icmp_seq=\(seq) ttl=57 time=\(ms) ms\n", after: 0.9))
            }
            steps.append(out("--- \(host) ping statistics ---\n5 packets transmitted, 5 received, 0% packet loss\n", after: 0.2))
            return Script(steps: steps, exitCode: 0)
        case "sleep":
            let seconds = Double(args.first ?? "3") ?? 3
            return Script(steps: [Step(delay: min(max(seconds, 0), 60), output: .stdout(""))], exitCode: 0)
        case "clear":
            return Script(steps: [], exitCode: 0)
        case "rm", "reboot", "shutdown", "mkfs", "dd":
            return Script(steps: [err("\(program): refused by the mock shell (destructive commands are never simulated as successful).\n")], exitCode: 1)
        default:
            return Script(steps: [err("\(program): command not found (mock shell — type `help`)\n")], exitCode: 127)
        }
    }

    /// Runs a script to completion and returns the combined output.
    public static func collect(_ script: Script) -> ToolResult {
        var text = ""
        var hadError = false
        for step in script.steps {
            switch step.output {
            case .stdout(let s): text += s
            case .stderr(let s): text += s; hadError = true
            case .exit: break
            }
        }
        return ToolResult(output: text, exitCode: script.exitCode, isError: hadError || script.exitCode != 0)
    }
}
