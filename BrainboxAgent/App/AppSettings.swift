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

    init(defaults: UserDefaults, isTesting: Bool = false) {
        self.defaults = defaults
        providerKind = ProviderKind(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .mock
        backendURL = defaults.string(forKey: Key.backendURL) ?? ""
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        biometricsEnabled = isTesting ? false : (defaults.object(forKey: Key.biometrics) as? Bool ?? true)
        let storedTimeout = defaults.object(forKey: Key.sessionTimeout) as? Double ?? 300
        sessionTimeout = storedTimeout < 0 ? nil : storedTimeout
        hapticsEnabled = defaults.object(forKey: Key.haptics) as? Bool ?? true
        notifyOnTaskComplete = defaults.object(forKey: Key.notifyComplete) as? Bool ?? false
        notifyOnDisconnect = defaults.object(forKey: Key.notifyDisconnect) as? Bool ?? false
        confirmSensitiveActions = defaults.object(forKey: Key.confirmSensitive) as? Bool ?? true
        // Hermes is pending: never boot into it.
        if providerKind == .hermes { providerKind = .mock }
    }

    var policy: SecurityPolicy {
        SecurityPolicy(biometricsEnabled: biometricsEnabled, gracePeriod: 60, sessionTimeout: sessionTimeout)
    }

    var validatedBackendURL: URL? {
        if case .valid(let url) = BackendURLValidator.validate(backendURL) { return url }
        return nil
    }

    func resetAll() {
        for key in [Key.provider, Key.backendURL, Key.appearance, Key.biometrics, Key.sessionTimeout, Key.haptics, Key.notifyComplete, Key.notifyDisconnect, Key.confirmSensitive, Key.onboarded] {
            defaults.removeObject(forKey: key)
        }
    }
}
