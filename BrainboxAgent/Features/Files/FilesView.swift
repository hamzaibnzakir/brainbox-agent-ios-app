import SwiftUI
import BrainboxCore

struct FilesView: View {
    @Environment(AppModel.self) private var model
    @State private var roots: [FileEntry] = []
    @State private var error: AgentError?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if model.suite.files == nil {
                    EmptyStateView(systemImage: "folder.badge.questionmark", title: "No file access", message: "This backend doesn't expose files. Use Mock, or connect the Brainbox gateway.")
                        .listRowBackground(Color.clear)
                } else {
                    if let error {
                        ErrorBanner(error: error, retry: { Task { await load() } })
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        if loading && roots.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in SkeletonBlock(height: 20).listRowBackground(BB.Palette.surface) }
                        }
                        ForEach(Array(roots.enumerated()), id: \.element.id) { index, root in
                            NavigationLink(value: root) {
                                FileRow(entry: root, showPath: true)
                            }
                            .accessibilityIdentifier("file.\(root.name).\(root.path)")
                            .listRowBackground(BB.Palette.surface)
                            .bbEntrance(index: index)
                        }
                    } header: {
                        Text("Exposed by the backend").bbLabelStyle()
                    } footer: {
                        Text("Only the paths the backend allows are reachable. Brainbox never assumes root access.")
                            .font(BB.Font.caption)
                            .foregroundStyle(BB.Palette.textTertiary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .bbScreen()
            .navigationTitle("Files")
            .navigationDestination(for: FileEntry.self) { entry in
                if entry.isDirectory {
                    DirectoryView(directory: entry)
                } else {
                    FileEditorView(entry: entry)
                }
            }
            .refreshable { await load() }
            .task(id: model.settings.providerKind) { await load() }
        }
    }

    private func load() async {
        guard let files = model.suite.files else { roots = []; return }
        loading = true
        defer { loading = false }
        do {
            let result = try await files.roots()
            withAnimation(Motion.standard) { roots = result; error = nil }
        } catch {
            withAnimation(Motion.standard) { self.error = error.asAgentError }
        }
    }
}

struct FileRow: View {
    let entry: FileEntry
    var showPath = false

    private var icon: String {
        if entry.isDirectory { return "folder.fill" }
        switch entry.language {
        case .yaml, .json, .jsonc: return "doc.badge.gearshape"
        case .markdown: return "doc.richtext"
        case .python, .javascript, .swift: return "chevron.left.forwardslash.chevron.right"
        case .shell: return "terminal"
        case .plainText: return "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(entry.isDirectory ? BB.Palette.signalText : BB.Palette.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                    if entry.isReadOnly { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(BB.Palette.textTertiary) }
                }
                Text(showPath ? entry.path : metadata).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        var parts: [String] = []
        if !entry.isDirectory { parts.append(ByteFormatter.string(entry.size)) }
        parts.append(entry.modifiedAt.formatted(.relative(presentation: .named)))
        if let permissions = entry.permissions { parts.append(permissions) }
        return parts.joined(separator: " · ")
    }
}

struct DirectoryView: View {
    @Environment(AppModel.self) private var model
    let directory: FileEntry

    @State private var entries: [FileEntry] = []
    @State private var error: AgentError?
    @State private var loading = true
    @State private var query = ""
    @State private var searchResults: [FileEntry]?
    @State private var sort: FileSortOrder = .name
    @State private var creating: CreateKind?
    @State private var newName = ""
    @State private var renaming: FileEntry?
    @State private var deleting: FileEntry?

    enum CreateKind: String, Identifiable { case file, folder; var id: String { rawValue } }

    private var shown: [FileEntry] { sort.sort(searchResults ?? entries) }

    var body: some View {
        List {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } }, dismiss: { self.error = nil })
                    .listRowBackground(Color.clear)
            }
            if loading && entries.isEmpty {
                ForEach(0..<5, id: \.self) { _ in SkeletonBlock(height: 20).listRowBackground(BB.Palette.surface) }
            } else if shown.isEmpty {
                EmptyStateView(systemImage: searchResults == nil ? "folder" : "magnifyingglass", title: searchResults == nil ? "Empty folder" : "No results", message: searchResults == nil ? "Create a file or folder with the + button." : "Nothing under this folder matches “\(query)”.")
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                NavigationLink(value: entry) {
                    FileRow(entry: entry, showPath: searchResults != nil)
                }
                .accessibilityIdentifier("file.\(entry.name).\(entry.path)")
                .listRowBackground(BB.Palette.surface)
                .bbEntrance(index: index)
                .swipeActions(edge: .trailing) {
                    if !entry.isReadOnly {
                        Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
                        Button { newName = entry.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }
                            .tint(BB.Palette.ion)
                    }
                }
                .contextMenu {
                    if !entry.isReadOnly {
                        Button { newName = entry.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .animation(Motion.standard, value: shown.map(\.id))
        .navigationTitle(directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search in \(directory.name)")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, newValue in if newValue.isEmpty { searchResults = nil } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        Label("Name", systemImage: "textformat").tag(FileSortOrder.name)
                        Label("Modified", systemImage: "clock").tag(FileSortOrder.modified)
                        Label("Size", systemImage: "arrow.up.arrow.down").tag(FileSortOrder.size)
                    }
                    if !directory.isReadOnly {
                        Divider()
                        Button { newName = ""; creating = .file } label: { Label("New file", systemImage: "doc.badge.plus") }
                        Button { newName = ""; creating = .folder } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    }
                } label: { Image(systemName: "plus.circle") }
                .accessibilityLabel("Sort and create")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .alert(creating == .folder ? "New folder" : "New file", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) { creating = nil }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.isDirectory == true ? "The folder and everything inside it will be deleted on the server. This can't be undone." : "The file will be deleted on the server. This can't be undone.")
        }
    }

    private var files: FileSystemProvider? { model.suite.files }

    private func load() async {
        guard let files else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await files.list(directory.path)
            withAnimation(Motion.standard) { entries = result; error = nil }
        } catch {
            withAnimation(Motion.standard) { self.error = error.asAgentError }
        }
    }

    private func search() async {
        guard let files, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let results = try await files.search(query, in: directory.path)
            withAnimation(Motion.standard) { searchResults = results }
        } catch {
            self.error = error.asAgentError
        }
    }

    private func create() async {
        guard let files, let kind = creating else { return }
        creating = nil
        let path = FilePath.join(directory.path, newName.trimmingCharacters(in: .whitespaces))
        do {
            if kind == .folder {
                _ = try await files.createDirectory(at: path)
            } else {
                _ = try await files.createFile(at: path)
            }
            model.toasts.show(kind == .folder ? "Folder created" : "File created")
            await load()
        } catch {
            self.error = error.asAgentError
        }
    }

    private func rename() async {
        guard let files, let entry = renaming else { return }
        renaming = nil
        do {
            _ = try await files.rename(entry.path, to: newName.trimmingCharacters(in: .whitespaces))
            await load()
        } catch {
            self.error = error.asAgentError
        }
    }

    private func delete() async {
        guard let files, let entry = deleting else { return }
        deleting = nil
        guard await model.gate.authorize(.deleteFile) else {
            if let message = model.gate.lastErrorMessage { error = .permissionDenied(detail: message) }
            return
        }
        do {
            try await files.delete(entry.path)
            model.toasts.show("Deleted \(entry.name)")
            await load()
        } catch {
            self.error = error.asAgentError
        }
    }
}
