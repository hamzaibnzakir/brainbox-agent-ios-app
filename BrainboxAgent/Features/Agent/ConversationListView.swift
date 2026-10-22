import SwiftUI
import BrainboxCore

struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var confirmingDelete: Conversation?
    @State private var notice: ChatLifecycleNotice?

    private var filtered: [Conversation] {
        let all = model.chat.activeConversations.filter { !$0.messages.isEmpty }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.messages.contains { $0.plainText.localizedCaseInsensitiveContains(q) } }
    }

    private var archivedCount: Int { model.chat.archivedEntries.count }

    var body: some View {
        NavigationStack {
            List {
                if let notice {
                    ChatLifecycleNoticeRow(notice: notice) { self.notice = nil }
                        .listRowBackground(Color.clear)
                }
                if filtered.isEmpty {
                    EmptyStateView(systemImage: "bubble.left.and.bubble.right", title: query.isEmpty ? "No conversations" : "No matches", message: query.isEmpty ? "Your chats are saved on this device and stay readable offline." : "Try a different search.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, conversation in
                    row(conversation, index: index)
                }
                Section {
                    NavigationLink { ArchivedChatsView() } label: {
                        Label(archivedCount > 0 ? "Archived chats (\(archivedCount))" : "Archived chats", systemImage: "archivebox")
                            .font(BB.Font.callout)
                    }
                    .accessibilityIdentifier("history.archived")
                    .listRowBackground(BB.Palette.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "Search conversations")
            .refreshable { await model.chat.syncArchiveState() }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.isHermes {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink { SessionsBrowserView() } label: {
                            Label("All sessions", systemImage: "tray.full")
                        }
                        .accessibilityIdentifier("history.sessions")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.chat.newConversation()
                        dismiss()
                    } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
                }
            }
            .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") {
                    if let renaming { model.chat.rename(renaming.id, to: newTitle) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Delete permanently?", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                                titleVisibility: .visible, presenting: confirmingDelete) { conversation in
                Button("Delete permanently", role: .destructive) { delete(conversation) }
                    .accessibilityIdentifier("history.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { conversation in
                Text(ChatLifecycleCopy.deleteConfirmation(for: conversation))
            }
        }
    }

    private func row(_ conversation: Conversation, index: Int) -> some View {
        Button {
            model.chat.select(conversation.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(conversation.id == model.chat.currentID ? BB.Palette.signal : BB.Palette.surfaceHigh)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                    Text(conversation.preview).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(2)
                }
                Spacer()
                if model.chat.isBusy(conversation.id) {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(conversation.updatedAt, style: .date).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                        Text(conversation.origin.map { $0.uppercased() + " COPY" } ?? (conversation.providerKind == .mock ? "MOCK" : conversation.providerKind.rawValue.uppercased()))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(BB.Palette.textTertiary)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableSubtle)
        .disabled(model.chat.isBusy(conversation.id))
        .accessibilityIdentifier("history.row")
        .listRowBackground(BB.Palette.surface)
        .bbEntrance(index: index)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { confirmingDelete = conversation } label: { Label("Delete", systemImage: "trash") }
            Button { archive(conversation) } label: { Label("Archive", systemImage: "archivebox") }.tint(.indigo)
        }
        .contextMenu {
            Button {
                newTitle = conversation.title
                renaming = conversation
            } label: { Label("Rename", systemImage: "pencil") }
            Button { archive(conversation) } label: { Label("Archive", systemImage: "archivebox") }
            Button(role: .destructive) { confirmingDelete = conversation } label: { Label("Delete permanently…", systemImage: "trash") }
        }
    }

    private func archive(_ conversation: Conversation) {
        Task {
            do {
                try await model.chat.archive(conversation.id)
                notice = .success("Archived “\(conversation.title)”. Find it under Archived chats.")
                await model.chat.syncArchiveState()
            } catch {
                notice = .failure(error.asAgentError.message)
            }
        }
    }

    private func delete(_ conversation: Conversation) {
        Task {
            do {
                let result = try await model.chat.deletePermanently(conversation.id)
                notice = .success(result.message)
                await model.chat.syncArchiveState()
            } catch {
                notice = .failure("Not deleted. " + error.asAgentError.message)
            }
        }
    }
}

// MARK: - Shared copy and notices

enum ChatLifecycleCopy {
    static func deleteConfirmation(for conversation: Conversation) -> String {
        if AppSessionID.serverID(for: conversation) != nil {
            return "“\(conversation.title)” will be removed from this device and its messages deleted from your Hermes server. This can't be undone. Telegram chats and scheduled-task results are never affected."
        }
        return "“\(conversation.title)” is only stored on this device and will be removed. This can't be undone."
    }

    static let serverOnlyDeleteConfirmation = "This archived chat will be deleted from your Hermes server. This can't be undone."
}

enum ChatLifecycleNotice: Equatable {
    case success(String)
    case failure(String)

    var text: String {
        switch self {
        case .success(let text), .failure(let text): return text
        }
    }

    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}

struct ChatLifecycleNoticeRow: View {
    let notice: ChatLifecycleNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isFailure ? BB.Palette.danger : BB.Palette.success)
            Text(notice.text)
                .font(BB.Font.caption)
                .foregroundStyle(BB.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(notice.isFailure ? "chat.lifecycle.error" : "chat.lifecycle.notice")
    }
}
