import BrainboxCore
import Foundation

// Hermes "Bot Screen": each profile's own Linux desktop (Xvnc + Xfce) on the server, with the
// bot's headed browser on it. Anyone connected can watch; one human at a time can take control
// (the "lease"), during which Hermes refuses the bot's browser and computer-use tools. Handing
// back lets the bot continue with whatever the human signed in to.
//
// Wire contract (hermes-agent `tui_gateway/contracts/display.py`, `hermes_cli/web_routers/display.py`):
// * `display.status | start | stop | thumbnail` on the JSON-RPC gateway.
// * `display.observe` mints a single-use, 30 s ticket and a viewer id bound to THIS gateway
//   connection; `/api/display/ws?display_ticket=…` then carries raw RFB as binary frames.
// * `display.lease.acquire / release {viewer_id}` take over and hand back. Events
//   `display.status` and `display.lease` tell every client when either changes.
// * The bridge closes a viewer whose control another human took with 4000, a vanished screen
//   with 4001 and a spent/invalid ticket with 4401. A CLEAN close (1000/1001) from the holder
//   hands control back; a dropped link keeps it (the human may be mid-login).

/// Who drives the screen.
public struct ScreenLease: Equatable, Sendable {
    public enum Holder: String, Sendable { case agent, human }
    public var holder: Holder
    /// Lets a viewer recognise itself as the holder (the raw viewer id never leaves Hermes).
    public var viewerHash: String?
    public var since: Date
    public var epoch: Int
    public var reason: String

    public init(holder: Holder = .agent, viewerHash: String? = nil, since: Date = Date(), epoch: Int = 0, reason: String = "") {
        self.holder = holder
        self.viewerHash = viewerHash
        self.since = since
        self.epoch = epoch
        self.reason = reason
    }

    public init?(json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        holder = Holder(rawValue: json["holder"]?.stringValue ?? "") ?? .agent
        viewerHash = json["viewer_hash"]?.stringValue
        since = Date(timeIntervalSince1970: json["since"]?.doubleValue ?? Date().timeIntervalSince1970)
        epoch = json["epoch"]?.intValue ?? 0
        reason = json["reason"]?.stringValue ?? ""
    }
}

/// A profile's screen: whether it can run, whether it runs, and who holds control.
public struct ScreenStatus: Equatable, Sendable {
    public var profileKey: String
    /// False on hosts that already have a real display (macOS/Windows): no Bot Screen there.
    public var supported: Bool
    public var installed: Bool
    public var missing: [String]
    public var running: Bool
    public var geometry: String
    /// The package-manager line to run on the server when `installed` is false.
    public var installCommand: String?
    /// The headed browser the screen offers, if any.
    public var browser: String?
    /// Why `start` would refuse right now (usually low memory).
    public var blocker: String?
    public var placement: String
    public var lease: ScreenLease

    public init(profileKey: String = "", supported: Bool = true, installed: Bool = true, missing: [String] = [],
                running: Bool = false, geometry: String = "1440x900", installCommand: String? = nil, browser: String? = nil,
                blocker: String? = nil, placement: String = "gateway", lease: ScreenLease = ScreenLease()) {
        self.profileKey = profileKey
        self.supported = supported
        self.installed = installed
        self.missing = missing
        self.running = running
        self.geometry = geometry
        self.installCommand = installCommand
        self.browser = browser
        self.blocker = blocker
        self.placement = placement
        self.lease = lease
    }

    public init(json: JSONValue) {
        profileKey = json["profile_key"]?.stringValue ?? json["profile"]?.stringValue ?? ""
        supported = json["supported"]?.boolValue ?? false
        installed = json["installed"]?.boolValue ?? false
        missing = json["missing"]?.arrayValue?.compactMap(\.stringValue) ?? []
        running = json["running"]?.boolValue ?? false
        geometry = json["geometry"]?.stringValue ?? "1440x900"
        installCommand = json["install_command"]?.stringValue
        browser = json["browser"]?.stringValue
        blocker = json["blocker"]?.stringValue
        placement = json["placement"]?.stringValue ?? "gateway"
        lease = ScreenLease(json: json["lease"]) ?? ScreenLease()
    }

    /// Pixel size from `geometry` ("1440x900").
    public var size: (width: Int, height: Int)? {
        let parts = geometry.lowercased().split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
}

/// What `display.observe` hands back: a ticket for one viewer socket and this connection's viewer id.
public struct ScreenTicket: Sendable {
    public var ticket: String
    public var path: String
    public var viewerID: String
    public var status: ScreenStatus

    /// The WebSocket path with the ticket attached (ticket ids are URL-safe base64).
    public var socketPath: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let encoded = ticket.addingPercentEncoding(withAllowedCharacters: allowed) ?? ticket
        return path + (path.contains("?") ? "&" : "?") + "display_ticket=" + encoded
    }
}

public enum ScreenError: Error, LocalizedError, Equatable {
    /// This Hermes has no Bot Screen (older than the screen feature).
    case unsupportedHermes
    /// The host can't run a screen (it has a real display: macOS/Windows).
    case unsupportedHost
    case notRunning
    /// Another person took control (WebSocket 4000).
    case controlTaken
    /// The screen stopped (WebSocket 4001).
    case screenGone
    /// The ticket was spent or expired (WebSocket 4401).
    case ticketRejected
    /// The viewer id belongs to an earlier connection; observe again.
    case staleViewer
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHermes:
            return "This Hermes doesn't have Bot Screen yet. Update Hermes on the server to use the shared screen."
        case .unsupportedHost:
            return "This server already has a real display, so Hermes doesn't run a Bot Screen on it."
        case .notRunning: return "The screen isn't running. Start it first."
        case .controlTaken: return "Someone else took control of the screen. You're watching now."
        case .screenGone: return "The screen stopped."
        case .ticketRejected: return "Hermes refused the screen ticket. Reconnecting will fetch a new one."
        case .staleViewer: return "This viewer belonged to an earlier connection. Reopen the screen."
        case .failed(let why): return why
        }
    }

    /// Maps the screen bridge's WebSocket close codes.
    public static func fromClose(code: Int, reason: String) -> ScreenError? {
        switch code {
        case 1000, 1001: return nil
        case 4000: return .controlTaken
        case 4001: return .screenGone
        case 4401: return .ticketRejected
        case 4403: return .failed("Hermes refused this screen connection (\(reason.isEmpty ? "not allowed" : reason)).")
        default: return .failed("The screen connection closed (\(code)\(reason.isEmpty ? "" : ": \(reason)")).")
        }
    }

    static func from(_ error: Error) -> Error {
        guard let rpc = error as? RPCError else { return error }
        if rpc.isUnknownMethod { return ScreenError.unsupportedHermes }
        if rpc.data?["code"]?.stringValue == "viewer_mismatch" { return ScreenError.staleViewer }
        if rpc.message.contains("not running") { return ScreenError.notRunning }
        return ScreenError.failed(rpc.message)
    }
}

/// Bot Screen calls on one live connection. Viewer ids are tied to that connection: after a
/// reconnect, observe again for a fresh one.
public struct BotScreen: Sendable {
    public let client: HermesClient
    /// Hermes profile (bot) whose screen this is; nil = the profile `hermes serve` runs.
    public var profile: String?

    public init(client: HermesClient, profile: String? = nil) {
        self.client = client
        self.profile = profile
    }

    private func params(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var p = extra
        if let profile, !profile.isEmpty { p["profile"] = .string(profile) }
        return p
    }

    private func call(_ method: String, _ extra: [String: JSONValue] = [:], timeout: TimeInterval = 30) async throws -> JSONValue {
        do {
            return try await client.rpc.call(method, params(extra), timeout: timeout)
        } catch {
            throw ScreenError.from(error)
        }
    }

    public func status() async throws -> ScreenStatus {
        ScreenStatus(json: try await call("display.status"))
    }

    /// Starts Xvnc + Xfce (idempotent). Blocks until the display is up.
    @discardableResult
    public func start() async throws -> ScreenStatus {
        ScreenStatus(json: try await call("display.start", timeout: 120))
    }

    /// Stops the screen. Hermes refuses while a human holds control unless `force`.
    @discardableResult
    public func stop(force: Bool = false) async throws -> ScreenStatus {
        ScreenStatus(json: try await call("display.stop", force ? ["force": true] : [:], timeout: 60))
    }

    /// One JPEG of the screen as a `data:` URL. Nil while it's stopped or while a human holds
    /// control (Hermes withholds frames that may show someone typing a password).
    public func thumbnail() async throws -> (dataURL: String?, suppressed: String?) {
        let result = try await call("display.thumbnail")
        return (result["data_url"]?.stringValue, result["suppressed"]?.stringValue)
    }

    /// A ticket for one viewer socket. Pass the viewer id this connection got before to keep it.
    public func observe(viewerID: String? = nil) async throws -> ScreenTicket {
        let result = try await call("display.observe", viewerID.map { ["viewer_id": .string($0)] } ?? [:])
        guard let ticket = result["ticket"]?.stringValue, let viewer = result["viewer_id"]?.stringValue else {
            throw ScreenError.failed("Hermes didn't return a screen ticket.")
        }
        return ScreenTicket(ticket: ticket, path: result["path"]?.stringValue ?? "/api/display/ws",
                            viewerID: viewer, status: ScreenStatus(json: result))
    }

    /// Take over: this viewer's keyboard and pointer drive the screen; the bot's screen tools stop.
    @discardableResult
    public func takeOver(viewerID: String, reason: String = "Brainbox (iPhone)") async throws -> ScreenLease {
        let result = try await call("display.lease.acquire", ["viewer_id": .string(viewerID), "reason": .string(reason)])
        return ScreenLease(json: result["lease"]) ?? ScreenLease(holder: .human)
    }

    /// Hand back to the bot. Without a viewer id (after a reconnect) only `force` clears a human's hold.
    @discardableResult
    public func handBack(viewerID: String?, force: Bool = false) async throws -> ScreenLease {
        var extra: [String: JSONValue] = [:]
        if let viewerID { extra["viewer_id"] = .string(viewerID) }
        if force { extra["force"] = true }
        let result = try await call("display.lease.release", extra)
        return ScreenLease(json: result["lease"]) ?? ScreenLease()
    }

    /// Opens the RFB stream for `ticket` through the SSH tunnel. Binary frames are raw RFB.
    public func openStream(_ ticket: ScreenTicket) async throws -> TunnelWebSocket {
        do {
            return try await TunnelWebSocket.connect(dialer: SSHPortDialer(ssh: client.ssh, port: client.backend.record.port),
                                                     path: ticket.socketPath)
        } catch WebSocketError.handshakeFailed(let status, let body) {
            if status == 404 { throw ScreenError.unsupportedHermes }
            throw ScreenError.failed("Couldn't open the screen (\(status)) \(body.prefix(120))")
        }
    }
}

public extension HermesClient {
    /// The Bot Screen of the profile this backend serves.
    var screen: BotScreen { BotScreen(client: self) }
}

/// Screen events from the gateway, decoded.
public enum ScreenEvent: Equatable, Sendable {
    case status(ScreenStatus)
    case lease(profileKey: String, ScreenLease)

    public init?(_ event: GatewayEvent) {
        switch event.type {
        case "display.status":
            self = .status(ScreenStatus(json: event.payload))
        case "display.lease":
            guard let lease = ScreenLease(json: event.payload["lease"]) else { return nil }
            self = .lease(profileKey: event.payload["profile_key"]?.stringValue ?? "", lease)
        default:
            return nil
        }
    }
}

public extension ScreenStatus {
    /// A tool call that drives the screen (`browser_*`, `computer_use`), so the app can offer to watch.
    static func isScreenTool(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("browser") || n.hasPrefix("computer_use") || n == "computer"
    }
}
