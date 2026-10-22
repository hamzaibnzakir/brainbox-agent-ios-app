import SwiftUI
import BrainboxCore

/// Archived conversations: ones archived on this device plus archived app
/// conversations on the server that have no copy here (e.g. after a reinstall).
/// Archive state lives on the server (Hermes' `archived` flag) and in the
/// local copy, so it survives restarts and reinstalls.
struct ArchivedChatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var notice: ChatLifecycleNotice?
    @State private var confirmingDelete: ArchivedChatEntry?
    @State private var working: Set<String> = []

    private var entries: [ArchivedChatEntry] { ArchivedChatEntry.search(model.chat.archivedEntries, query) }

    var body: some View {
        List {
            if let notice {
                ChatLifecycleNoticeRow(notice: notice) { self.notice = nil }
                    .listRowBackground(Color.clear)
            }
            if let syncError = model.chat.archiveSyncError, model.isHermes {
                Label("Couldn't refresh from the server: \(syncError)", systemImage: "icloud.slash")
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.warning)
                    .listRowBackground(Color.clear)
            }
            if entries.isEmpty {
                EmptyStateView(systemImage: "archivebox", title: query.isEmpty ? "No archived chats" : "No matches",
                               message: query.isEmpty ? "Swipe a chat in History and choose Archive to tuck it away here." : "Try a different search.")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search archived chats")
        .navigationTitle("Archived chats")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.chat.syncArchiveState() }
        .task { await model.chat.syncArchiveState() }
        .accessibilityIdentifier("archived.list")
        .confirmationDialog("Delete permanently?", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmingDelete) { entry in
            Button("Delete permanently", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            if let id = entry.localID, let conversation = model.chat.conversations.first(where: { $0.id == id }) {
                Text(ChatLifecycleCopy.deleteConfirmation(for: conversation))
            } else {
                Text(ChatLifecycleCopy.serverOnlyDeleteConfirmation)
            }
        }
    }

    private func row(_ entry: ArchivedChatEntry) -> some View {
        Button { open(entry) } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.localID == nil ? "icloud" : "archivebox")
                    .foregroundStyle(BB.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                    if !entry.preview.isEmpty {
                        Text(entry.preview).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(2)
                    } else if entry.localID == nil {
                        Text("On your server only").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    }
                }
                Spacer()
                if working.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else if let date = entry.lastActivity {
                    Text(date, style: .date).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableSubtle)
        .disabled(working.contains(entry.id))
        .listRowBackground(BB.Palette.surface)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { confirmingDelete = entry } label: { Label("Delete", systemImage: "trash") }
            Button { restore(entry) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }.tint(.green)
        }
        .contextMenu {
            Button { open(entry) } label: { Label("Open", systemImage: "bubble.left") }
            Button { restore(entry) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { confirmingDelete = entry } label: { Label("Delete permanently…", systemImage: "trash") }
        }
        .accessibilityIdentifier("archived.row")
    }

    private func perform(_ entry: ArchivedChatEntry, _ body: @escaping () async throws -> String) {
        guard !working.contains(entry.id) else { return }
        working.insert(entry.id)
        Task {
            defer { working.remove(entry.id) }
            do {
                notice = .success(try await body())
                await model.chat.syncArchiveState()
            } catch {
                notice = .failure(error.asAgentError.message)
            }
        }
    }

    private func restore(_ entry: ArchivedChatEntry) {
        perform(entry) {
            if let id = entry.localID {
                try await model.chat.restore(id)
            } else if let server = entry.server {
                try await model.chat.restore(serverSession: server)
            }
            return "Restored “\(entry.title)” to your chats."
        }
    }

    private func delete(_ entry: ArchivedChatEntry) {
        perform(entry) {
            if let id = entry.localID {
                return try await model.chat.deletePermanently(id).message
            } else if let server = entry.server {
                try await model.chat.deletePermanently(serverSession: server)
                return "Deleted from your server."
            }
            return "Nothing to delete."
        }
    }

    private func open(_ entry: ArchivedChatEntry) {
        if let id = entry.localID {
            model.chat.select(id)
            model.selectedTab = .agent
            dismiss()
            return
        }
        guard let server = entry.server else { return }
        guard let client = model.hermes.client else {
            notice = .failure("Connect to your Hermes server to open this chat.")
            return
        }
        perform(entry) {
            let page = try await client.with(profile: nil).messages(sessionID: server.id, limit: 200, order: "latest")
            let transcript = page.messages.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
            model.chat.reopenOwnSession(server.asSession, transcript: transcript, teammateID: model.hermes.activeTeammateID, archived: true)
            model.selectedTab = .agent
            return "Opened “\(entry.title)” (still archived)."
        }
    }
}
