import SwiftUI
import UIKit
import PhotosUI
import BrainboxCore

struct AgentView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var showHistory = false
    @State private var isAtBottom = true
    @State private var lastAutoScroll = Date.distantPast
    @State private var reviewing: AgentApproval?
    @State private var hop = 0
    @State private var attachments: [PendingAttachment] = []
    @State private var commandError: String?
    @State private var showSessions = false
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
                if let commandError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(BB.Palette.textSecondary)
                        Text(commandError).font(BB.Font.caption).foregroundStyle(BB.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { self.commandError = nil } label: { Image(systemName: "xmark").font(.caption) }
                            .buttonStyle(.plain).foregroundStyle(BB.Palette.textTertiary).accessibilityLabel("Dismiss")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surfaceHigh))
                    .padding(.horizontal, BB.Space.gutter)
                    .accessibilityIdentifier("composer.notice")
                    .transition(.bbRise)
                }
                if let conversationID = chat.currentID, let queued = chat.queuedInstructions[conversationID], !queued.isEmpty {
                    QueuedInstructionsView(items: queued, canSendNow: !chat.isStreaming,
                                           remove: { chat.removeQueued($0, from: conversationID) },
                                           sendNow: { chat.sendQueuedNow($0, in: conversationID) })
                }
                Composer(
                    text: $draft,
                    attachments: $attachments,
                    isStreaming: replyRunningHere,
                    isOnline: model.network.isOnline,
                    focused: $composerFocused,
                    suggestions: SlashCommandRouter.suggestions(for: draft, catalog: model.hermes.commandCatalog),
                    argumentHelp: SlashCommandRouter.argumentHelp(for: draft, catalog: model.hermes.commandCatalog),
                    canAttach: model.isHermes,
                    canInject: chat.canSteer,
                    busyMode: chat.busyMode(),
                    onSend: send,
                    onStop: { chat.stop() },
                    onSteer: steer,
                    onPickPhotos: addPhotos,
                    onPickFiles: addFiles,
                    placeholder: model.isHermes ? "Message \(currentTeammate.name), or type /" : "Message the agent…"
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
            .sheet(isPresented: $showSessions) {
                NavigationStack { SessionsBrowserView() }
                    .presentationDragIndicator(.visible)
            }
            .animation(Motion.standard, value: commandError)
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
            MascotView(style: model.isHermes ? currentTeammate.mascot : .brainbox, mood: currentMood, size: 40,
                       seed: model.isHermes ? currentTeammate.id : MascotView.defaultSeed, hopTrigger: hop)
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

    /// A reply is running in the chat on screen (another chat's reply doesn't
    /// turn this composer into a stop button).
    private var replyRunningHere: Bool { chat.isStreaming && chat.activeConversationID == chat.currentID }

    private func steer(_ mode: ChatStore.SteerMode) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task {
            do {
                try await chat.steer(text, mode: mode)
                switch mode {
                case .inject: model.toasts.show("Steering sent")
                case .queue: model.toasts.show("Queued for after this reply")
                case .interrupt: model.toasts.show("Stopping, then sending")
                }
            } catch {
                draft = text
                commandError = error.asAgentError.message
            }
        }
    }

    // MARK: Attachments

    private func addPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            let pending = PendingAttachment(name: "Photo.jpg", kind: .image, byteCount: 0)
            attachments.append(pending)
            let id = pending.id
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let prepared = ImagePrep.prepare(data) else {
                    update(id) { $0.state = .failed("Couldn't read this photo") }
                    return
                }
                update(id) {
                    $0.byteCount = Int64(prepared.jpeg.count)
                    $0.thumbnail = prepared.thumbnail
                    $0.dataURL = prepared.dataURL
                    $0.state = .ready
                }
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        guard let client = model.hermes.client, model.hermes.features?.files == true else {
            commandError = "Sending files needs the Brainbox proxy's file transfer (Server → Files)."
            return
        }
        for url in urls {
            let pending = PendingAttachment(name: url.lastPathComponent, kind: .file, byteCount: 0, state: .uploading(0))
            attachments.append(pending)
            let id = pending.id
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let upload = try await model.transfers.upload(fileAt: url, name: url.lastPathComponent, client: client)
                    update(id) {
                        $0.name = upload.file.name
                        $0.byteCount = upload.file.size ?? 0
                        $0.serverPath = upload.absolutePath ?? upload.file.path
                        $0.state = .ready
                    }
                } catch {
                    update(id) { $0.state = .failed(error.asAgentError.message) }
                }
            }
        }
    }

    private func update(_ id: UUID, _ body: (inout PendingAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        body(&attachments[index])
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
                                onReviewApproval: { reviewing = $0 },
                                onStopAgain: message.id == chat.activeMessageID ? { chat.stop() } : nil,
                                onStopFollowing: message.id == chat.activeMessageID ? { chat.stopFollowing() } : nil,
                                onReconnect: { chat.reconnectLiveRuns() }
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
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = attachments.filter { $0.state == .ready }
        guard !text.isEmpty || !ready.isEmpty else { return }
        let files = ready.filter { $0.kind == .file }.compactMap { item in
            item.serverPath.map { AttachmentPrompt.Item(name: item.name, serverPath: $0, isImage: false) }
        }
        var note: String?
        if !files.isEmpty {
            let full = AttachmentPrompt.compose(text, attachments: files)
            note = text.isEmpty ? full : String(full.dropFirst(text.count))
        }
        let images = ready.compactMap(\.dataURL)
        draft = ""
        let sentAttachments = attachments
        attachments = []
        commandError = nil
        Task {
            let outcome = await chat.submit(text, attachments: ready.map(\.asMessageAttachment), imageDataURLs: images, attachmentNote: note)
            switch outcome {
            case .sent:
                break
            case .handled(let message):
                if let message { model.toasts.show(message) }
            case .refused(let reason):
                draft = text
                attachments = sentAttachments
                commandError = reason
            case .navigate(let destination):
                switch destination {
                case .workspace: model.selectedTab = .team
                case .sessions: showSessions = true
                case .files: model.open(.files)
                case .terminal: model.open(.terminal)
                }
            case .parallel(let tasks):
                let mate = currentTeammate
                model.agents.start(title: tasks.joined(separator: " · "),
                                   prompts: tasks.map { (title: String($0.prefix(40)), prompt: $0, instructions: mate.runInstructions, model: mate.model) },
                                   synthesize: true)
                model.selectedTab = .team
                model.toasts.show("Started \(tasks.count) agents")
            case .background(let prompt, let origin):
                let mate = currentTeammate
                model.agents.start(title: "Background: " + String(prompt.prefix(50)),
                                   prompts: [(title: String(prompt.prefix(40)), prompt: prompt, instructions: mate.runInstructions, model: mate.model)],
                                   synthesize: false, origin: origin)
                model.toasts.show("Running in the background — the result will appear in this chat")
            }
        }
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
                MascotView(style: .brainbox, mood: model.connectionState.isConnected ? .idle : .offline, size: 120)
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

