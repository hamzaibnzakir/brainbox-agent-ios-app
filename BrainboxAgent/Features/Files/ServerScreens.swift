import BrainboxCore
import HermesKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files

struct RemoteFileEntry: Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var id: String { path }
}

struct FilesScreen: View {
    var path: String?
    @Environment(AppModel.self) private var model
    @State private var entries: [RemoteFileEntry] = []
    @State private var current = ""
    @State private var error: String?
    @State private var loading = true
    @State private var showHidden = false
    @State private var showUpload = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var pendingDelete: RemoteFileEntry?

    private var visible: [RemoteFileEntry] { entries.filter { showHidden || !$0.name.hasPrefix(".") } }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var list: some View {
        List {
            if let error {
                ErrorBanner(message: error) { Task { await load() } }.listRowBackground(Color.clear)
            }
            ForEach(visible) { entry in
                FileRow(entry: entry)
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = entry } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
    }

    private var menu: some View {
        Menu {
            Toggle("Show hidden files", isOn: $showHidden)
            Button { showUpload = true } label: { Label("Upload here", systemImage: "square.and.arrow.up") }
            Button { newFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
            Button { UIPasteboard.general.string = current } label: { Label("Copy path", systemImage: "doc.on.doc") }
        } label: { Image(systemName: "ellipsis.circle") }
    }

    private var title: String { current.isEmpty ? "Files" : (current as NSString).lastPathComponent }

    var body: some View {
        list
            .overlay { if loading { ProgressView() } }
            .refreshable { await load() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
            .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await upload(urls) } }
            }
            .alert("New folder", isPresented: $newFolder) {
                TextField("Name", text: $folderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(Text("Delete \(pendingDelete?.name ?? "")?"), isPresented: deleteBinding, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deletePending() }
            } message: { Text("This can't be undone.") }
            .task { await load() }
    }

    private func createFolder() {
        let target = RemoteBackend.shq(current + "/" + folderName)
        Task { await run("mkdir -p " + target) }
    }

    private func deletePending() {
        guard let entry = pendingDelete else { return }
        let target = RemoteBackend.shq(entry.path)
        Task { await run("rm -rf -- " + target) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let client = try await model.client()
            if current.isEmpty {
                if let path { current = path }
                else {
                    let home = try await client.ssh.exec("printf %s \"$HOME\"", timeout: 15).output
                    current = home.isEmpty ? "/root" : home
                }
            }
            let result = try await client.get("/api/fs/list" + HermesClient.query(["path": current]))
            entries = (result["entries"]?.arrayValue ?? []).compactMap { e in
                guard let name = e["name"]?.stringValue, let p = e["path"]?.stringValue else { return nil }
                return RemoteFileEntry(name: name, path: p, isDirectory: e["isDirectory"]?.boolValue ?? false)
            }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ command: String) async {
        do {
            let result = try await model.client().ssh.exec(command, timeout: 60)
            if !result.succeeded { model.toast = result.errorOutput.isEmpty ? "Command failed." : result.errorOutput }
        } catch {
            model.toast = error.localizedDescription
        }
        await load()
    }

    /// Uploads through SSH (`cat > file`), so any size and type works.
    private func upload(_ urls: [URL]) async {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let target = current + "/" + url.lastPathComponent
            do {
                let result = try await model.client().ssh.exec("cat > \(RemoteBackend.shq(target))", stdin: data, timeout: 600)
                model.toast = result.succeeded ? "Uploaded \(url.lastPathComponent)" : result.errorOutput
            } catch {
                model.toast = error.localizedDescription
            }
        }
        await load()
    }

    static func icon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "md", "txt", "log": return "doc.text"
        case "py", "js", "ts", "swift", "sh", "rb", "go", "rs", "json", "yaml", "yml", "toml": return "chevron.left.forwardslash.chevron.right"
        case "zip", "gz", "tar": return "doc.zipper"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

struct FileRow: View {
    var entry: RemoteFileEntry
    var body: some View {
        NavigationLink {
            if entry.isDirectory { FilesScreen(path: entry.path) } else { FileViewer(path: entry.path) }
        } label: {
            HStack(spacing: DS.S.s + 4) {
                Image(systemName: entry.isDirectory ? "folder.fill" : FilesScreen.icon(entry.name))
                    .foregroundStyle(entry.isDirectory ? DS.C.volt : DS.C.ink2)
                    .frame(width: 24)
                Text(entry.name).font(DS.F.body).foregroundStyle(DS.C.ink).lineLimit(1)
            }
        }
    }
}

struct FileViewer: View {
    var path: String
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var original = ""
    @State private var editing = false
    @State private var binary = false
    @State private var error: String?
    @State private var image: UIImage?
    @State private var shareURL: URL?

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit() }
            } else if binary {
                EmptyState(symbol: "doc", title: "Binary file", message: "Download it to open in another app.",
                           action: (label: "Download", run: { Task { await download() } }))
            } else if editing {
                TextEditor(text: $text).font(DS.F.monoSmall).padding(DS.S.s)
            } else {
                ScrollView {
                    CodeBlock(language: (path as NSString).pathExtension, code: text).padding(DS.S.m)
                }
            }
        }
        .overlay(alignment: .top) { if let error { ErrorBanner(message: error).padding(DS.S.m) } }
        .screenBackground()
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !binary && image == nil {
                    if editing {
                        Button("Save") { Task { await save() } }.disabled(text == original)
                    } else {
                        Button("Edit") { editing = true }
                    }
                }
                Menu {
                    Button { Task { await download() } } label: { Label("Download", systemImage: "arrow.down.circle") }
                    Button { UIPasteboard.general.string = path } label: { Label("Copy path", systemImage: "doc.on.doc") }
                    Button { Task { await model.send("Look at \(path) and tell me what it does.") ; model.selectedTab = .chat } } label: {
                        Label("Ask Hermes about it", systemImage: "bubble.left")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: Binding(get: { shareURL.map { IdentifiedURL(url: $0) } }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
        .task { await load() }
    }

    private func load() async {
        let ext = (path as NSString).pathExtension.lowercased()
        do {
            let client = try await model.client()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
                let data = try await client.raw("GET", "/api/fs/download" + HermesClient.query(["path": path])).body
                image = UIImage(data: data)
                return
            }
            let result = try await client.get("/api/fs/read-text" + HermesClient.query(["path": path]))
            binary = result["binary"]?.boolValue ?? false
            text = result["text"]?.stringValue ?? ""
            original = text
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        if await perform(model, "POST", "/api/fs/write-text", json: ["path": .string(path), "content": .string(text)], success: "Saved") != nil {
            original = text
            editing = false
        }
    }

    private func download() async {
        do {
            let data = try await model.client().raw("GET", "/api/fs/download" + HermesClient.query(["path": path]), timeout: 600).body
            let url = FileManager.default.temporaryDirectory.appendingPathComponent((path as NSString).lastPathComponent)
            try data.write(to: url)
            shareURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct IdentifiedURL: Identifiable { var url: URL; var id: String { url.absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Server health

struct SystemScreen: View {
    var body: some View {
        RemoteJSON("/api/system/stats") { stats, reload in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.m) {
                    HStack(spacing: DS.S.s + 4) {
                        gauge("CPU", stats["cpu_percent"]?.doubleValue ?? 0)
                        gauge("Memory", stats["memory"]?["percent"]?.doubleValue ?? 0)
                        gauge("Disk", stats["disk"]?["percent"]?.doubleValue ?? 0)
                    }
                    VStack(alignment: .leading, spacing: DS.S.s) {
                        row("Host", stats["hostname"]?.stringValue)
                        row("OS", stats["platform"]?.stringValue)
                        row("Hermes", stats["hermes_version"]?.stringValue)
                        row("Python", stats["python_version"]?.stringValue)
                        row("CPUs", stats["cpu_count"]?.displayText)
                        row("Load", stats["load_avg"]?.arrayValue?.compactMap { $0.doubleValue }.map { String(format: "%.2f", $0) }.joined(separator: "  "))
                        row("Uptime", stats["uptime_seconds"]?.doubleValue.map { Fmt.duration($0) })
                        row("Memory", stats["memory"].map { "\(Fmt.bytes($0["used"]?.intValue ?? 0)) of \(Fmt.bytes($0["total"]?.intValue ?? 0))" })
                        row("Disk", stats["disk"].map { "\(Fmt.bytes($0["used"]?.intValue ?? 0)) of \(Fmt.bytes($0["total"]?.intValue ?? 0))" })
                    }
                    .card(padding: DS.S.m)
                    GatewayStatusCard()
                }
                .padding(DS.S.m)
            }
            .refreshable { await reload() }
        }
        .screenBackground()
        .navigationTitle("Server health")
    }

    private func gauge(_ label: String, _ value: Double) -> some View {
        VStack(spacing: DS.S.s) {
            ZStack {
                Circle().stroke(DS.C.line, lineWidth: 8)
                Circle().trim(from: 0, to: value / 100).stroke(value > 85 ? DS.C.bad : value > 65 ? DS.C.warn : DS.C.volt,
                                                               style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int(value))%").font(DS.F.smallStrong).monospacedDigit().foregroundStyle(DS.C.ink)
            }
            .frame(width: 72, height: 72)
            Text(label).font(DS.F.caption).foregroundStyle(DS.C.ink3)
        }
        .frame(maxWidth: .infinity)
        .card(padding: DS.S.m)
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(DS.F.caption).foregroundStyle(DS.C.ink3).frame(width: 72, alignment: .leading)
            Text(value ?? "—").font(DS.F.small).foregroundStyle(DS.C.ink).lineLimit(2)
        }
    }
}

/// The messaging gateway (Telegram etc.) as Hermes reports it. Read-only here;
/// starting/stopping lives in Messaging behind a confirmation.
struct GatewayStatusCard: View {
    var body: some View {
        RemoteJSON("/api/status") { status, _ in
            VStack(alignment: .leading, spacing: DS.S.s) {
                HStack {
                    Text("Messaging gateway").font(DS.F.bodyStrong)
                    Spacer()
                    let running = status["gateway_running"]?.boolValue == true
                    Pill(text: running ? "Running" : (status["gateway_state"]?.stringValue ?? "Not running"), color: running ? DS.C.good : DS.C.ink3)
                }
                let platforms = status["gateway_platforms"]?.objectValue ?? [:]
                ForEach(platforms.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).font(DS.F.small)
                        Spacer()
                        Text(platforms[key]?["state"]?.stringValue ?? platforms[key]?.displayText ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                    }
                }
                Text("Active agents: \(status["active_agents"]?.intValue ?? 0) · sessions: \(status["active_sessions"]?.intValue ?? 0)")
                    .font(DS.F.caption).foregroundStyle(DS.C.ink3)
            }
            .card(padding: DS.S.m)
        }
        .frame(minHeight: 80)
    }
}

// MARK: - Logs (read over SSH)

struct LogsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var files: [String] = []
    @State private var selected = "agent.log"
    @State private var text = ""
    @State private var filter = ""
    @State private var follow = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.S.s) {
                    ForEach(files, id: \.self) { f in
                        Button(f) { selected = f }.buttonStyle(ChipButtonStyle(selected: selected == f))
                    }
                }
                .padding(.horizontal, DS.S.m).padding(.vertical, DS.S.s)
            }
            if let error { ErrorBanner(message: error).padding(.horizontal, DS.S.m) }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(filtered.isEmpty ? "(empty)" : filtered)
                        .font(DS.F.monoSmall).foregroundStyle(DS.C.ink2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(DS.S.m)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { _, _ in if follow { proxy.scrollTo("end") } }
            }
        }
        .screenBackground()
        .searchable(text: $filter, prompt: "Filter lines")
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }.toggleStyle(.button)
            }
        }
        .task {
            await listFiles()
            while !Task.isCancelled {
                await read()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !follow { break }
            }
        }
        .onChange(of: selected) { _, _ in Task { await read() } }
    }

    private var filtered: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    private func listFiles() async {
        guard let out = try? await model.client().ssh.exec("ls -1 \"$HOME/.hermes/logs\" 2>/dev/null | grep -E '\\.log$'", timeout: 20).output else { return }
        files = out.split(separator: "\n").map(String.init)
        if !files.contains(selected), let first = files.first { selected = first }
    }

    private func read() async {
        do {
            let result = try await model.client().ssh.exec("tail -n 400 \"$HOME/.hermes/logs/\(selected.replacingOccurrences(of: "/", with: ""))\" 2>&1", timeout: 20)
            text = result.output
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Updates & doctor

struct UpdatesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var output: String?
    @State private var running: String?
    @State private var confirmUpdate = false

    var body: some View {
        RemoteJSON("/api/hermes/update/check") { info, reload in
            List {
                Section {
                    LabeledContent("Installed", value: info["current_version"]?.stringValue ?? model.serverInfo?.version ?? "?")
                    LabeledContent("Install", value: info["install_method"]?.stringValue ?? "")
                    if let behind = info["behind"]?.intValue { LabeledContent("Behind", value: "\(behind) commits") }
                    if let message = info["message"]?.stringValue { Text(message).font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                    if info["update_available"]?.boolValue == true {
                        Button("Update Hermes") { confirmUpdate = true }.foregroundStyle(DS.C.volt)
                    }
                    Button("Check again") { Task { await reload() } }
                } header: { Text("Version") }
                Section {
                    action("Run doctor", "stethoscope", "/api/ops/doctor")
                    action("Security audit", "lock.shield", "/api/ops/security-audit")
                    action("Measure prompt size", "ruler", "/api/ops/prompt-size")
                    action("Migrate config", "arrow.triangle.2.circlepath", "/api/ops/config-migrate")
                } header: { Text("Checks") } footer: { Text("These run Hermes' own maintenance commands on the server.") }
                if let output {
                    Section("Result") { Text(output).font(DS.F.monoSmall).textSelection(.enabled) }
                }
            }
            .confirmationDialog("Update Hermes now?", isPresented: $confirmUpdate, titleVisibility: .visible) {
                Button("Update") { Task { await run("/api/hermes/update") } }
            } message: {
                Text("Hermes updates itself on the server. Running chats and the Telegram gateway may restart.")
            }
        }
        .navigationTitle("Updates & doctor")
    }

    private func action(_ title: String, _ symbol: String, _ path: String) -> some View {
        Button {
            Task { await run(path) }
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if running == path { ProgressView() }
            }
        }
        .disabled(running != nil)
    }

    private func run(_ path: String) async {
        running = path
        defer { running = nil }
        if let result = await perform(model, "POST", path) {
            output = result["output"]?.stringValue ?? result["report"]?.stringValue ?? result.displayText
        }
    }
}

// MARK: - Backups

struct BackupScreen: View {
    @Environment(AppModel.self) private var model
    @State private var working = false
    @State private var result: String?
    @State private var shareURL: URL?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await backup() }
                } label: {
                    HStack { Label("Make a backup", systemImage: "externaldrive.badge.plus"); Spacer(); if working { ProgressView() } }
                }
                .disabled(working)
            } footer: {
                Text("Hermes zips your ~/.hermes (config, memory, sessions, skills) on the server. You can then save the zip to Files.")
            }
            if let result { Section("Result") { Text(result).font(DS.F.monoSmall) } }
        }
        .navigationTitle("Backups")
        .sheet(item: Binding(get: { shareURL.map { IdentifiedURL(url: $0) } }, set: { shareURL = $0?.url })) { ShareSheet(items: [$0.url]) }
    }

    private func backup() async {
        working = true
        defer { working = false }
        guard let made = await perform(model, "POST", "/api/ops/backup", success: "Backup made") else { return }
        result = made.displayText
        if let data = try? await model.client().raw("GET", "/api/ops/backup/download", timeout: 900).body {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-backup.zip")
            try? data.write(to: url)
            shareURL = url
        }
    }
}
