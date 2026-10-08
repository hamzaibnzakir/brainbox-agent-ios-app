import SwiftUI
import UIKit
import BrainboxCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardVisible = false

    @State private var visited: Set<AppTab> = []

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // Custom container instead of TabView: the bar is a real layout
            // sibling (content always ends above it), tabs keep their state,
            // are mounted lazily, and only the visible tab runs live streams.
            ZStack {
                ForEach(AppTab.allCases) { tab in
                    if visited.contains(tab) || tab == model.selectedTab {
                        TabPage(isActive: tab == model.selectedTab) { page(for: tab) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !keyboardVisible {
                BBTabBar(selection: $model.selectedTab, agentBusy: model.agentStatus.isBusy)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(ScreenBackground())
        .onAppear { visited.insert(model.selectedTab) }
        .onChange(of: model.selectedTab) { _, tab in visited.insert(tab) }
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

extension RootView {
    @ViewBuilder
    func page(for tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .agent: AgentView()
        case .vps: VPSView()
        case .files: FilesView()
        case .settings: SettingsView()
        }
    }
}

private struct TabActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while a tab is mounted but not on screen; screens use it to
    /// pause live streams (metrics, logs) they don't need.
    var tabIsActive: Bool {
        get { self[TabActiveKey.self] }
        set { self[TabActiveKey.self] = newValue }
    }
}

/// Shows/hides a tab with the brand page transition: the incoming page
/// rises 10pt and de-blurs while the outgoing one fades (anime.js-style
/// crossfade, done with springs).
private struct TabPage<Content: View>: View {
    let isActive: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .environment(\.tabIsActive, isActive)
            .opacity(isActive ? 1 : 0)
            .offset(y: isActive || reduceMotion ? 0 : 10)
            .blur(radius: isActive || reduceMotion ? 0 : 3)
            .scaleEffect(isActive || reduceMotion ? 1 : 0.99)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
            .animation(isActive ? Motion.adaptive(Motion.standard, reduceMotion: reduceMotion) : Motion.exit, value: isActive)
    }
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
