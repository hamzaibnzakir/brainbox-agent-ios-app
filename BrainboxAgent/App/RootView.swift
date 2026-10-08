import SwiftUI
import UIKit
import BrainboxCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardVisible = false

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            HomeView().tabRoot().tag(AppTab.home)
            AgentView().tabRoot().tag(AppTab.agent)
            VPSView().tabRoot().tag(AppTab.vps)
            FilesView().tabRoot().tag(AppTab.files)
            SettingsView().tabRoot().tag(AppTab.settings)
        }
        // The custom bar takes real layout space (not an overlay), so content
        // like the chat composer always sits above it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible {
                BBTabBar(selection: $model.selectedTab, agentBusy: model.agentStatus.isBusy)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let message = model.toasts.message {
                ToastView(text: message)
                    .padding(.top, 8)
                    .transition(.bbDropIn)
                    .zIndex(10)
            }
        }
        .overlay {
            if model.gate.isLocked {
                LockView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    .zIndex(20)
            }
        }
        .overlay {
            // Privacy cover: the app-switcher snapshot never shows chats,
            // terminal output or file contents while protection is on.
            if scenePhase != .active && model.settings.biometricsEnabled && !model.gate.isLocked {
                PrivacyCover().transition(.opacity).zIndex(30)
            }
        }
        .animation(Motion.fade, value: scenePhase)
        .animation(Motion.snappy, value: keyboardVisible)
        .animation(Motion.gentle, value: model.gate.isLocked)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }
}

private struct TabRootModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            // Replays on every tab switch: quick rise + de-blur (anime.js-like page enter).
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .onAppear { withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { shown = true } }
            .onDisappear { shown = false }
    }
}

private extension View {
    func tabRoot() -> some View { modifier(TabRootModifier()) }
}

// MARK: - Tab bar

struct BBTabBar: View {
    static let reservedHeight: CGFloat = 74

    @Binding var selection: AppTab
    var agentBusy: Bool
    @Namespace private var pill
    @State private var bounce: [AppTab: Int] = [:]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    guard tab != selection else { return }
                    withAnimation(Motion.standard) { selection = tab }
                    bounce[tab, default: 0] += 1
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 17, weight: selected ? .semibold : .regular))
                                .symbolEffect(.bounce.down, value: bounce[tab, default: 0])
                            if tab == .agent && agentBusy {
                                StatusDot(tone: .busy, size: 6).offset(x: 6, y: -2)
                            }
                        }
                        Text(tab.title)
                            .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? BB.Palette.onSignal : BB.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(BB.Palette.signal)
                                .shadow(color: BB.Palette.signalGlow, radius: 10, y: 2)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(BB.Palette.surface.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(BB.Palette.strokeStrong))
                .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            BB.Palette.background.opacity(0.85)
            AgentOrb(mode: .offline, size: 72)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Lock screen

struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var attempted = false

    var body: some View {
        ZStack {
            ScreenBackground()
            VStack(spacing: 22) {
                Spacer()
                AgentOrb(mode: .offline, size: 120)
                    .bbEntrance()
                VStack(spacing: 6) {
                    Text("Brainbox is locked").font(BB.Font.title).foregroundStyle(BB.Palette.textPrimary)
                    Text("Unlock with \(model.gate.biometryName) to continue.").font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                }
                .bbEntrance(index: 1)
                if let message = model.gate.lastErrorMessage {
                    Text(message).font(BB.Font.caption).foregroundStyle(BB.Palette.danger).multilineTextAlignment(.center).padding(.horizontal, 32)
                }
                Spacer()
                PrimaryButton(title: "Unlock", systemImage: model.gate.biometrySymbol) {
                    Task { await model.gate.unlock() }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .bbEntrance(index: 2)
            }
        }
        .task {
            guard !attempted else { return }
            attempted = true
            await model.gate.unlock()
        }
    }
}
