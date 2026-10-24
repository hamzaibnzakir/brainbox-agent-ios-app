import SwiftUI
import BrainboxCore

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// How the app was launched. UI tests pass `-uitesting` so the app runs
/// against fast mock providers with isolated, throwaway storage.
struct LaunchEnvironment {
    var isUITesting: Bool
    var isUnitTesting: Bool

    static var current: LaunchEnvironment {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        let uiTesting = args.contains("-uitesting")
        #else
        let uiTesting = false
        #endif
        let unitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil && !uiTesting
        return LaunchEnvironment(isUITesting: uiTesting, isUnitTesting: unitTesting)
    }

    var usesEphemeralStorage: Bool { isUITesting || isUnitTesting }
}

/// Non-sensitive preferences only. Tokens and other secrets live in the
/// Keychain (`CredentialStore`), never in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let provider = "bb.provider"
        static let backendURL = "bb.backendURL"
        static let appearance = "bb.appearance"
        static let biometrics = "bb.biometrics"
        static let sessionTimeout = "bb.sessionTimeout"
        static let haptics = "bb.haptics"
        static let notifyComplete = "bb.notify.complete"
        static let notifyDisconnect = "bb.notify.disconnect"
        static let confirmSensitive = "bb.confirmSensitive"
        static let onboarded = "bb.onboarded"
        static let hermesURL = "bb.hermes.url"
        static let launchSeen = "bb.launch.seen"
        static let lastTeammate = "bb.teammate.active"
    }

    private let defaults: UserDefaults

    var providerKind: ProviderKind { didSet { defaults.set(providerKind.rawValue, forKey: Key.provider) } }
    var backendURL: String { didSet { defaults.set(backendURL, forKey: Key.backendURL) } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    var biometricsEnabled: Bool { didSet { defaults.set(biometricsEnabled, forKey: Key.biometrics) } }
    /// nil = never lock automatically.
    var sessionTimeout: TimeInterval? { didSet { defaults.set(sessionTimeout ?? -1, forKey: Key.sessionTimeout) } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) } }
    var notifyOnTaskComplete: Bool { didSet { defaults.set(notifyOnTaskComplete, forKey: Key.notifyComplete) } }
    var notifyOnDisconnect: Bool { didSet { defaults.set(notifyOnDisconnect, forKey: Key.notifyDisconnect) } }
    /// Ask "are you sure?" before destructive actions (in addition to Face ID).
    var confirmSensitiveActions: Bool { didSet { defaults.set(confirmSensitiveActions, forKey: Key.confirmSensitive) } }
    /// Hermes API base URL (Brainbox proxy, e.g. https://vps.tailnet.ts.net:8444/hermes).
    var hermesURL: String { didSet { defaults.set(hermesURL, forKey: Key.hermesURL) } }
    /// The full launch sequence plays once; later launches get a short fade.
    var hasSeenLaunch: Bool { didSet { defaults.set(hasSeenLaunch, forKey: Key.launchSeen) } }
    var lastTeammateID: String { didSet { defaults.set(lastTeammateID, forKey: Key.lastTeammate) } }

    init(defaults: UserDefaults, isTesting: Bool = false) {
        self.defaults = defaults
        providerKind = ProviderKind(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .mock
        backendURL = defaults.string(forKey: Key.backendURL) ?? ""
        // New installs follow the system appearance (light and dark are both designed).
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        #if DEBUG
        // UI tests can force one: `-ui-appearance light|dark`.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-ui-appearance"), index + 1 < args.count, let forced = AppearanceMode(rawValue: args[index + 1]) {
            appearance = forced
        }
        #endif
        biometricsEnabled = isTesting ? false : (defaults.object(forKey: Key.biometrics) as? Bool ?? true)
        let storedTimeout = defaults.object(forKey: Key.sessionTimeout) as? Double ?? 300
        sessionTimeout = storedTimeout < 0 ? nil : storedTimeout
        hapticsEnabled = defaults.object(forKey: Key.haptics) as? Bool ?? true
        notifyOnTaskComplete = defaults.object(forKey: Key.notifyComplete) as? Bool ?? false
        notifyOnDisconnect = defaults.object(forKey: Key.notifyDisconnect) as? Bool ?? false
        confirmSensitiveActions = defaults.object(forKey: Key.confirmSensitive) as? Bool ?? true
        hermesURL = defaults.string(forKey: Key.hermesURL) ?? ""
        hasSeenLaunch = isTesting ? true : defaults.bool(forKey: Key.launchSeen)
        lastTeammateID = defaults.string(forKey: Key.lastTeammate) ?? ""
    }

    var policy: SecurityPolicy {
        SecurityPolicy(biometricsEnabled: biometricsEnabled, gracePeriod: 60, sessionTimeout: sessionTimeout)
    }

    var validatedBackendURL: URL? {
        if case .valid(let url) = BackendURLValidator.validate(backendURL) { return url }
        return nil
    }

    var validatedHermesURL: URL? {
        if case .valid(let url) = HermesURLValidator.validate(hermesURL) { return url }
        return nil
    }

    func resetAll() {
        for key in [Key.provider, Key.backendURL, Key.appearance, Key.biometrics, Key.sessionTimeout, Key.haptics, Key.notifyComplete, Key.notifyDisconnect, Key.confirmSensitive, Key.onboarded, Key.hermesURL, Key.launchSeen, Key.lastTeammate] {
            defaults.removeObject(forKey: key)
        }
    }
}
