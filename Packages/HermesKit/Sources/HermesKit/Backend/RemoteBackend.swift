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
///
/// Shared: every Brainbox device (phones, PCs) on the server uses ONE backend, so a chat is
/// live on all of them at once (Hermes' gateway owns execution; clients attach to the same
/// session). It lives in `~/.hermes/desktop-ssh/<sharedOwner>/` with its token in a 0600 file
/// next to the lock, so any device that can SSH in as this user adopts it instead of starting
/// its own. Backends from older builds (one per device, under the device's ownership id) are
/// stopped. Same layout as the Windows app (desktop/src/main/hermes/backend.ts).
public struct RemoteBackendRecord: Codable, Hashable, Sendable {
    public var pid: Int
    public var port: Int
    public var nonce: String
    public var token: String
    public var hermesPath: String
    /// Hermes version seen when this backend was verified (for fast reconnects).
    public var version: String?
    /// Started under the shared directory (older builds kept one backend per device).
    public var shared: Bool?
}

public struct BackendHandle: Sendable {
    public var record: RemoteBackendRecord
    public var reused: Bool
    public var version: String?
    /// Reused a backend another device started.
    public var adopted = false

    public init(record: RemoteBackendRecord, reused: Bool, version: String?, adopted: Bool = false) {
        self.record = record
        self.reused = reused
        self.version = version
        self.adopted = adopted
    }
}

public enum BackendError: Error, LocalizedError, Equatable {
    case hermesNotFound
    case unsupportedHermes(String)
    case spawnFailed(String)
    case notReady(String)
    /// The backend demands a dashboard login (server has `dashboard.public_url` set).
    case gated

    public var errorDescription: String? {
        switch self {
        case .hermesNotFound:
            return "Couldn't find Hermes on the server. Brainbox looks for `hermes` on the login PATH, ~/.local/bin and ~/.hermes/hermes-agent."
        case .unsupportedHermes(let detail):
            return "This Hermes version can't run the Desktop backend over SSH (\(detail)). Update Hermes on the server."
        case .spawnFailed(let log): return "Hermes didn't start: \(log)"
        case .notReady(let log): return "Hermes started but never reported ready. Last log lines:\n\(log)"
        case .gated:
            return "Hermes put its dashboard login in front of the private backend (your config sets dashboard.public_url). Turn on Connection › Desktop-compatible backend and connect again."
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
    /// Start the backend the way Desktop does (`HERMES_DESKTOP=1`). Only needed when the
    /// server sets `dashboard.public_url`, which otherwise puts a web-login gate in front
    /// of the private backend. Desktop mode also runs its own cron ticker (it stands down
    /// for profiles a gateway already serves).
    public var desktopMode = false

    public init(ssh: SSHConnection, ownershipID: String, desktopMode: Bool = false) {
        self.ssh = ssh
        self.ownershipID = ownershipID
        self.desktopMode = desktopMode
    }

    public static func makeOwnershipID() -> String { randomHex(16) }

    static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Single-quotes a value for POSIX sh.
    public static func shq(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Hermes requires 32 hex for the runtime dir: sha256("brainbox-shared-backend")[:32], fixed.
    public static let sharedOwner = "9bfaf1f3f5d1b43167520d9fb4c60c03"

    var runtimeDir: String { "$HOME/.hermes/desktop-ssh/\(Self.sharedOwner)" }
    var lockPath: String { "\(runtimeDir)/brainbox-mobile.lock.json" }
    var tokenPath: String { "\(runtimeDir)/backend.token" }
    var legacyDir: String { "$HOME/.hermes/desktop-ssh/\(ownershipID)" }

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

    /// The shared lock plus its token (lock JSON on the first line, the token on the second).
    func readLock() async throws -> RemoteBackendRecord? {
        let result = try await ssh.exec("tr -d '\\n' < \(lockPath) 2>/dev/null; echo; cat \(tokenPath) 2>/dev/null", timeout: 20)
        let lines = result.output.components(separatedBy: "\n")
        guard let data = lines.first?.data(using: .utf8), !data.isEmpty,
              let lock = try? JSONDecoder().decode(LockFile.self, from: data) else { return nil }
        var record = lock.record(token: lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        record.shared = true
        return record
    }

    /// The backend another device started, when it is alive and its token still opens it.
    public func adopt() async -> BackendHandle? {
        guard let lock = try? await readLock(), lock.token.count == 64,
              lock.token.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              await pidAlive(lock), let version = await verify(lock) else { return nil }
        var record = lock
        record.version = version
        return BackendHandle(record: record, reused: true, version: version, adopted: true)
    }

    /// Stops a backend an older build started for this device alone (only if its argv proves it).
    func retireLegacy(_ record: RemoteBackendRecord?) async {
        guard let record, record.shared != true, await pidAlive(record) else { return }
        _ = try? await ssh.exec("kill \(record.pid) 2>/dev/null; rm -f \(legacyDir)/brainbox-mobile.lock.json; true", timeout: 20)
    }

    /// Serialises starts across devices: two connecting at once must not start two backends.
    func withSpawnLock<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let dir = "\(runtimeDir)/spawn.lock"
        _ = try await ssh.exec("""
        umask 077; mkdir -p "$HOME/.hermes/desktop-ssh" "\(runtimeDir)"; chmod 700 "$HOME/.hermes/desktop-ssh" "\(runtimeDir)"
        for i in $(seq 1 90); do mkdir "\(dir)" 2>/dev/null && { echo GOT; exit 0; }
          find "\(dir)" -maxdepth 0 -mmin +3 -exec rmdir {} \\; 2>/dev/null; sleep 1; done; echo BUSY
        """, timeout: 100)
        do {
            let value = try await body()
            _ = try? await ssh.exec("rmdir \"\(dir)\" 2>/dev/null; true", timeout: 15)
            return value
        } catch {
            _ = try? await ssh.exec("rmdir \"\(dir)\" 2>/dev/null; true", timeout: 15)
            throw error
        }
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
        progress(.reusing)
        if let known, known.shared == true, await pidAlive(known), let version = await verify(known) {
            var record = known
            record.version = version
            return BackendHandle(record: record, reused: true, version: version)
        }
        if let adopted = await adopt() {
            await retireLegacy(known)
            return adopted
        }
        await retireLegacy(known)
        return try await withSpawnLock {
            // Another device may have finished starting one while we waited for the lock.
            if let late = await adopt() { return late }
            progress(.locating)
            let hermes = try await locateHermes()
            progress(.starting)
            return try await spawn(hermesPath: hermes, progress: progress)
        }
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
        child=$("$launcher" sh -c 'ulimit -n 4096 2>/dev/null; exec \(desktopMode ? "env HERMES_DESKTOP=1 " : "")"$0" serve --isolated --host 127.0.0.1 --port 0 --ssh-session-token-file "$1" --ssh-owner-nonce "$2" </dev/null >>"$3" 2>&1 & echo $!' \(Self.shq(hermesPath)) "\(tokenFile)" \(nonce) "\(log)")
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

        let record = RemoteBackendRecord(pid: pid, port: port, nonce: nonce, token: token, hermesPath: hermesPath, version: nil, shared: true)
        let lock = LockFile(record: record)
        if let data = try? JSONEncoder().encode(lock) {
            // Token first, lock last: a device that reads the lock always finds the matching token.
            _ = try? await ssh.exec("umask 077; printf %s \(token) > \(tokenPath).tmp && mv -f \(tokenPath).tmp \(tokenPath) && cat > \(lockPath).tmp && mv -f \(lockPath).tmp \(lockPath)", stdin: data, timeout: 20)
        }
        let version = await verify(record)
        var verified = record
        verified.version = version
        return BackendHandle(record: verified, reused: false, version: version)
    }

    /// Stops the shared Brainbox backend (never anything else); other devices reconnect to a new one.
    public func stop(_ record: RemoteBackendRecord) async {
        if await pidAlive(record) {
            let files = record.shared == true ? "\(lockPath) \(tokenPath)" : "\(legacyDir)/brainbox-mobile.lock.json"
            _ = try? await ssh.exec("kill \(record.pid) 2>/dev/null; rm -f \(files)", timeout: 20)
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
            RemoteBackendRecord(pid: pid, port: port, nonce: nonce, token: token, hermesPath: hermesPath, version: nil, shared: nil)
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
