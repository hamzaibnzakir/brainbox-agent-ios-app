import SwiftUI
import BrainboxCore

struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    private var filtered: [Conversation] {
        let all = model.chat.conversations.filter { !$0.messages.isEmpty }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.messages.contains { $0.plainText.localizedCaseInsensitiveContains(q) } }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    EmptyStateView(systemImage: "bubble.left.and.bubble.right", title: query.isEmpty ? "No conversations" : "No matches", message: query.isEmpty ? "Your chats are saved on this device and stay readable offline." : "Try a different search.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, conversation in
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
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(conversation.updatedAt, style: .date).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                                Text(conversation.providerKind == .mock ? "MOCK" : conversation.providerKind.rawValue.uppercased())
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(BB.Palette.textTertiary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableSubtle)
                    .listRowBackground(BB.Palette.surface)
                    .bbEntrance(index: index)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            withAnimation(Motion.standard) { model.chat.delete(conversation.id) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button {
                            newTitle = conversation.title
                            renaming = conversation
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) {
                            withAnimation(Motion.standard) { model.chat.delete(conversation.id) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "Search conversations")
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        }
    }
}
