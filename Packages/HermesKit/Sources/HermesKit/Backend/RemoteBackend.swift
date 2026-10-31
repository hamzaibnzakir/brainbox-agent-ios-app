import Crypto
import Foundation

/// Starts or reuses `hermes serve` on the server over SSH — the same backend
/// Hermes Desktop runs in SSH mode — and reports where it listens.
///
/// Mirrors Desktop's remote lifecycle (apps/desktop/electron/remote-lifecycle.ts):
/// * locate Hermes with a login-shell probe plus the installer's known paths;
/// * reuse a backend this phone started earlier when its lockfile pid is alive AND
///   an authenticated `/api/ssh/ownership` call answers with our spawn nonce;
/// * otherwise spawn `serve --isolated --host 127.0.0.1 --port 0` detached
///   (setsid), handing it a one-shot token through a 0600 file under
///   `~/.hermes/desktop-ssh/<ownership-id>/` that Hermes reads and unlinks;
/// * wait for the `HERMES_BACKEND_READY port=N` line.
///
/// Unlike Desktop it does NOT set `HERMES_DESKTOP=1`: on a server that already runs
/// the Hermes gateway (Telegram, cron), Desktop mode would start its own cron ticker
/// (jobs firing twice) and reap "unsupervised" gateway processes. Plain `serve`
/// leaves the existing gateway and scheduled jobs alone.
///
/// The backend binds loopback only; the phone reaches it through SSH
/// direct-tcpip channels, never over the open internet.
public struct RemoteBackendRecord: Codable, Hashable, Sendable {
    public var pid: Int
    public var port: Int
    public var nonce: String
    public var token: String
    public var hermesPath: String
}

public struct BackendHandle: Sendable {
    public var record: RemoteBackendRecord
    public var reused: Bool
    public var version: String?
}

public enum BackendError: Error, LocalizedError, Equatable {
    case hermesNotFound
    case unsupportedHermes(String)
    case spawnFailed(String)
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .hermesNotFound:
            return "Couldn't find Hermes on the server. Brainbox looks for `hermes` on the login PATH, ~/.local/bin and ~/.hermes/hermes-agent."
        case .unsupportedHermes(let detail):
            return "This Hermes version can't run the Desktop backend over SSH (\(detail)). Update Hermes on the server."
        case .spawnFailed(let log): return "Hermes didn't start: \(log)"
        case .notReady(let log): return "Hermes started but never reported ready. Last log lines:\n\(log)"
        }
    }
}

/// Progress reported while connecting, for the connection screen.
public enum BackendStep: String, Sendable {
    case locating = "Finding Hermes on the server"
    case reusing = "Checking the running backend"
    case starting = "Starting Hermes"
    case waiting = "Waiting for Hermes to be ready"
}

public struct RemoteBackend: Sendable {
    public let ssh: SSHConnection
    /// Stable per-phone id (32 lowercase hex): names this phone's runtime directory.
    public let ownershipID: String
    public var readyTimeout: TimeInterval = 120

    public init(ssh: SSHConnection, ownershipID: String) {
        self.ssh = ssh
        self.ownershipID = ownershipID
    }

    public static func makeOwnershipID() -> String { randomHex(16) }

    static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Single-quotes a value for POSIX sh.
    static func shq(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var runtimeDir: String { "$HOME/.hermes/desktop-ssh/\(ownershipID)" }
    var lockPath: String { "\(runtimeDir)/brainbox-mobile.lock.json" }

    // MARK: Locate

    public func locateHermes() async throws -> String {
        let script = """
        for c in "$(bash -lc 'command -v hermes' 2>/dev/null </dev/null)" "$(sh -lc 'command -v hermes' 2>/dev/null </dev/null)" \
          "$HOME/.local/bin/hermes" "$HOME/.hermes/hermes-agent/venv/bin/hermes" "$HOME/.hermes/hermes-agent/.venv/bin/hermes" \
          /usr/local/bin/hermes /opt/hermes/bin/hermes; do
          if [ -n "$c" ] && [ -x "$c" ]; then echo "HERMES_PATH=$c"; exit 0; fi
        done
        echo HERMES_MISSING
        """
        let result = try await ssh.exec(script, timeout: 30)
        for line in result.output.split(separator: "\n") where line.hasPrefix("HERMES_PATH=") {
            return String(line.dropFirst("HERMES_PATH=".count)).trimmingCharacters(in: .whitespaces)
        }
        throw BackendError.hermesNotFound
    }

    // MARK: Reuse

    func readLock() async throws -> RemoteBackendRecord? {
        let result = try await ssh.exec("cat \(lockPath) 2>/dev/null", timeout: 20)
        guard let data = result.output.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(LockFile.self, from: data).record(token: "")
    }

    func pidAlive(_ record: RemoteBackendRecord) async -> Bool {
        // Ours only when that pid's argv still carries our nonce.
        let check = "tr '\\0' ' ' < /proc/\(record.pid)/cmdline 2>/dev/null | grep -q -- \(Self.shq("--ssh-owner-nonce \(record.nonce)")) && echo ALIVE || (kill -0 \(record.pid) 2>/dev/null && ps -o args= -p \(record.pid) 2>/dev/null | grep -q -- \(Self.shq(record.nonce)) && echo ALIVE) || echo DEAD"
        guard let result = try? await ssh.exec(check, timeout: 20) else { return false }
        return result.output.contains("ALIVE")
    }

    /// Whether `record` is a live backend this phone owns and can authenticate to.
    public func verify(_ record: RemoteBackendRecord) async -> String? {
        let http = TunnelHTTPClient(dialer: SSHPortDialer(ssh: ssh, port: record.port),
                                    defaultHeaders: ["X-Hermes-Session-Token": record.token])
        guard let response = try? await http.send("GET", "/api/ssh/ownership", timeout: 15),
              response.status == 200,
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              json["sshOwnerNonce"] as? String == record.nonce else { return nil }
        for path in ["/api/health", "/api/status"] {
            if let response = try? await http.send("GET", path, timeout: 15),
               let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let version = body["version"] as? String, !version.isEmpty {
                // Source checkouts without tags report "unknown"; their display version says more.
                if version == "unknown", let display = body["displayVersion"] as? String, !display.isEmpty { return display }
                return version
            }
        }
        return "unknown"
    }

    // MARK: Start

    /// Reuses `known` when it is still ours and alive; otherwise starts a fresh backend.
    public func ensure(known: RemoteBackendRecord?, progress: @Sendable (BackendStep) -> Void = { _ in }) async throws -> BackendHandle {
        if let known {
            progress(.reusing)
            if await pidAlive(known), let version = await verify(known) {
                return BackendHandle(record: known, reused: true, version: version)
            }
        }
        progress(.locating)
        let hermes = try await locateHermes()
        progress(.starting)
        return try await spawn(hermesPath: hermes, progress: progress)
    }

    public func spawn(hermesPath: String, progress: @Sendable (BackendStep) -> Void = { _ in }) async throws -> BackendHandle {
        let token = Self.randomHex(32)
        let nonce = Self.randomHex(8)
        let log = "\(runtimeDir)/\(nonce).log"
        let tokenFile = "\(runtimeDir)/\(nonce).token"
        // Stop a previous backend of ours first (only if its argv proves it is ours).
        if let old = try? await readLock(), await pidAlive(old) {
            _ = try? await ssh.exec("kill \(old.pid) 2>/dev/null; sleep 1; kill -0 \(old.pid) 2>/dev/null && kill -9 \(old.pid) 2>/dev/null; true", timeout: 20)
        }
        let script = """
        umask 077
        root="$HOME/.hermes/desktop-ssh"; dir="\(runtimeDir)"
        mkdir -p "$root" "$dir" && chmod 700 "$root" "$dir" || exit 71
        cat > "\(tokenFile)" || exit 72
        chmod 600 "\(tokenFile)"
        find "$dir" -name '*.log' -mtime +3 -delete 2>/dev/null
        : > "\(log)"
        launcher="$(command -v setsid || echo nohup)"
        child=$("$launcher" sh -c 'ulimit -n 4096 2>/dev/null; exec "$0" serve --isolated --host 127.0.0.1 --port 0 --ssh-session-token-file "$1" --ssh-owner-nonce "$2" </dev/null >>"$3" 2>&1 & echo $!' \(Self.shq(hermesPath)) "\(tokenFile)" \(nonce) "\(log)")
        echo "PID=$child"
        """
        let result = try await ssh.exec(script, stdin: Data(token.utf8), timeout: 40)
        guard let pidLine = result.output.split(separator: "\n").first(where: { $0.hasPrefix("PID=") }),
              let pid = Int(pidLine.dropFirst(4).trimmingCharacters(in: .whitespaces)) else {
            throw BackendError.spawnFailed((result.errorOutput + result.output).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        progress(.waiting)
        let deadline = Date().addingTimeInterval(readyTimeout)
        var port: Int?
        var tail = ""
        while Date() < deadline {
            let probe = try await ssh.exec("grep -o 'HERMES_\\(BACKEND\\|DASHBOARD\\)_READY port=[0-9]*' \"\(log)\" | head -n1; kill -0 \(pid) 2>/dev/null && echo RUNNING || { echo EXITED; tail -n 15 \"\(log)\"; }", timeout: 20)
            let out = probe.output
            if let range = out.range(of: "port=") {
                let digits = out[range.upperBound...].prefix { $0.isNumber }
                port = Int(digits)
                if port != nil { break }
            }
            if out.contains("EXITED") {
                tail = out.components(separatedBy: "EXITED").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if tail.contains("ssh-session-token-file") || tail.contains("unrecognized arguments") {
                    throw BackendError.unsupportedHermes(String(tail.suffix(300)))
                }
                throw BackendError.spawnFailed(String(tail.suffix(600)))
            }
            try await Task.sleep(nanoseconds: 750_000_000)
        }
        guard let port else {
            tail = (try? await ssh.exec("tail -n 15 \"\(log)\"", timeout: 15).output) ?? ""
            throw BackendError.notReady(tail)
        }

        let record = RemoteBackendRecord(pid: pid, port: port, nonce: nonce, token: token, hermesPath: hermesPath)
        let lock = LockFile(record: record)
        if let data = try? JSONEncoder().encode(lock) {
            _ = try? await ssh.exec("umask 077; cat > \(lockPath).tmp && mv -f \(lockPath).tmp \(lockPath)", stdin: data, timeout: 20)
        }
        let version = await verify(record)
        return BackendHandle(record: record, reused: false, version: version)
    }

    /// Stops the backend this phone started (never anything else).
    public func stop(_ record: RemoteBackendRecord) async {
        if await pidAlive(record) {
            _ = try? await ssh.exec("kill \(record.pid) 2>/dev/null; rm -f \(lockPath)", timeout: 20)
        }
    }

    /// The lockfile never stores the token itself, only its fingerprint.
    struct LockFile: Codable {
        var schemaVersion = 1
        var owner = "brainbox-mobile"
        var pid: Int
        var port: Int
        var nonce: String
        var tokenFingerprint: String
        var hermesPath: String

        init(record: RemoteBackendRecord) {
            pid = record.pid
            port = record.port
            nonce = record.nonce
            hermesPath = record.hermesPath
            tokenFingerprint = Data(SHA256.hash(data: Data(record.token.utf8))).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
        }

        func record(token: String) -> RemoteBackendRecord {
            RemoteBackendRecord(pid: pid, port: port, nonce: nonce, token: token, hermesPath: hermesPath)
        }
    }
}

/// Dials the backend's loopback port through SSH, one channel per stream.
public struct SSHPortDialer: TunnelDialer {
    public let ssh: SSHConnection
    public let port: Int

    public init(ssh: SSHConnection, port: Int) {
        self.ssh = ssh
        self.port = port
    }

    public func dial() async throws -> ByteDuplex {
        try await ssh.openDirectTCPIP(host: "127.0.0.1", port: port)
    }
}
