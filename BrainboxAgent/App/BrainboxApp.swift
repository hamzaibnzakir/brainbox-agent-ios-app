import HermesKit
import SwiftUI
import UIKit

@main
struct BrainboxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.chatTextScale, CGFloat(model.preferences.textScale))
                .preferredColorScheme(model.preferences.theme == .system ? nil : model.preferences.theme == .dark ? .dark : .light)
                .tint(DS.C.volt)
                .onAppear {
                    AppDelegate.model = model
                    Notifier.shared.model = model
                    model.start()
                }
                .onOpenURL { url in Task { await model.handle(url: url) } }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        BackgroundKeeper.shared.enterForeground()
                        Task { await model.resumeFromBackground() }
                    case .background:
                        BackgroundRefresh.schedule()
                        BackgroundKeeper.shared.enterBackground(keepAlive: model.preferences.stayConnected && model.profile != nil)
                    default: break
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Notifier.shared.setUp()
        BackgroundRefresh.register { AppDelegate.model }
        return true
    }
}

extension AppModel {
    /// brainbox://ask?text=…, brainbox://new, brainbox://chat/<id>, brainbox://screen, or a shared file.
    func handle(url: URL) async {
        if url.isFileURL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                let isImage = ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext)
                sharedAttachments.append(Attachment(filename: url.lastPathComponent, data: data, isImage: isImage))
                selectedTab = .chat
                toast = "Attached \(url.lastPathComponent). Add a message and send."
            }
            return
        }
        guard url.scheme == "brainbox" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "new":
            await newChat()
        case "ask":
            if let text = items.first(where: { $0.name == "text" })?.value, !text.isEmpty {
                if !isConnected { await connect() }
                await newChat()
                await send(text)
            }
        case "chat":
            let id = url.lastPathComponent
            if !id.isEmpty, id != "/" { await open(chatID: id) }
        case "voice":
            selectedTab = .chat
            voiceRequested = true
        case "screen":
            if !isConnected { await connect() }
            showScreen = true
        default:
            break
        }
    }
}
