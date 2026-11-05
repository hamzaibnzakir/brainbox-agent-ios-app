import HermesKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.profile == nil {
                NavigationStack { ConnectView(isOnboarding: true) }
            } else {
                TabView(selection: $model.selectedTab) {
                    NavigationStack { ChatScreen() }
                        .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right.fill") }
                        .tag(AppModel.Tab.chat)
                    NavigationStack { SessionsScreen() }
                        .tabItem { Label("Sessions", systemImage: "clock.arrow.circlepath") }
                        .tag(AppModel.Tab.sessions)
                    NavigationStack { AgentsScreen() }
                        .tabItem { Label("Agents", systemImage: "point.3.connected.trianglepath.dotted") }
                        .tag(AppModel.Tab.agents)
                    NavigationStack { HubScreen() }
                        .tabItem { Label("Hub", systemImage: "square.grid.2x2.fill") }
                        .tag(AppModel.Tab.hub)
                }
            }
        }
        .overlay {
            if model.isReconnecting, model.profile != nil, !AppModel.isDemo {
                ReconnectingScreen().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isReconnecting)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(text: toast)
                    .padding(.top, DS.S.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 3_200_000_000)
                        withAnimation { model.toast = nil }
                    }
                    .onTapGesture { withAnimation { model.toast = nil } }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        .fullScreenCover(isPresented: $model.showScreen) {
            NavigationStack {
                ScreenScreen()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { model.showScreen = false }.foregroundStyle(.white)
                        }
                    }
            }
            .environment(model)
        }
    }
}

struct ToastView: View {
    var text: String
    var body: some View {
        Text(text)
            .font(DS.F.small)
            .foregroundStyle(DS.C.userText)
            .padding(.horizontal, DS.S.m)
            .padding(.vertical, DS.S.s + 4)
            .background(DS.C.userBubble, in: Capsule())
            .shadow(color: DS.C.shadow.opacity(0.18), radius: 16, y: 8)
            .padding(.horizontal, DS.S.m)
    }
}

/// Compact connection status for screen headers.
struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.connection {
        case .connected:
            Pill(text: model.profile?.name ?? "Online", color: DS.C.good, symbol: "lock.fill")
        case .connecting(let step):
            Pill(text: step, color: DS.C.warn, symbol: "arrow.triangle.2.circlepath")
        case .reconnecting:
            Pill(text: "Reconnecting", color: DS.C.warn, symbol: "arrow.triangle.2.circlepath")
        case .failed:
            Pill(text: "Offline", color: DS.C.bad, symbol: "exclamationmark.triangle.fill")
        case .idle:
            Pill(text: "Not connected", color: DS.C.ink3, symbol: "bolt.slash")
        }
    }
}

/// Full-width banner shown when the connection isn't up.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.connection {
        case .connected:
            EmptyView()
        case .connecting(let step):
            banner(symbol: "lock.shield", text: step, busy: true, action: nil)
        case .reconnecting(let attempt, let reason):
            banner(symbol: "arrow.triangle.2.circlepath", text: attempt > 1 ? "\(reason) (try \(attempt))" : reason, busy: true, action: nil)
        case .failed(let message):
            banner(symbol: "exclamationmark.triangle.fill", text: message, busy: false, action: ("Retry", { Task { await model.connect() } }))
        case .idle:
            banner(symbol: "bolt.slash", text: "Not connected to \(model.profile?.name ?? "your server")", busy: false,
                   action: ("Connect", { Task { await model.connect() } }))
        }
    }

    private func banner(symbol: String, text: String, busy: Bool, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: DS.S.s + 4) {
            if busy { ProgressView().controlSize(.small) } else { Image(systemName: symbol).foregroundStyle(DS.C.warn) }
            Text(text).font(DS.F.small).foregroundStyle(DS.C.ink).frame(maxWidth: .infinity, alignment: .leading)
            if let action { Button(action.0, action: action.1).font(DS.F.smallStrong).foregroundStyle(DS.C.volt) }
        }
        .padding(DS.S.m)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.line, lineWidth: 1))
        .padding(.horizontal, DS.S.m)
    }
}


/// Shown while the link to the server is being rebuilt: your chat stays underneath,
/// and anything you send waits for the connection instead of failing.
struct ReconnectingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var since = Date()

    private var step: String {
        switch model.connection {
        case .connecting(let step): return step
        case .reconnecting(let attempt, let reason): return attempt > 1 ? "\(reason) (try \(attempt))" : reason
        default: return "Connecting"
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: DS.S.m) {
                Companion(mood: .busy, size: 72)
                Text("Reconnecting to \(model.profile?.name ?? "your server")").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
                HStack(spacing: DS.S.s) {
                    ProgressView().controlSize(.small)
                    Text(step).font(DS.F.small).foregroundStyle(DS.C.ink2)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date.timeIntervalSince(since) > 12 {
                        Button("Try again now") { Task { await model.engine.reconnectNow(reason: "Reconnecting") } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(DS.S.xl)
            .card()
            .padding(DS.S.l)
        }
        .onAppear { since = Date() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnecting")
    }
}
