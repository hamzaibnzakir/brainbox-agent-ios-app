import Foundation
import HermesKit
import Security

/// Keychain items, device-only (never synced or backed up).
enum Keychain {
    static let service = "app.brainbox.agent.ssh"

    static func set(_ data: Data, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The server the phone connects to.
struct ServerProfile: Codable, Hashable {
    var name: String
    /// SSH address (in Tailscale mode, the server's Tailscale address — also used for the terminal).
    var target: SSHTarget
    /// Talk to Hermes straight over Tailscale (the Brainbox service on the server) instead of SSH.
    var tailscale = false
    /// The tailnet port `tailscale serve` forwards to Hermes.
    var hermesPort = 8766

    init(name: String, target: SSHTarget, tailscale: Bool = false, hermesPort: Int = 8766) {
        self.name = name
        self.target = target
        self.tailscale = tailscale
        self.hermesPort = hermesPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        target = try c.decode(SSHTarget.self, forKey: .target)
        tailscale = try c.decodeIfPresent(Bool.self, forKey: .tailscale) ?? false
        hermesPort = try c.decodeIfPresent(Int.self, forKey: .hermesPort) ?? 8766
    }
}

/// Persists the phone's SSH key, pinned host keys and the backend it started.
final class AppStore: EnginePersistence, HostKeyStore, @unchecked Sendable {
    static let shared = AppStore()
    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    // MARK: Identity

    /// The phone's Ed25519 key, created on first use.
    func identity() -> SSHIdentity {
        lock.lock(); defer { lock.unlock() }
        if let raw = Keychain.get("identity"), let id = try? SSHIdentity(rawRepresentation: raw) { return id }
        let fresh = SSHIdentity.generate()
        Keychain.set(fresh.rawRepresentation, for: "identity")
        return fresh
    }

    /// Replaces the key (the old public key stops working on the server).
    func regenerateIdentity() -> SSHIdentity {
        let fresh = SSHIdentity.generate()
        Keychain.set(fresh.rawRepresentation, for: "identity")
        return fresh
    }

    var ownershipID: String {
        if let id = defaults.string(forKey: "ownershipID"), id.count == 32 { return id }
        let id = RemoteBackend.makeOwnershipID()
        defaults.set(id, forKey: "ownershipID")
        return id
    }

    // MARK: Server

    var profile: ServerProfile? {
        get { defaults.data(forKey: "server").flatMap { try? JSONDecoder().decode(ServerProfile.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "server") }
    }

    /// Hermes' access token for Tailscale mode (from the server's /etc/brainbox/token).
    var hermesToken: String? {
        get { Keychain.get("hermes-token").map { String(decoding: $0, as: UTF8.self) } }
        set {
            if let newValue, !newValue.isEmpty { Keychain.set(Data(newValue.utf8), for: "hermes-token") }
            else { Keychain.delete("hermes-token") }
        }
    }

    // MARK: HostKeyStore

    func pinnedKey(for hostID: String) -> String? {
        Keychain.get("hostkey:" + hostID).map { String(decoding: $0, as: UTF8.self) }
    }

    func pin(_ openSSHKey: String, for hostID: String) {
        Keychain.set(Data(openSSHKey.utf8), for: "hostkey:" + hostID)
    }

    func forgetHostKey(for hostID: String) { Keychain.delete("hostkey:" + hostID) }

    // MARK: EnginePersistence

    func loadBackend(for hostID: String) -> RemoteBackendRecord? {
        Keychain.get("backend:" + hostID).flatMap { try? JSONDecoder().decode(RemoteBackendRecord.self, from: $0) }
    }

    func saveBackend(_ record: RemoteBackendRecord?, for hostID: String) {
        if let record, let data = try? JSONEncoder().encode(record) { Keychain.set(data, for: "backend:" + hostID) }
        else { Keychain.delete("backend:" + hostID) }
    }

    // MARK: Chats the user had open (to check on in the background)

    var watchedChats: [String: String] {
        get { (defaults.dictionary(forKey: "watchedChats") as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: "watchedChats") }
    }

    var lastChat: String? {
        get { defaults.string(forKey: "lastChat") }
        set { defaults.set(newValue, forKey: "lastChat") }
    }
}

/// User preferences (Settings).
struct Preferences: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable { case system, light, dark }
    var theme: Theme = .system
    var textScale: Double = 1
    var showReasoning = true
    var showToolDetails = true
    var haptics = true
    var notifyOnFinish = true
    var notifyOnApproval = true
    var lockWithFaceID = false
    var speakReplies = false
    var autoReconnect = true
    var showPet = true
    /// Start `hermes serve` in Desktop mode (only for servers with dashboard.public_url set).
    var desktopBackend = false
    /// Keep the app (and SSH) running in the background until it's swiped away.
    var stayConnected = true
    /// Run the terminal inside tmux (when the server has it) so it survives disconnects.
    var persistentTerminal = true

    init() {}

    /// Missing keys keep their defaults, so adding a setting never resets the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? d.theme
        textScale = try c.decodeIfPresent(Double.self, forKey: .textScale) ?? d.textScale
        showReasoning = try c.decodeIfPresent(Bool.self, forKey: .showReasoning) ?? d.showReasoning
        showToolDetails = try c.decodeIfPresent(Bool.self, forKey: .showToolDetails) ?? d.showToolDetails
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        notifyOnFinish = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? d.notifyOnFinish
        notifyOnApproval = try c.decodeIfPresent(Bool.self, forKey: .notifyOnApproval) ?? d.notifyOnApproval
        persistentTerminal = try c.decodeIfPresent(Bool.self, forKey: .persistentTerminal) ?? d.persistentTerminal
        lockWithFaceID = try c.decodeIfPresent(Bool.self, forKey: .lockWithFaceID) ?? d.lockWithFaceID
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? d.speakReplies
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        showPet = try c.decodeIfPresent(Bool.self, forKey: .showPet) ?? d.showPet
        desktopBackend = try c.decodeIfPresent(Bool.self, forKey: .desktopBackend) ?? d.desktopBackend
        stayConnected = try c.decodeIfPresent(Bool.self, forKey: .stayConnected) ?? d.stayConnected
    }

    static var current: Preferences {
        get { UserDefaults.standard.data(forKey: "prefs").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "prefs") }
    }
}
