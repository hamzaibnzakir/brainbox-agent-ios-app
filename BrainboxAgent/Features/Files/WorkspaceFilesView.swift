import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import BrainboxCore

/// The Brainbox workspace on the server: inbox (what you send) and outbox
/// (what the agent leaves for you). Nothing else on the server is reachable.
struct WorkspaceFilesView: View {
    @Environment(AppModel.self) private var model
    var path: String = ""

    @State private var listing: WorkspaceListing?
    @State private var error: AgentError?
    @State private var loading = false
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var confirmDelete: WorkspaceEntry?
    @State private var preview: URL?
    @State private var notice: ChatLifecycleNotice?

    private var client: HermesAPIClient? { model.hermes.client }
    private var limits: (allowed: Set<String>, maxBytes: Int64) {
        let serverAllowed = Set(listing?.allowedExtensions ?? [])
        return (serverAllowed.isEmpty ? WorkspacePolicy.defaultExtensions : serverAllowed,
                listing?.maxUploadBytes ?? WorkspacePolicy.defaultMaxUploadBytes)
    }
    private var canUpload: Bool { path == "inbox" || path.hasPrefix("inbox/") || path.isEmpty }

    var body: some View {
        List {
            if let notice {
                ChatLifecycleNoticeRow(notice: notice) { self.notice = nil }.listRowBackground(Color.clear)
            }
            transfersSection
            if path.isEmpty {
                Section {
                    Text("Only this workspace is visible to the app. Put files in the inbox for your agent; it can leave results in the outbox.")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
                .listRowBackground(Color.clear)
            }
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } }, dismiss: { self.error = nil })
                    .listRowBackground(Color.clear)
            }
            if let listing {
                if listing.entries.isEmpty {
                    EmptyStateView(systemImage: "tray", title: "Empty", message: path.hasPrefix("outbox") ? "Nothing from the agent yet." : "Upload a photo or file with the + button.")
                        .listRowBackground(Color.clear)
                }
                ForEach(listing.entries) { entry in
                    row(entry)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .bbScreen()
        .navigationTitle(path.isEmpty ? "Files" : (path as NSString).lastPathComponent.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            if canUpload {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                            Label("Photo", systemImage: "photo")
                        }
                        Button { importing = true } label: { Label("File", systemImage: "doc") }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Upload")
                    .accessibilityIdentifier("files.upload")
                    .disabled(client == nil)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await uploadFile(url) } }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { for item in items { await uploadPhoto(item) } }
        }
        .confirmationDialog("Delete this file from the server?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { entry in
            Button("Delete", role: .destructive) { Task { await delete(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("“\(entry.name)” will be removed from the Brainbox workspace. This can't be undone.")
        }
        .quickLookPreview($preview)
    }

    @ViewBuilder
    private var transfersSection: some View {
        let transfers = model.transfers.transfers.prefix(5)
        if !transfers.isEmpty {
            Section {
                ForEach(Array(transfers)) { transfer in
                    TransferRow(transfer: transfer, cancel: { model.transfers.cancel(transfer.id) },
                                dismiss: { model.transfers.dismiss(transfer.id) })
                }
            } header: { Text("Transfers").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)
        }
    }

    @ViewBuilder
    private func row(_ entry: WorkspaceEntry) -> some View {
        if entry.kind == .directory {
            NavigationLink { WorkspaceFilesView(path: entry.path) } label: {
                FileEntryLabel(entry: entry)
            }
            .listRowBackground(BB.Palette.surface)
            .accessibilityIdentifier("files.dir.\(entry.name)")
        } else {
            Button { Task { await open(entry) } } label: { FileEntryLabel(entry: entry) }
                .buttonStyle(.pressableSubtle)
                .listRowBackground(BB.Palette.surface)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { confirmDelete = entry } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu {
                    Button { Task { await open(entry) } } label: { Label("Download & preview", systemImage: "arrow.down.circle") }
                    Button(role: .destructive) { confirmDelete = entry } label: { Label("Delete", systemImage: "trash") }
                }
        }
    }

    // MARK: Actions

    private func load() async {
        guard let client else {
            error = .providerUnavailable(detail: "Connect to Hermes through the Brainbox proxy to see files.")
            return
        }
        guard model.hermes.features?.files ?? false else {
            error = .providerUnavailable(detail: model.hermes.gatewayInfo == nil
                ? "Files need the Brainbox proxy; this connection goes straight to Hermes."
                : "File transfer is turned off on the server, or this proxy is too old.")
            return
        }
        loading = true
        defer { loading = false }
        do {
            listing = try await client.workspaceList(path: path)
            error = nil
        } catch {
            self.error = error.asAgentError
        }
    }

    private func uploadFile(_ url: URL) async {
        guard let client else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await model.transfers.upload(fileAt: url, name: url.lastPathComponent, client: client, limits: limits)
            notice = .success("Uploaded \(result.file.name) to the inbox.")
            await load()
        } catch AgentError.cancelled {
            notice = nil
        } catch {
            notice = .failure("\(url.lastPathComponent): \(error.asAgentError.message)")
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        guard let client else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let name = "Photo \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())).\(ext)"
            let result = try await model.transfers.upload(data: data, name: name, client: client, limits: limits)
            notice = .success("Uploaded \(result.file.name) to the inbox.")
            await load()
        } catch AgentError.cancelled {
            notice = nil
        } catch {
            notice = .failure(error.asAgentError.message)
        }
    }

    private func open(_ entry: WorkspaceEntry) async {
        guard let client else { return }
        do {
            preview = try await model.transfers.download(entry, client: client)
        } catch AgentError.cancelled {
        } catch {
            notice = .failure("\(entry.name): \(error.asAgentError.message)")
        }
    }

    private func delete(_ entry: WorkspaceEntry) async {
        guard let client else { return }
        do {
            try await client.workspaceDelete(path: entry.path)
            notice = .success("Deleted \(entry.name).")
            await load()
        } catch {
            notice = .failure("Not deleted. " + error.asAgentError.message)
        }
    }
}

struct FileEntryLabel: View {
    let entry: WorkspaceEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(entry.kind == .directory ? BB.Palette.signalText : BB.Palette.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let date = entry.modifiedDate { Text(date, style: .date) }
                }
                .font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if entry.kind == .directory { return entry.name == "inbox" ? "tray.and.arrow.down" : entry.name == "outbox" ? "tray.and.arrow.up" : "folder" }
        if entry.isImage { return "photo" }
        if entry.mime == "application/pdf" { return "doc.richtext" }
        if entry.mime?.hasPrefix("text/") == true { return "doc.text" }
        return "doc"
    }
}

struct TransferRow: View {
    let transfer: TransferManager.Transfer
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(BB.Palette.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                switch transfer.state {
                case .running:
                    ProgressView(value: transfer.progress).tint(BB.Palette.signal)
                case .finished:
                    Text(transfer.direction == .upload ? "Uploaded" : "Downloaded").font(BB.Font.caption).foregroundStyle(BB.Palette.success)
                case .failed(let message):
                    Text(message).font(BB.Font.caption).foregroundStyle(BB.Palette.danger).lineLimit(2)
                case .cancelled:
                    Text("Cancelled").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
            }
            Spacer()
            if transfer.state == .running {
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(BB.Palette.textTertiary)
                    .accessibilityLabel("Cancel \(transfer.name)")
            } else {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(BB.Palette.textTertiary)
                    .accessibilityLabel("Dismiss")
            }
        }
    }
}
