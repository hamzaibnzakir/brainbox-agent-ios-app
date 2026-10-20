import SwiftUI
import UIKit
import BrainboxCore

struct AgentView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var showHistory = false
    @State private var isAtBottom = true
    @State private var lastAutoScroll = Date.distantPast
    @State private var reviewing: AgentApproval?
    @State private var hop = 0
    @FocusState private var composerFocused: Bool
    @Namespace private var teammatePill

    private var chat: ChatStore { model.chat }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if model.isHermes && model.hermes.visibleTeammates.count > 1 {
                    teammateStrip
                }
                if let banner = bannerError {
                    ErrorBanner(error: banner, retry: { model.reconnect() })
                        .padding(.horizontal, BB.Space.gutter)
                        .padding(.bottom, 8)
                        .transition(.bbDropIn)
                }
                messages
                Composer(
                    text: $draft,
                    isStreaming: chat.isStreaming,
                    isOnline: model.network.isOnline,
                    focused: $composerFocused,
                    onSend: send,
                    onStop: { chat.stop() },
                    canSteer: chat.canSteer,
                    onSteer: steer,
                    placeholder: model.isHermes ? "Message \(currentTeammate.name)…" : "Message the agent…"
                )
            }
            .animation(Motion.standard, value: bannerError)
            .background(ScreenBackground())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $reviewing) { approval in
                ApprovalSheet(approval: approval, teammate: currentTeammate)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showHistory) {
                ConversationListView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(BB.Palette.backgroundRaised)
            }
        }
    }

    private var bannerError: AgentError? {
        if !model.network.isOnline { return .offline }
        switch model.connectionState {
        case .failed(let error): return error
        default: return nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if model.isHermes {
                MascotView(style: currentTeammate.mascot, mood: currentMood, size: 40, seed: currentTeammate.id, hopTrigger: hop)
            } else {
                AgentOrb(mode: OrbMode(status: model.agentStatus, connection: model.connectionState), size: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.current?.title ?? "New conversation")
                    .font(BB.Font.headline)
                    .foregroundStyle(BB.Palette.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .id(chat.current?.title)
                    .transition(.bbRise)
                HStack(spacing: 6) {
                    StatusDot(tone: model.connectionState.isConnected ? model.agentStatus.tone : model.connectionState.tone, size: 6)
                    Text(statusLine)
                        .font(BB.Font.caption)
                        .foregroundStyle(BB.Palette.textSecondary)
                        .contentTransition(.interpolate)
                    if model.isMock { Badge(text: "Mock") }
                }
            }
            .animation(Motion.standard, value: chat.current?.title)
            Spacer(minLength: 8)
            IconButton(systemImage: "clock.arrow.circlepath", label: "Conversation history") { showHistory = true }
                .accessibilityIdentifier("agent.history")
            IconButton(systemImage: "square.and.pencil", label: "New conversation") {
                withAnimation(Motion.standard) { chat.newConversation() }
                composerFocused = true
            }
            .accessibilityIdentifier("agent.new")
        }
        .padding(.horizontal, BB.Space.gutter)
        .padding(.vertical, 10)
    }

    private var statusLine: String {
        if model.connectionState.isConnected {
            let name = model.isHermes ? currentTeammate.name : model.agentDescriptor.name
            return "\(name) · \(model.agentStatus.label)"
        }
        return model.connectionState.label
    }

    // MARK: Teammates

    private var currentTeammate: Teammate {
        model.hermes.teammate(chat.current?.teammateID) ?? model.hermes.activeTeammate
    }

    private var currentMood: MascotMood {
        MascotMood.derive(status: model.agentStatus, connected: model.connectionState.isConnected,
                          latest: chat.current?.messages.last(where: { $0.role == .assistant }),
                          isActiveTeammate: chat.isStreaming)
    }

    private var teammateStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.hermes.visibleTeammates) { mate in
                    let selected = mate.id == currentTeammate.id
                    Button {
                        guard !selected else { return }
                        model.selectTeammate(mate.id)
                        hop += 1
                        withAnimation(Motion.smooth) {
                            if let existing = chat.conversations(for: mate.id).first { chat.select(existing.id) } else { chat.newConversation() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            MascotView(style: mate.mascot, mood: .idle, size: 22, seed: mate.id)
                            Text(mate.name).font(BB.Font.subhead).lineLimit(1)
                        }
                        .foregroundStyle(selected ? BB.Palette.textPrimary : BB.Palette.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background {
                            if selected {
                                Capsule().fill(BB.Palette.surfaceHigh)
                                    .overlay(Capsule().strokeBorder(BB.Palette.signal.opacity(0.55)))
                                    .matchedGeometryEffect(id: "pill", in: teammatePill)
                            }
                        }
                    }
                    .buttonStyle(.pressable)
                    .disabled(chat.isStreaming)
                    .accessibilityIdentifier("strip.\(mate.name)")
                }
            }
            .padding(.horizontal, BB.Space.gutter)
        }
        .padding(.bottom, 6)
        .sensoryFeedback(.selection, trigger: currentTeammate.id)
        .animation(Motion.smooth, value: currentTeammate.id)
    }

    private func steer() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task {
            do {
                try await chat.steer(text)
                model.toasts.show("Steering sent")
            } catch {
                draft = text
                model.toasts.show(error.asAgentError.title)
            }
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        if let conversation = chat.current, !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    // Plain VStack: stable measured heights while text streams
                    // (no lazy re-estimation jitter under the bottom anchor).
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.messages) { message in
                            MessageRow(
                                message: message,
                                agentName: model.isHermes ? currentTeammate.name : model.agentDescriptor.name,
                                isLatest: message.id == conversation.messages.last?.id,
                                onRetry: { chat.retry(message.id) },
                                onCopy: copy,
                                onReviewApproval: { reviewing = $0 }
                            )
                            .id(message.id)
                            .transition(message.role == .user
                                ? .asymmetric(insertion: .scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity), removal: .opacity)
                                : .bbRise)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(.horizontal, BB.Space.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .animation(Motion.standard, value: conversation.messages.count)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .bottom) {
                    if !isAtBottom {
                        Button {
                            withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(BB.Palette.textPrimary)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.ultraThinMaterial))
                                .overlay(Circle().strokeBorder(BB.Palette.strokeStrong))
                        }
                        .buttonStyle(.pressable)
                        .padding(.bottom, 8)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .accessibilityLabel("Scroll to latest")
                    }
                }
                .animation(Motion.snappy, value: isAtBottom)
                .onChange(of: conversation.messages.count) { _, _ in
                    withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: conversation.messages.last?.content) { _, _ in
                    // Follow the stream, throttled to ~12 fps so token bursts
                    // don't trigger a scroll per token.
                    guard isAtBottom, Date().timeIntervalSince(lastAutoScroll) > 0.08 else { return }
                    lastAutoScroll = Date()
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: chat.isStreaming) { _, streaming in
                    if !streaming { withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: chat.currentID) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .id(conversation.id)
            .transition(.opacity)
        } else {
            EmptyChat(onSuggestion: { prompt in
                draft = ""
                chat.send(prompt)
            })
            .frame(maxHeight: .infinity)
            .transition(.opacity)
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        withAnimation(Motion.standard) { chat.send(text) }
    }

    private func copy(_ text: String) {
        Clipboard.copy(text)
        model.toasts.show("Copied")
    }
}

// MARK: - Empty state

struct EmptyChat: View {
    @Environment(AppModel.self) private var model
    var onSuggestion: (String) -> Void

    private let suggestions: [(String, String)] = [
        ("waveform.path.ecg", "Check server status"),
        ("doc.text.magnifyingglass", "Show the gateway config file"),
        ("shippingbox", "Run a long deploy"),
        ("chevron.left.forwardslash.chevron.right", "Write a python health check script")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: BB.Space.xl) {
                Spacer(minLength: 40)
                AgentOrb(mode: OrbMode(status: model.agentStatus, connection: model.connectionState), size: 110)
                    .bbEntrance(index: 0, distance: 24)
                VStack(spacing: 6) {
                    Text("What should we work on?")
                        .font(BB.Font.title)
                        .foregroundStyle(BB.Palette.textPrimary)
                    Text(model.isMock
                         ? "You're talking to the mock agent. Replies are simulated for development."
                         : "Ask \(model.agentDescriptor.name) to inspect, fix or explain anything on your server.")
                        .font(BB.Font.callout)
                        .foregroundStyle(BB.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .bbEntrance(index: 1)
                VStack(spacing: 10) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                        Button { onSuggestion(item.1) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.0)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(BB.Palette.signalText)
                                    .frame(width: 22)
                                Text(item.1).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(BB.Palette.textTertiary)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
                            .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
                        }
                        .buttonStyle(.pressable)
                        .bbEntrance(index: index + 2)
                        .accessibilityIdentifier("suggestion.\(index)")
                    }
                }
                .padding(.horizontal, BB.Space.gutter)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: - Composer

struct Composer: View {
    @Binding var text: String
    var isStreaming: Bool
    var isOnline: Bool
    var focused: FocusState<Bool>.Binding
    var onSend: () -> Void
    var onStop: () -> Void
    var canSteer: Bool = false
    var onSteer: () -> Void = {}
    var placeholder: String = "Message the agent…"

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isOnline }
    private var steering: Bool { isStreaming && canSteer }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(isOnline ? (steering ? "Steer while it works…" : placeholder) : "Offline — reconnecting…", text: $text, axis: .vertical)
                .font(BB.Font.body)
                .foregroundStyle(BB.Palette.textPrimary)
                .lineLimit(1...6)
                .focused(focused)
                .submitLabel(.send)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .accessibilityIdentifier("composer.field")

            if steering && canSend {
                Button(action: onSteer) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(BB.Palette.onSignal)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(BB.Palette.auraGradient))
                }
                .buttonStyle(.pressable)
                .padding(.vertical, 5)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("Send steering note")
                .accessibilityIdentifier("composer.steer")
            }

            Button {
                if isStreaming { onStop() } else if canSend { onSend() }
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isStreaming || canSend ? BB.Palette.onSignal : BB.Palette.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isStreaming || canSend ? BB.Palette.signal : BB.Palette.surfaceHigh))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .shadow(color: isStreaming || canSend ? BB.Palette.signalGlow : .clear, radius: 8)
            }
            .buttonStyle(.pressable)
            .disabled(!isStreaming && !canSend)
            .padding(5)
            .sensoryFeedback(.impact(weight: .medium), trigger: isStreaming)
            .accessibilityLabel(isStreaming ? "Stop generating" : "Send")
            .accessibilityIdentifier("composer.send")
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(BB.Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(focused.wrappedValue ? BB.Palette.signal.opacity(0.45) : BB.Palette.strokeStrong, lineWidth: 1)
        )
        .animation(Motion.snappy, value: canSend)
        .animation(Motion.snappy, value: isStreaming)
        .bbAuraBorder(isStreaming, cornerRadius: 24)
        .animation(Motion.standard, value: focused.wrappedValue)
        .padding(.horizontal, BB.Space.gutter)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}
