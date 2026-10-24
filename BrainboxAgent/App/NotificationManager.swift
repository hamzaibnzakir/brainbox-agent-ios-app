import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import BrainboxCore

/// Notifications for Brainbox, using local notifications only (UserNotifications).
///
/// Works with a free Apple developer account: no APNs, no server push. The app
/// posts each alert itself when it notices the event:
/// * live, while it's open or finishing work in the background (run streams,
///   approvals, parallel agents);
/// * by polling scheduled jobs every minute while it's open;
/// * during iOS background refresh (`BGAppRefreshTask`), which iOS runs when it
///   chooses — often every few hours, never guaranteed, and not at all after the
///   app was force-quit or with Background App Refresh turned off.
/// So alerts are reliable while Brainbox is running and best-effort when it isn't.
@MainActor
@Observable
final class NotificationManager {
    static let refreshTaskID = "app.brainbox.agent.refresh"

    private(set) var permission: UNAuthorizationStatus = .notDetermined
    private(set) var preferences: [LocalAlertKind: Bool]
    private(set) var lastBackgroundCheck: Date?
    private(set) var lastTestResult: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private var ledger: AlertLedger
    @ObservationIgnored private(set) var jobDetector: JobAlertDetector
    /// Whether the app is in the foreground (a finished reply you're looking at needs no alert).
    @ObservationIgnored var isAppActive: () -> Bool = { UIApplication.shared.applicationState == .active }

    init(defaults: UserDefaults, enabled: Bool) {
        self.defaults = defaults
        self.enabled = enabled
        var prefs: [LocalAlertKind: Bool] = [:]
        for kind in LocalAlertKind.allCases {
            prefs[kind] = defaults.object(forKey: "bb.alert.\(kind.rawValue)") as? Bool ?? true
        }
        preferences = prefs
        ledger = (defaults.data(forKey: "bb.alert.ledger")).flatMap { try? JSONDecoder().decode(AlertLedger.self, from: $0) } ?? AlertLedger()
        jobDetector = (defaults.data(forKey: "bb.alert.jobs")).flatMap { try? JSONDecoder().decode(JobAlertDetector.self, from: $0) } ?? JobAlertDetector()
        lastBackgroundCheck = defaults.object(forKey: "bb.alert.lastBackground") as? Date
    }

    var isAllowed: Bool { permission == .authorized || permission == .provisional || permission == .ephemeral }

    // MARK: Permission & preferences

    func refreshPermission() async {
        guard enabled else { return }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks iOS for permission (only shows the prompt the first time).
    @discardableResult
    func requestPermission() async -> Bool {
        guard enabled else { return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshPermission()
        if granted { scheduleBackgroundRefresh() }
        return granted
    }

    func setPreference(_ kind: LocalAlertKind, _ value: Bool) {
        preferences[kind] = value
        defaults.set(value, forKey: "bb.alert.\(kind.rawValue)")
    }

    // MARK: Posting

    /// Posts a local notification for an event — once per event, if allowed.
    /// Returns whether it was handed to iOS.
    @discardableResult
    func post(_ alert: LocalAlert, evenWhenActive: Bool = false) -> Bool {
        guard enabled, preferences[alert.kind] ?? true else { return false }
        guard ledger.record(alert.dedupeKey) else { return false }
        saveLedger()
        guard isAllowed, evenWhenActive || !isAppActive() || alert.kind == .approvalNeeded else { return false }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.kind.rawValue
        content.userInfo = ["bb": ["link": alert.link, "kind": alert.kind.rawValue]]
        let request = UNNotificationRequest(identifier: alert.dedupeKey, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    /// A local test notification from this phone (says exactly that).
    func sendTest() async {
        if !isAllowed { _ = await requestPermission() }
        guard isAllowed else {
            lastTestResult = "Notifications are off for Brainbox in iOS Settings."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Brainbox test"
        content.body = "Local notifications are working on this iPhone."
        content.sound = .default
        content.userInfo = ["bb": ["link": "brainbox://settings"]]
        // A few seconds out, so it also shows if you leave the app.
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
            lastTestResult = "Scheduled — it appears in about 3 seconds (try going to the Home Screen)."
        } catch {
            lastTestResult = "iOS refused the notification: \(error.localizedDescription)"
        }
    }

    // MARK: Event sources

    /// New outcomes in a scheduled-jobs snapshot (first snapshot only records state).
    func jobsChanged(_ jobs: [HermesJob]) {
        let alerts = jobDetector.alerts(for: jobs)
        defaults.set(try? JSONEncoder().encode(jobDetector), forKey: "bb.alert.jobs")
        for alert in alerts { post(alert) }
    }

    func runChanged(runID: String, title: String, state: HermesRunState) {
        guard let alert = RunAlerts.alert(runID: runID, title: title, state: state) else { return }
        post(alert)
    }

    func parallelTaskChanged(_ task: ParallelTask) {
        guard let alert = RunAlerts.alert(for: task) else { return }
        post(alert)
    }

    // MARK: Background refresh

    /// Registers the background check. Must run before the app finishes launching.
    static func registerBackgroundTask(handler: @escaping @MainActor (BGAppRefreshTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { handler(refresh) }
        }
    }

    /// Asks iOS for the next background check (≥ 15 min; iOS decides the real time).
    func scheduleBackgroundRefresh() {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func noteBackgroundCheck() {
        lastBackgroundCheck = Date()
        defaults.set(lastBackgroundCheck, forKey: "bb.alert.lastBackground")
    }

    private func saveLedger() {
        defaults.set(try? JSONEncoder().encode(ledger), forKey: "bb.alert.ledger")
    }
}

/// UIKit hooks: background-task registration and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerBackgroundTask { [weak self] task in
            guard let model = self?.model else { task.setTaskCompleted(success: false); return }
            model.runBackgroundCheck(task)
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let bb = info["bb"] as? [String: Any], let link = bb["link"] as? String, let url = URL(string: link) else { return }
        await MainActor.run { self.model?.open(url) }
    }
}
