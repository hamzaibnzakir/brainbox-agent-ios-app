import SwiftUI
import BrainboxCore

enum SessionFilter: String, CaseIterable, Identifiable {
    case all, ios, telegram, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .ios: return "iOS"
        case .telegram: return "Telegram"
        case .other: return "Other"
        }
    }
    /// Server-side `source` filter where one exists.
    var serverSource: String? {
        switch self {
        case .telegram: return "telegram"
        case .ios: return "api_server"
        default: return nil
        }
    }
    func matches(_ session: HermesSession) -> Bool {
        switch self {
        case .all: return true
        case .ios: return session.sourceKind == .ios
        case .telegram: return session.sourceKind == .telegram
        case .other: return session.sourceKind != .ios && session.sourceKind != .telegram
        }
    }
}

/// Every Hermes session — iOS, Telegram, CLI… — with source labels.
/// Pushed inside an existing NavigationStack.
struct SessionsBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabIsActive) private var tabIsActive
    @State private var filter: SessionFilter = .all
    @State private var sessions: [HermesSession] = []
    @State private var hasMore = false
    @State private var offset = 0
    @State private var loading = false
    @State private var error: AgentError?
    @Namespace private var chips
    private let pageSize = 30

    var body: some View {
        List {
            Section {
                filterBar.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if let error {
                ErrorBanner(error: error, retry: { Task { await reload() } })
                    .listRowBackground(Color.clear)
            }
            if sessions.isEmpty && !loading && error == nil {
                EmptyStateView(systemImage: "tray", title: "No sessions", message: filter == .telegram
                               ? "No Telegram conversations were found in Hermes' session history."
                               : "Sessions from every Hermes surface appear here.")
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, session in
                NavigationLink {
                    SessionTranscriptView(session: session)
                } label: {
                    SessionRow(session: session)
                }
                .listRowBackground(BB.Palette.surface)
                .bbEntrance(index: min(index, Motion.maxStaggeredItems))
                .accessibilityIdentifier("session.\(session.sourceKind.rawValue)")
            }
            if hasMore {
                Button("Load more") { Task { await loadMore() } }
                    .foregroundStyle(BB.Palette.signalText)
                    .listRowBackground(BB.Palette.surface)
            }
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: filter) { await reload() }
        .task {
            // Lightweight refresh so new Telegram messages show up while open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if tabIsActive && !loading { await reload(quiet: true) }
            }
        }
    }

    private var visible: [HermesSession] { sessions.filter(filter.matches) }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(SessionFilter.allCases) { item in
                let selected = item == filter
                Button {
                    withAnimation(Motion.smooth) { filter = item }
                } label: {
                    Text(item.title)
                        .font(BB.Font.subhead)
                        .foregroundStyle(selected ? BB.Palette.onSignal : BB.Palette.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            if selected {
                                Capsule().fill(BB.Palette.signal).matchedGeometryEffect(id: "chip", in: chips)
                            } else {
                                Capsule().fill(BB.Palette.surface)
                            }
                        }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("sessions.filter.\(item.rawValue)")
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func reload(quiet: Bool = false) async {
        guard let client = model.hermes.client else {
            error = .providerUnavailable(detail: "Connect to Hermes to browse sessions.")
            return
        }
        if !quiet { loading = true }
        defer { loading = false }
        do {
            let page = try await client.sessions(limit: pageSize, offset: 0, source: filter.serverSource)
            withAnimation(Motion.smooth) {
                sessions = page.sessions
                hasMore = page.hasMore
                offset = page.sessions.count
                error = nil
            }
        } catch {
            if !quiet { self.error = error.asAgentError }
        }
    }

    private func loadMore() async {
        guard let client = model.hermes.client, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await client.sessions(limit: pageSize, offset: offset, source: filter.serverSource)
            let known = Set(sessions.map(\.id))
            sessions += page.sessions.filter { !known.contains($0.id) }
            hasMore = page.hasMore
            offset += page.sessions.count
        } catch {
            self.error = error.asAgentError
        }
    }
}

struct SourceBadge: View {
    let source: HermesSessionSource
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(source.displayName.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .accessibilityLabel("Source: \(source.displayName)")
    }

    private var symbol: String {
        switch source {
        case .ios: return "iphone"
        case .telegram: return "paperplane.fill"
        case .cli: return "terminal"
        case .discord, .slack: return "bubble.left.and.bubble.right.fill"
        default: return "circle.grid.2x2"
        }
    }

    private var color: Color {
        switch source {
        case .ios: return BB.Palette.signalText
        case .telegram: return Color(hex: 0x2AABEE)
        default: return BB.Palette.textSecondary
        }
    }
}

struct SessionRow: View {
    let session: HermesSession
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SourceBadge(source: session.sourceKind)
                Spacer()
                if let date = session.lastActivity {
                    Text(date, style: .relative).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
            }
            Text(session.displayTitle).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
            HStack(spacing: 10) {
                if let count = session.messageCount { Label("\(count)", systemImage: "text.bubble").labelStyle(.titleAndIcon) }
                if let tools = session.toolCallCount, tools > 0 { Label("\(tools)", systemImage: "wrench.and.screwdriver") }
                if let model = session.model { Text(model).lineLimit(1) }
            }
            .font(BB.Font.caption)
            .foregroundStyle(BB.Palette.textTertiary)
        }
        .padding(.vertical, 4)
    }
}

/// Read-only transcript. External-platform sessions (Telegram) are never
/// written to: "Continue" forks them into a separate app session, and
/// replies from the app are never delivered to Telegram.
struct SessionTranscriptView: View {
    let session: HermesSession
    @Environment(AppModel.self) private var model
    @State private var messages: [HermesMessage] = []
    @State private var loading = true
    @State private var error: AgentError?
    @State private var forking = false
    @State private var confirmFork = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    TranscriptBubble(message: message)
                        .bbEntrance(index: min(index, Motion.maxStaggeredItems))
                }
            }
            .padding(BB.Space.gutter)
        }
        .background(ScreenBackground())
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { continueBar }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Continue in the app?", isPresented: $confirmFork, titleVisibility: .visible) {
            Button("Create a separate copy") { Task { await fork() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(session.sourceKind == .telegram
                 ? "Hermes copies this conversation into a new app session. The Telegram chat is not changed, and nothing you send in the app is delivered to Telegram."
                 : "Hermes copies this conversation into a new app session. The original is not changed.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SourceBadge(source: session.sourceKind)
                Spacer()
            }
            if session.sourceKind.isExternalPlatform {
                Label("Read-only here. This conversation belongs to \(session.sourceKind.displayName).", systemImage: "lock")
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.textSecondary)
            }
            Text("Session \(session.id)").font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var continueBar: some View {
        if model.hermes.report?.supports(.sessionFork) == true || session.sourceKind == .ios {
            Button {
                if session.sourceKind == .ios, model.chat.openConversation(boundTo: session.id) {
                    model.selectedTab = .agent
                } else {
                    confirmFork = true
                }
            } label: {
                Label(forking ? "Copying…" : (session.sourceKind == .ios ? "Open in Chat" : "Continue in the app"), systemImage: "arrow.turn.down.right")
                    .font(BB.Font.headline)
                    .foregroundStyle(BB.Palette.onSignal)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.signal))
            }
            .buttonStyle(.pressable)
            .disabled(forking)
            .padding(.horizontal, BB.Space.gutter)
            .padding(.bottom, 8)
            .accessibilityIdentifier("session.continue")
        }
    }

    private func load() async {
        guard let client = model.hermes.client else { return }
        loading = true
        defer { loading = false }
        do {
            // Latest page (server default), shown oldest → newest.
            let page = try await client.messages(sessionID: session.id, limit: 200, order: "latest")
            let sorted = page.messages.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            withAnimation(Motion.smooth) { messages = sorted; error = nil }
        } catch {
            self.error = error.asAgentError
        }
    }

    private func fork() async {
        guard let client = model.hermes.client else { return }
        forking = true
        defer { forking = false }
        do {
            let title = "\(session.displayTitle) (\(session.sourceKind.displayName) copy)"
            let forked = try await client.forkSession(id: session.id, title: String(title.prefix(80)))
            let imported: [Message] = messages.compactMap { m in
                guard m.role == "user" || m.role == "assistant", !m.content.isEmpty else { return nil }
                return Message(role: m.role == "user" ? .user : .assistant, content: m.content, createdAt: m.date ?? Date(), state: .complete)
            }
            model.chat.importConversation(title: String(title.prefix(80)), sessionID: forked.id, origin: session.sourceKind.rawValue,
                                          teammateID: model.hermes.activeTeammateID, messages: imported)
            model.selectedTab = .agent
            model.toasts.show("Continuing in a separate copy")
        } catch {
            self.error = error.asAgentError
        }
    }
}

private struct TranscriptBubble: View {
    let message: HermesMessage
    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(BB.Font.callout)
                    .foregroundStyle(BB.Palette.onUserBubble)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BB.Palette.userBubble))
                    .textSelection(.enabled)
            }
        case "tool":
            HStack(spacing: 6) {
                Image(systemName: ToolKind.symbolFor(message.toolName))
                Text(message.toolName ?? "tool").font(BB.Font.monoSmall)
                Text(String(message.content.prefix(80))).font(BB.Font.monoSmall).lineLimit(1)
            }
            .foregroundStyle(BB.Palette.textTertiary)
        default:
            if !message.content.isEmpty {
                MarkdownView(text: message.content, isStreaming: false, onCopy: { Clipboard.copy($0) })
            }
        }
    }
}

extension ToolKind {
    static func symbolFor(_ toolName: String?) -> String {
        HermesRunMapper.kind(forTool: toolName ?? "").symbol
    }
}
