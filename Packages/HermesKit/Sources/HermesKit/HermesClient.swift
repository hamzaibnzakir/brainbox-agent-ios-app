import BrainboxCore
import Foundation

/// A live connection to Hermes: its REST API and JSON-RPC gateway, reached either straight over the
/// tailnet (Tailscale mode) or through an SSH tunnel (SSH mode), plus SSH for the features that run
/// commands on the server (terminal, file transfers, Hermes' browser) — opened on demand.
public final class HermesClient: @unchecked Sendable {
    public let ssh: SSHLink
    public let backend: BackendHandle
    public let http: TunnelHTTPClient
    public let rpc: GatewayRPC
    /// The first event the gateway sends (skin, version info).
    public let ready: GatewayEvent?
    /// How to open another stream to Hermes' port (the screen viewer uses it).
    public let dialer: TunnelDialer
    /// Connected straight over Tailscale (no SSH in the chat path).
    public let isDirect: Bool

    init(ssh: SSHLink, backend: BackendHandle, http: TunnelHTTPClient, rpc: GatewayRPC, ready: GatewayEvent?,
         dialer: TunnelDialer, isDirect: Bool) {
        self.ssh = ssh
        self.backend = backend
        self.http = http
        self.rpc = rpc
        self.ready = ready
        self.dialer = dialer
        self.isDirect = isDirect
    }

    /// Hermes running as a service on the server, reached over Tailscale: `tailscale serve` forwards
    /// `port` on the tailnet to Hermes on the server's 127.0.0.1; `token` is its fixed access token.
    public struct DirectEndpoint: Sendable, Equatable {
        public var host: String
        public var port: Int
        public var token: String
        public init(host: String, port: Int, token: String) {
            self.host = host
            self.port = port
            self.token = token
        }
    }

    public struct Options: Sendable {
        public var target: SSHTarget
        public var identity: SSHIdentity
        public var hostKeys: HostKeyStore
        public var ownershipID: String
        public var knownBackend: RemoteBackendRecord?
        public var desktopMode: Bool
        /// How long the SSH connect + handshake may take. Reconnects use a short one: a link that
        /// doesn't come up in a few seconds is retried instead of waited on.
        public var sshTimeout: TimeInterval = 20
        /// Tailscale mode: talk to Hermes directly at this endpoint (SSH only for the terminal etc.).
        public var direct: DirectEndpoint?

        public init(target: SSHTarget, identity: SSHIdentity, hostKeys: HostKeyStore, ownershipID: String,
                    knownBackend: RemoteBackendRecord? = nil, desktopMode: Bool = false) {
            self.target = target
            self.identity = identity
            self.hostKeys = hostKeys
            self.ownershipID = ownershipID
            self.knownBackend = knownBackend
            self.desktopMode = desktopMode
        }
    }

    public enum Step: Sendable, Equatable {
        case ssh
        case backend(String)
        case gateway
    }

    /// Tailscale mode: straight to Hermes' gateway over the tailnet. SSH mode: SSH in, start or reuse
    /// `hermes serve`, open the gateway through the tunnel.
    public static func connect(_ options: Options, progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> HermesClient {
        if let direct = options.direct {
            progress(.gateway)
            let link = SSHLink(target: options.target, identity: options.identity, hostKeys: options.hostKeys)
            let record = RemoteBackendRecord(pid: 0, port: direct.port, nonce: "", token: direct.token,
                                             hermesPath: "brainbox-hermes.service", version: nil, shared: true)
            let dialer = DirectDialer(host: direct.host, port: direct.port, connectTimeout: min(options.sshTimeout, 8))
            do {
                let client = try await attach(link: link, dialer: dialer, backend: BackendHandle(record: record, reused: true, version: nil),
                                              isDirect: true)
                return client
            } catch BackendError.gated {
                throw DirectError.badToken
            }
        }
        progress(.ssh)
        let ssh = try await SSHConnection.connect(to: options.target, identity: options.identity, hostKeys: options.hostKeys,
                                                  timeout: .milliseconds(Int64(options.sshTimeout * 1000)))
        // Fast path: the backend this phone started is usually still running. Go straight to
        // its gateway with the saved token (the token itself proves it's ours); only if that
        // fails run the full locate / verify / spawn sequence.
        // A per-device backend from an older build goes through ensure() so it is retired.
        if let known = options.knownBackend, known.shared == true {
            progress(.gateway)
            if let client = try? await attach(ssh: ssh, options: options, backend: BackendHandle(record: known, reused: true, version: known.version),
                                              readyTimeout: 2) {
                return client
            }
        }
        do {
            let backend = try await RemoteBackend(ssh: ssh, ownershipID: options.ownershipID, desktopMode: options.desktopMode)
                .ensure(known: options.knownBackend) { step in progress(.backend(step.rawValue)) }
            progress(.gateway)
            return try await attach(ssh: ssh, options: options, backend: backend)
        } catch {
            ssh.close()
            throw error
        }
    }

    /// Opens HTTP + gateway to an already-running backend on `ssh`.
    public static func attach(ssh: SSHConnection, options: Options, backend: BackendHandle, readyTimeout: TimeInterval = 3) async throws -> HermesClient {
        // The link reconnects by itself (same key and host-key pins) if the terminal etc. need SSH later.
        let link = SSHLink(target: options.target, identity: options.identity, hostKeys: options.hostKeys, connection: ssh)
        return try await attach(link: link, dialer: SSHPortDialer(ssh: ssh, port: backend.record.port), backend: backend,
                                readyTimeout: readyTimeout, isDirect: false)
    }

    static func attach(link: SSHLink, dialer: TunnelDialer, backend: BackendHandle, readyTimeout: TimeInterval = 3,
                       isDirect: Bool) async throws -> HermesClient {
        var backend = backend
        let http = TunnelHTTPClient(dialer: dialer, defaultHeaders: ["X-Hermes-Session-Token": backend.record.token])
        let token = backend.record.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let socket: TunnelWebSocket
        do {
            socket = try await TunnelWebSocket.connect(dialer: dialer, path: "/api/ws?token=\(token)")
        } catch WebSocketError.handshakeFailed(let status, _) where status == 401 || status == 403 {
            throw BackendError.gated
        }
        let rpc = GatewayRPC(socket: socket)
        // Newer Hermes only sends approvals/questions to clients that say they answer them.
        async let capabilities: JSONValue? = try? await rpc.call("client.capabilities", ["server_requests": true], timeout: 10)
        let ready = await rpc.waitForReady(timeout: readyTimeout)
        _ = await capabilities
        // A socket that opened but answers nothing isn't a backend we can use.
        do {
            _ = try await rpc.call("ping", [:], timeout: 8)
        } catch let error as RPCError where error == .timedOut || error == .disconnected {
            rpc.close()
            throw error
        } catch {
            // Older backends without `ping` answer "unknown method" — still alive.
        }
        if isDirect, backend.version == nil {
            // The service's version, for the connection screen (SSH mode learns it while verifying).
            if let health = try? await http.send("GET", "/api/health", timeout: 8),
               let body = try? JSONDecoder().decode(JSONValue.self, from: health.body) {
                let v = body["version"]?.stringValue
                backend.version = (v == nil || v == "unknown") ? body["displayVersion"]?.stringValue ?? v : v
                backend.record.version = backend.version
            }
        }
        return HermesClient(ssh: link, backend: backend, http: http, rpc: rpc, ready: ready, dialer: dialer, isDirect: isDirect)
    }

    public func close() {
        rpc.close()
        ssh.close()
    }

    /// True when the gateway answers within `timeout` (a suspended or half-open link doesn't).
    public func isAlive(timeout: TimeInterval = 2) async -> Bool {
        guard isDirect || ssh.isActive, !rpc.closed else { return false }
        do {
            _ = try await rpc.call("ping", [:], timeout: timeout)
            return true
        } catch let error as RPCError where error == .timedOut || error == .disconnected {
            return false
        } catch {
            return true
        }
    }

    // MARK: REST helpers

    public func get(_ path: String, timeout: TimeInterval = 60) async throws -> JSONValue {
        try decode(try await http.send("GET", path, timeout: timeout))
    }

    @discardableResult
    public func send(_ method: String, _ path: String, json: JSONValue? = nil, timeout: TimeInterval = 60) async throws -> JSONValue {
        let body = try json.map { try JSONEncoder().encode($0) }
        let headers = body == nil ? [:] : ["Content-Type": "application/json"]
        return try decode(try await http.send(method, path, headers: headers, body: body, timeout: timeout))
    }

    public func raw(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil,
                    timeout: TimeInterval = 120) async throws -> TunnelResponse {
        let response = try await http.send(method, path, headers: headers, body: body, timeout: timeout)
        guard (200..<300).contains(response.status) else { throw TunnelHTTPError.status(response.status, response.text) }
        return response
    }

    func decode(_ response: TunnelResponse) throws -> JSONValue {
        guard (200..<300).contains(response.status) else { throw TunnelHTTPError.status(response.status, response.text) }
        if response.body.isEmpty { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: response.body)) ?? .string(response.text)
    }

    public static func query(_ items: [String: String]) -> String {
        guard !items.isEmpty else { return "" }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/")
        return "?" + items.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
