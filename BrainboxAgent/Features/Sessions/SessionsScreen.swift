import BrainboxCore
import HermesKit
import SwiftUI

struct SessionsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var source = "all"
    @State private var viewing: SessionSummary?
    @State private var confirmDelete: SessionSummary?

    private var sources: [String] {
        let all = Set(model.sessions.map { $0.source.isEmpty ? "app" : $0.source })
        return ["all"] + all.sorted()
    }

    private var filtered: [SessionSummary] {
        model.sessions.filter { s in
            (source == "all" || (s.source.isEmpty ? "app" : s.source) == source) &&
                (search.isEmpty || s.displayTitle.localizedCaseInsensitiveContains(search) || s.preview.localizedCaseInsensitiveContains(search))
        }
    }

    struct SessionGroup: Identifiable { var id: String; var items: [SessionSummary] }

    private var groups: [SessionGroup] {
        let cal = Calendar.current
        var buckets: [String: [SessionSummary]] = [:]
        var order: [String] = []
        for s in filtered.sorted(by: { $0.startedAt > $1.startedAt }) {
            let key: String
            if cal.isDateInToday(s.startedAt) { key = "Today" }
            else if cal.isDateInYesterday(s.startedAt) { key = "Yesterday" }
            else if let days = cal.dateComponents([.day], from: s.startedAt, to: Date()).day, days < 7 { key = "This week" }
            else { key = s.startedAt.formatted(.dateTime.month(.wide).year()) }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(s)
        }
        return order.map { SessionGroup(id: $0, items: buckets[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.S.l, pinnedViews: []) {
                ConnectionBanner()
                sourceChips
                if let error = model.sessionsError {
                    ErrorBanner(message: error) { Task { await model.refreshSessions() } }
                }
                if filtered.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: search.isEmpty ? "No sessions yet" : "Nothing matches",
                               message: search.isEmpty ? "Every chat with Hermes, from any app, shows up here." : "Try a different word.",
                               action: emptyAction)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: DS.S.s) {
                        SectionTitle(text: group.id, trailing: "\(group.items.count)")
                        VStack(spacing: 0) {
                            ForEach(group.items) { session in
                                row(session)
                                if session.id != group.items.last?.id { Divider().overlay(DS.C.line).padding(.leading, 72) }
                            }
                        }
                        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).stroke(DS.C.line.opacity(0.6), lineWidth: 0.5))
                    }
                }
            }
            .padding(DS.S.m)
        }
        .screenBackground()
        .searchable(text: $search, prompt: "Search chats")
        .refreshable { await model.refreshSessions() }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.newChat() } } label: { Image(systemName: "square.and.pencil") }.disabled(!model.isConnected)
            }
        }
        .sheet(item: $viewing) { session in NavigationStack { ReadOnlyTranscript(session: session) } }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { session in
            Button("Delete", role: .destructive) { Task { await model.delete(session: session) } }
        } message: { _ in Text("It's removed from Hermes on the server.") }
        .task { if model.sessions.isEmpty { await model.refreshSessions() } }
    }

    private var emptyAction: (label: String, run: () -> Void)? {
        guard model.isConnected else { return nil }
        let model = self.model
        return (label: "New chat", run: { Task { await model.newChat() } })
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.S.s) {
                ForEach(sources, id: \.self) { s in
                    Button(s == "all" ? "All" : s.capitalized) { source = s }.buttonStyle(ChipButtonStyle(selected: source == s))
                }
            }
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        Button {
            if session.isReadOnly { viewing = session } else { Task { await model.open(session: session) } }
        } label: {
            HStack(spacing: DS.S.m) {
                IconTile(symbol: Self.symbol(session.source), index: Self.tint(session.source), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.displayTitle).font(DS.F.body).foregroundStyle(DS.C.ink).lineLimit(1)
                        if session.id == model.currentChat { StatusDot(color: DS.C.volt) }
                    }
                    if !session.preview.isEmpty, session.preview != session.title {
                        Text(session.preview).font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.relative(session.startedAt)).font(DS.F.caption).foregroundStyle(DS.C.ink3)
                    if session.isReadOnly { Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(DS.C.ink3) }
                }
            }
            .padding(.horizontal, DS.S.m)
            .padding(.vertical, DS.S.s + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !session.isReadOnly {
                Button { Task { await model.open(session: session) } } label: { Label("Open", systemImage: "bubble.left") }
                Button(role: .destructive) { confirmDelete = session } label: { Label("Delete", systemImage: "trash") }
            } else {
                Button { viewing = session } label: { Label("View", systemImage: "eye") }
            }
            Button { UIPasteboard.general.string = session.id } label: { Label("Copy session ID", systemImage: "number") }
        }
    }

    static func symbol(_ source: String) -> String {
        switch source {
        case "telegram": return "paperplane.fill"
        case "whatsapp": return "phone.bubble.fill"
        case "discord": return "gamecontroller.fill"
        case "slack": return "number"
        case "cron": return "calendar.badge.clock"
        case "api_server": return "network"
        case "tui", "desktop", "cli", "": return "bubble.left.fill"
        default: return "bubble.left.and.bubble.right"
        }
    }

    static func tint(_ source: String) -> Int {
        switch source {
        case "telegram": return 3
        case "cron": return 2
        case "tui", "desktop", "cli", "": return 0
        default: return 5
        }
    }
}

/// History of a session from another surface (Telegram, cron…), read-only.
struct ReadOnlyTranscript: View {
    var session: SessionSummary
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var transcript = Transcript()
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.S.m) {
                Label("Read-only: this chat belongs to \(session.source.capitalized). Brainbox shows it but never writes to it.",
                      systemImage: "eye")
                    .font(DS.F.caption).foregroundStyle(DS.C.ink3)
                if let error { ErrorBanner(message: error) }
                ForEach(transcript.items) { item in
                    switch item.kind {
                    case .user(let text, _): UserBubble(text: text, attachments: [])
                    case .assistant(let text, _, _): AssistantMessage(text: text, reasoning: nil, streaming: false)
                    case .tool(let tool): ToolCard(tool: tool, expandedByDefault: false)
                    default: EmptyView()
                    }
                }
            }
            .padding(DS.S.m)
        }
        .overlay { if loading { ProgressView() } }
        .screenBackground()
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        dismiss()
                        await model.newChat()
                        await model.send("Continue from my \(session.source) chat \"\(session.displayTitle)\" (session \(session.id)). Read it with session_search first.")
                    }
                } label: { Label("Continue here", systemImage: "arrowshape.turn.up.right") }
            }
        }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        do {
            let result = try await model.engine.call(nil, "session.resume", ["session_id": .string(session.id)], timeout: 90)
            var t = Transcript()
            t.hydrate(messages: result["messages"]?.arrayValue ?? [])
            transcript = t
            if let live = result["session_id"]?.stringValue {
                _ = try? await model.engine.call(nil, "session.close", ["session_id": .string(live)])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
