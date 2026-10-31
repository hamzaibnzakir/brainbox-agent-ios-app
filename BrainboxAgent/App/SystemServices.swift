import ActivityKit
import BackgroundTasks
import BrainboxCore
import Foundation
import HermesKit
import LocalAuthentication
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Face ID

enum Biometrics {
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}

// MARK: - Local notifications (no push server needed)

/// Local notifications fired by the app itself when a reply lands or Hermes needs
/// you, plus actions to approve or deny a command straight from the banner.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    weak var model: AppModel?

    static let approvalCategory = "BB_APPROVAL"
    static let replyCategory = "BB_REPLY"

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: "approve_once", title: "Approve once", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message Hermes")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.replyCategory, actions: [reply], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    @MainActor private var appIsActive: Bool { UIApplication.shared.applicationState == .active }

    @MainActor
    func turnFinished(chat: String, title: String, text: String) {
        guard !appIsActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text.isEmpty ? "Hermes finished." : String(text.prefix(240))
        content.sound = .default
        content.categoryIdentifier = Self.replyCategory
        content.threadIdentifier = chat
        content.userInfo = ["chat": chat]
        post(content, id: "done-\(chat)")
    }

    @MainActor
    func needsAttention(chat: String, title: String, request: PendingRequest) {
        guard !appIsActive else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.threadIdentifier = chat
        content.userInfo = ["chat": chat, "request": request.requestID]
        switch request.kind {
        case .approval(let command, let description, _):
            content.title = "Approve command?"
            content.body = (description.isEmpty ? "" : description + ": ") + command
            content.categoryIdentifier = Self.approvalCategory
            content.interruptionLevel = .timeSensitive
        case .clarify(let question, _, _):
            content.title = "\(title) has a question"
            content.body = question
        case .clarifyBatch(let questions):
            content.title = "\(title) has questions"
            content.body = questions.first?.question ?? ""
        case .sudo:
            content.title = "Hermes needs the sudo password"
            content.body = "Open Brainbox to answer."
        case .secret(let prompt, _):
            content.title = "Hermes needs a secret"
            content.body = prompt
        }
        post(content, id: "req-\(request.requestID)")
    }

    func notify(title: String, body: String, chat: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let chat { content.userInfo = ["chat": chat] }
        post(content, id: UUID().uuidString)
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let chat = info["chat"] as? String else { return }
        let requestID = info["request"] as? String
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            guard let model = self.model else { return }
            Task { await model.handleNotification(chat: chat, requestID: requestID, action: action, text: typed) }
        }
    }
}

extension AppModel {
    func handleNotification(chat: String, requestID: String?, action: String, text: String?) async {
        if !isConnected { await connect() }
        guard isConnected else { return }
        await open(chatID: chat)
        switch action {
        case "approve_once", "deny":
            guard let requestID else { return }
            let request = transcripts[chat]?.pendingRequests.first { $0.requestID == requestID }
                ?? PendingRequest(requestID: requestID, kind: .approval(command: "", description: "", choices: ["once", "deny"]))
            await respond(request, answer: action == "deny" ? "deny" : "once", chat: chat)
        case "reply":
            if let text, !text.isEmpty { await send(text) }
        default:
            selectedTab = .chat
        }
    }

    /// Runs in a background refresh window: reconnect briefly and notify about
    /// chats that finished while the app was suspended.
    func backgroundCheck() async {
        let watched = store.watchedChats
        guard !watched.isEmpty, profile != nil else { return }
        if !isConnected { await connect() }
        guard isConnected else { return }
        for (chat, title) in watched {
            guard let resumed = try? await engine.call(nil, "session.resume", ["session_id": .string(chat)], timeout: 25) else { continue }
            let running = resumed["running"]?.boolValue == true || resumed["inflight"]?.boolValue == true
            if !running {
                var t = Transcript()
                t.hydrate(messages: resumed["messages"]?.arrayValue ?? [])
                let last = t.items.reversed().compactMap { item -> String? in
                    if case .assistant(let text, _, _) = item.kind { return text }
                    return nil
                }.first ?? ""
                if preferences.notifyOnFinish { notifier.turnFinished(chat: chat, title: title, text: last) }
                store.watchedChats[chat] = nil
            }
        }
    }
}

enum BackgroundRefresh {
    static let identifier = "app.brainbox.agent.refresh"

    static func register(model: @escaping @MainActor () -> AppModel?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                await model()?.backgroundCheck()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - Live Activity

@MainActor
final class LiveActivityBridge {
    static let shared = LiveActivityBridge()
    private var activities: [String: Activity<HermesActivityAttributes>] = [:]
    private var lastStatus: [String: String] = [:]

    func start(chat: String, title: String, prompt: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activities[chat] == nil else { return }
        let attributes = HermesActivityAttributes(chat: chat, title: title)
        let state = HermesActivityAttributes.ContentState(status: "Working", detail: String(prompt.prefix(80)), done: false)
        if let activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil)) {
            activities[chat] = activity
        }
    }

    func update(chat: String, title: String, status: String) {
        guard let activity = activities[chat], lastStatus[chat] != status else { return }
        lastStatus[chat] = status
        let state = HermesActivityAttributes.ContentState(status: status, detail: title, done: false)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end(chat: String, text: String) {
        guard let activity = activities.removeValue(forKey: chat) else { return }
        lastStatus[chat] = nil
        let state = HermesActivityAttributes.ContentState(status: "Done", detail: String(text.prefix(120)), done: true)
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60 * 10))) }
    }
}

// MARK: - Pet sprite (Hermes' petdex companions)

struct PetSprite: Equatable {
    var slug: String
    var name: String
    var revision: String?
    var image: CGImage
    var frameSize: CGSize
    var rows: [String]
    var framesByRow: [String: Int]
    var framesByState: [String: Int]
    var framesPerState: Int
    var loop: Double

    init?(_ json: JSONValue) {
        guard json["enabled"]?.boolValue == true,
              let b64 = json["spritesheetBase64"]?.stringValue,
              let data = Data(base64Encoded: b64),
              let image = UIImage(data: data)?.cgImage else { return nil }
        slug = json["slug"]?.stringValue ?? "pet"
        name = json["displayName"]?.stringValue ?? slug
        revision = json["spritesheetRevision"]?.stringValue
        self.image = image
        frameSize = CGSize(width: json["frameW"]?.doubleValue ?? 192, height: json["frameH"]?.doubleValue ?? 208)
        rows = json["stateRows"]?.arrayValue?.compactMap(\.stringValue) ?? ["idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review"]
        framesByRow = (json["framesByRow"]?.objectValue ?? [:]).compactMapValues(\.intValue)
        framesByState = (json["framesByState"]?.objectValue ?? [:]).compactMapValues(\.intValue)
        framesPerState = json["framesPerState"]?.intValue ?? 6
        loop = (json["loopMs"]?.doubleValue ?? 1100) / 1000
    }

    static func == (a: PetSprite, b: PetSprite) -> Bool { a.slug == b.slug && a.revision == b.revision }

    private static let aliases: [String: [String]] = [
        "run": ["running", "run"], "wave": ["waving", "wave"], "jump": ["jumping", "jump"],
        "idle": ["idle"], "failed": ["failed"], "waiting": ["waiting", "idle"], "review": ["review", "idle"],
    ]

    func row(for state: String) -> (index: Int, frames: Int) {
        for name in Self.aliases[state] ?? [state] {
            if let i = rows.firstIndex(of: name) {
                return (i, framesByRow[name] ?? framesByState[state] ?? framesPerState)
            }
        }
        return (0, framesByRow[rows.first ?? "idle"] ?? framesPerState)
    }

    func frame(state: String, time: TimeInterval) -> CGImage? {
        let (row, count) = row(for: state)
        let n = max(count, 1)
        let index = Int((time.truncatingRemainder(dividingBy: loop)) / loop * Double(n)) % n
        let rect = CGRect(x: CGFloat(index) * frameSize.width, y: CGFloat(row) * frameSize.height,
                          width: frameSize.width, height: frameSize.height)
        return image.cropping(to: rect)
    }
}

struct PetView: View {
    var sprite: PetSprite
    var mood: PetMood
    var size: CGFloat = 64

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
            if let frame = sprite.frame(state: mood.spriteState, time: timeline.date.timeIntervalSinceReferenceDate) {
                Image(decorative: frame, scale: 1).resizable().interpolation(.none).scaledToFit()
            }
        }
        .frame(width: size, height: size * sprite.frameSize.height / max(sprite.frameSize.width, 1))
        .accessibilityLabel("\(sprite.name), \(mood.rawValue)")
    }
}

/// The companion shown in chat: the user's Hermes pet when they have one, else the Brainbox bot.
struct Companion: View {
    @Environment(AppModel.self) private var model
    var mood: PetMood
    var size: CGFloat = 40

    var body: some View {
        if let pet = model.pet, model.preferences.showPet {
            PetView(sprite: pet, mood: mood, size: size)
        } else {
            MascotView(style: .brainbox, mood: mood.mascotMood, size: size)
        }
    }
}

extension PetMood {
    var mascotMood: MascotMood {
        switch self {
        case .idle: return .idle
        case .busy, .reasoning: return .thinking
        case .tool: return .working
        case .waiting: return .waitingApproval
        case .done, .celebrate: return .happy
        case .failed: return .failed
        }
    }
}
