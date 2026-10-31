import AppIntents
import Foundation

/// "Hey Siri, ask Brainbox" — Siri asks for the question, Brainbox opens and sends it.
struct AskHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Hermes"
    static var description = IntentDescription("Send a message to your Hermes agent.")
    static var openAppWhenRun = true

    @Parameter(title: "Message", requestValueDialog: "What should I ask Hermes?")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult {
        var components = URLComponents()
        components.scheme = "brainbox"
        components.host = "ask"
        components.queryItems = [URLQueryItem(name: "text", value: message)]
        if let url = components.url { await AppDelegate.model?.handle(url: url) }
        return .result()
    }
}

struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Hermes chat"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppDelegate.model?.handle(url: URL(string: "brainbox://new")!)
        return .result()
    }
}

struct TalkToHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Hermes"
    static var description = IntentDescription("Start a hands-free voice conversation with Hermes.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppDelegate.model?.handle(url: URL(string: "brainbox://voice")!)
        return .result()
    }
}

struct BrainboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskHermesIntent(), phrases: ["Ask \(.applicationName)", "Message Hermes in \(.applicationName)"],
                    shortTitle: "Ask Hermes", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: TalkToHermesIntent(), phrases: ["Talk to Hermes in \(.applicationName)", "Start \(.applicationName) voice"],
                    shortTitle: "Talk to Hermes", systemImageName: "waveform")
        AppShortcut(intent: NewChatIntent(), phrases: ["New chat in \(.applicationName)"],
                    shortTitle: "New chat", systemImageName: "square.and.pencil")
    }
}
