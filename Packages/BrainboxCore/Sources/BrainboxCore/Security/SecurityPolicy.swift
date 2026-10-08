import Foundation

/// Actions that require a fresh biometric (Face ID / Touch ID / passcode)
/// confirmation before they run.
public enum SensitiveAction: String, CaseIterable, Sendable, Hashable, Identifiable {
    case openTerminal
    case editConfiguration
    case changeConnection
    case deleteFile
    case controlService
    case changeAgentConfiguration
    case revealToken

    public var id: String { rawValue }

    public var reason: String {
        switch self {
        case .openTerminal: return "Unlock the terminal"
        case .editConfiguration: return "Save changes to a configuration file"
        case .changeConnection: return "Change connection settings"
        case .deleteFile: return "Delete a file on the server"
        case .controlService: return "Start, stop or restart a service"
        case .changeAgentConfiguration: return "Change the agent configuration"
        case .revealToken: return "Show the saved access token"
        }
    }

    /// Destructive actions always re-prompt, even inside the grace period.
    public var alwaysPrompt: Bool {
        switch self {
        case .deleteFile, .controlService, .revealToken: return true
        default: return false
        }
    }
}

/// Decides when biometrics are required. Pure logic, unit tested.
public struct SecurityPolicy: Sendable, Hashable {
    public var biometricsEnabled: Bool
    /// After a successful unlock, non-destructive sensitive actions don't
    /// re-prompt for this long. 0 = always prompt.
    public var gracePeriod: TimeInterval
    /// Lock the whole app after this long in the background. nil = never.
    public var sessionTimeout: TimeInterval?

    public init(biometricsEnabled: Bool = true, gracePeriod: TimeInterval = 60, sessionTimeout: TimeInterval? = 300) {
        self.biometricsEnabled = biometricsEnabled
        self.gracePeriod = gracePeriod
        self.sessionTimeout = sessionTimeout
    }

    public func requiresAuthentication(for action: SensitiveAction, lastAuthenticatedAt: Date?, now: Date = Date()) -> Bool {
        guard biometricsEnabled else { return false }
        if action.alwaysPrompt { return true }
        guard let last = lastAuthenticatedAt, gracePeriod > 0 else { return true }
        return now.timeIntervalSince(last) > gracePeriod
    }

    public func shouldLock(backgroundedAt: Date?, now: Date = Date()) -> Bool {
        guard biometricsEnabled, let timeout = sessionTimeout, let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= timeout
    }

    public static let sessionTimeoutOptions: [(label: String, value: TimeInterval?)] = [
        ("Immediately", 0),
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("Never", nil)
    ]
}

/// Validates a user-entered backend URL before it is saved.
public enum BackendURLValidator {
    public enum Result: Equatable {
        case valid(URL)
        case invalid(String)
    }

    public static func validate(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid("Enter the gateway URL.") }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return .invalid("That doesn't look like a URL.")
        }
        guard scheme == "wss" || scheme == "ws" else {
            return .invalid("Use wss:// (or ws:// only on a private Tailscale address).")
        }
        if scheme == "ws" && !isPrivateHost(host) {
            return .invalid("Plain ws:// is only allowed for Tailscale/private addresses. Use wss:// for anything else.")
        }
        guard url.user == nil, url.password == nil else {
            return .invalid("Don't put credentials in the URL — save the token separately.")
        }
        return .valid(url)
    }

    /// Tailscale CGNAT range (100.64.0.0/10), MagicDNS (*.ts.net),
    /// RFC1918 and loopback.
    public static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".ts.net") || h.hasSuffix(".local") { return true }
        let octets = h.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true
        default: return false
        }
    }
}
