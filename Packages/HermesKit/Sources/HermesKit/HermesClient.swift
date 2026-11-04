import BrainboxCore
import Foundation

/// A live connection to Hermes over SSH: the SSH session, the backend it runs,
/// an HTTP client for Hermes' REST API and the JSON-RPC gateway.
public final class HermesClient: @unchecked Sendable {
    public let ssh: SSHConnection
    public let backend: BackendHandle
    public let http: TunnelHTTPClient
    public let rpc: GatewayRPC
    /// The first event the gateway sends (skin, version info).
    public let ready: GatewayEvent?

    init(ssh: SSHConnection, backend: BackendHandle, http: TunnelHTTPClient, rpc: GatewayRPC, ready: GatewayEvent?) {
        self.ssh = ssh
        self.backend = backend
        self.http = http
        self.rpc = rpc
        self.ready = ready
    }

    public struct Options: Sendable {
        public var target: SSHTarget
        public var identity: SSHIdentity
        public var hostKeys: HostKeyStore
        public var ownershipID: String
        public var knownBackend: RemoteBackendRecord?
        public var desktopMode: Bool

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

    /// SSH in, start or reuse `hermes serve`, open the gateway.
    public static func connect(_ options: Options, progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> HermesClient {
        progress(.ssh)
        let ssh = try await SSHConnection.connect(to: options.target, identity: options.identity, hostKeys: options.hostKeys)
        // Fast path: the backend this phone started is usually still running. Go straight to
        // its gateway with the saved token (the token itself proves it's ours); only if that
        // fails run the full locate / verify / spawn sequence.
        if let known = options.knownBackend {
            progress(.gateway)
            if let client = try? await attach(ssh: ssh, backend: BackendHandle(record: known, reused: true, version: known.version),
                                              readyTimeout: 2) {
                return client
            }
        }
        do {
            let backend = try await RemoteBackend(ssh: ssh, ownershipID: options.ownershipID, desktopMode: options.desktopMode)
                .ensure(known: options.knownBackend) { step in progress(.backend(step.rawValue)) }
            progress(.gateway)
            return try await attach(ssh: ssh, backend: backend)
        } catch {
            ssh.close()
            throw error
        }
    }

    /// Opens HTTP + gateway to an already-running backend on `ssh`.
    public static func attach(ssh: SSHConnection, backend: BackendHandle, readyTimeout: TimeInterval = 3) async throws -> HermesClient {
        let dialer = SSHPortDialer(ssh: ssh, port: backend.record.port)
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
        return HermesClient(ssh: ssh, backend: backend, http: http, rpc: rpc, ready: ready)
    }

    public func close() {
        rpc.close()
        ssh.close()
    }

    /// True when the gateway answers within `timeout` (a suspended or half-open link doesn't).
    public func isAlive(timeout: TimeInterval = 2) async -> Bool {
        guard ssh.isActive, !rpc.closed else { return false }
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
