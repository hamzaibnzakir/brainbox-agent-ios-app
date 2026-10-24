import SwiftUI
import UIKit
import UserNotifications
import BrainboxCore

/// Remote (APNs) notifications. Works only when ALL of these are true, and the
/// Notifications screen says exactly which one is missing:
/// 1. the app was signed with the Push capability (paid Apple Developer account —
///    free/sideloaded builds can't register: iOS reports a missing aps-environment);
/// 2. the user allowed notifications;
/// 3. the Brainbox proxy has push configured (APNs key on the server).
@MainActor
@Observable
final class PushManager {
    enum Readiness: Equatable {
        case off
        case checking
        case permissionDenied
        case buildCannotPush(String)
        case serverNotConfigured([String])
        case notConnected
        case ready
    }

    private(set) var wantsPush: Bool
    private(set) var permission: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    private(set) var registrationError: String?
    private(set) var serverStatus: BrainboxPushStatus?
    private(set) var serverError: String?
    private(set) var preferences: [PushEventKind: Bool]
    private(set) var lastTestResult: String?
    private(set) var busy = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private var client: HermesAPIClient?
    @ObservationIgnored private var features: BrainboxFeatures?

    init(defaults: UserDefaults, enabled: Bool) {
        self.defaults = defaults
        self.enabled = enabled
        wantsPush = defaults.bool(forKey: "bb.push.wanted")
        var prefs: [PushEventKind: Bool] = [:]
        for kind in PushEventKind.allCases {
            prefs[kind] = defaults.object(forKey: "bb.push.pref.\(kind.rawValue)") as? Bool ?? true
        }
        preferences = prefs
    }

    /// APNs environment matching how the app was signed: debug builds use the
    /// sandbox; release, ad-hoc and TestFlight builds use production.
    var environment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    var readiness: Readiness {
        guard wantsPush else { return .off }
        if permission == .denied { return .permissionDenied }
        if let registrationError { return .buildCannotPush(registrationError) }
        guard client != nil else { return .notConnected }
        if let status = serverStatus, !status.ready { return .serverNotConfigured(status.problems) }
        if features?.push.ready == false && serverStatus == nil { return .serverNotConfigured([]) }
        guard deviceToken != nil, serverStatus?.ready == true, serverStatus?.registeredTokens ?? 0 > 0 else { return .checking }
        return .ready
    }

    // MARK: Lifecycle

    func serverChanged(client: HermesAPIClient?, features: BrainboxFeatures?) async {
        self.client = client
        self.features = features
        await refreshPermission()
        guard enabled, client != nil else { return }
        await refreshServerStatus()
        if wantsPush, permission == .authorized || permission == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func refreshServerStatus() async {
        guard let client else { return }
        do {
            serverStatus = try await client.pushStatus()
            serverError = nil
        } catch {
            serverStatus = nil
            serverError = error.asAgentError.message
        }
    }

    func setWantsPush(_ value: Bool) async {
        wantsPush = value
        defaults.set(value, forKey: "bb.push.wanted")
        lastTestResult = nil
        guard enabled else { return }
        if value {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshPermission()
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        } else {
            UIApplication.shared.unregisterForRemoteNotifications()
            deviceToken = nil
            if let client { try? await client.unregisterPush() }
            await refreshServerStatus()
        }
    }

    func setPreference(_ kind: PushEventKind, _ value: Bool) async {
        preferences[kind] = value
        defaults.set(value, forKey: "bb.push.pref.\(kind.rawValue)")
        await registerWithServer()
    }

    // MARK: APNs callbacks (from the app delegate)

    func didRegister(deviceToken data: Data) {
        registrationError = nil
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await registerWithServer() }
    }

    func didFailToRegister(_ error: Error) {
        let text = error.localizedDescription
        // Free / sideloaded provisioning has no Push capability.
        registrationError = text.contains("aps-environment")
            ? "This build isn't signed with the Push capability. Push needs a paid Apple Developer account and a build with BRAINBOX_PUSH=1."
            : "iOS couldn't register for notifications: \(text)"
    }

    private func registerWithServer() async {
        guard wantsPush, let client, let deviceToken else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.registerPush(token: deviceToken, environment: environment,
                                          preferences: Dictionary(uniqueKeysWithValues: preferences.map { ($0.key.rawValue, $0.value) }))
            serverError = nil
        } catch {
            serverError = error.asAgentError.message
        }
        await refreshServerStatus()
    }

    func sendTest() async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            let sent = try await client.sendTestPush()
            lastTestResult = sent > 0 ? "Apple accepted the test notification. It should arrive in a moment."
                                      : "The server sent nothing: no registered device for this phone."
        } catch {
            lastTestResult = "Not sent. " + error.asAgentError.message
        }
    }
}

/// UIKit hooks SwiftUI doesn't expose: APNs registration and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in self.model?.push.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in self.model?.push.didFailToRegister(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let bb = info["bb"] as? [String: Any], let link = bb["link"] as? String, let url = URL(string: link) else { return }
        await MainActor.run { self.model?.open(url) }
    }
}
