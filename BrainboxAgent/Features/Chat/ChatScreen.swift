import BrainboxCore
import HermesKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showModels = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showTodos = true

    private var chat: String? { model.currentChat }
    private var transcript: Transcript { chat.flatMap { model.transcripts[$0] } ?? Transcript() }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner().padding(.top, model.isConnected ? 0 : DS.S.s)
            if let chat, !transcript.items.isEmpty {
                messages(chat: chat)
            } else {
                welcome
            }
        }
        .screenBackground()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.S.s) {
                if !transcript.todos.isEmpty { TodoPanel(todos: transcript.todos, expanded: $showTodos) }
                Composer(chat: chat, busy: transcript.busy, status: transcript.status)
            }
        }
        .toolbar { toolbar }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModels) { NavigationStack { ModelPicker() } }
        .alert("Rename chat", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Save") { if let chat { Task { await model.rename(chat: chat, to: renameText) } } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: DS.S.s + 4) {
                Companion(mood: model.isConnected ? transcript.petMood : .idle, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(transcript.title ?? (chat == nil ? "Hermes" : "New chat"))
                        .font(DS.F.smallStrong).foregroundStyle(DS.C.ink).lineLimit(1)
                    HStack(spacing: DS.S.xs) {
                        if transcript.busy { StatusDot(color: DS.C.volt, pulsing: true) }
                        Text(subtitle).font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: 240)
            .onTapGesture { showModels = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { Task { await model.newChat() } } label: { Label("New chat", systemImage: "square.and.pencil") }
                Button { showModels = true } label: { Label("Model", systemImage: "cpu") }
                if chat != nil {
                    Button { renameText = transcript.title ?? ""; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                    if let text = shareText { ShareLink(item: text) { Label("Share chat", systemImage: "square.and.arrow.up") } }
                    Button { Task { await model.send("/compress") } } label: { Label("Compress context", systemImage: "rectangle.compress.vertical") }
                    Button { Task { await model.send("/usage") } } label: { Label("Usage", systemImage: "chart.bar") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18, weight: .semibold))
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button { Task { await model.newChat() } } label: { Image(systemName: "square.and.pencil").font(.system(size: 17, weight: .semibold)) }
                .disabled(!model.isConnected)
                .accessibilityLabel("New chat")
        }
    }

    private var subtitle: String {
        if let status = transcript.status, transcript.busy { return status }
        var parts: [String] = []
        if let m = transcript.model ?? transcript.usage?.model { parts.append(m) }
        if let pct = transcript.usage?.contextPercent { parts.append("\(pct)% context") }
        if parts.isEmpty { return model.isConnected ? "Ready" : "Offline" }
        return parts.joined(separator: " · ")
    }

    private var shareText: String? {
        let lines = transcript.items.compactMap { item -> String? in
            switch item.kind {
            case .user(let t, _): return "You: " + t
            case .assistant(let t, _, _): return "Hermes: " + t
            default: return nil
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    private func messages(chat: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.S.m) {
                    ForEach(transcript.items) { item in
                        ChatItemView(item: item, chat: chat).id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, DS.S.m)
                .padding(.top, DS.S.m)
                .padding(.bottom, DS.S.s)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: transcript.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: transcript.items.last) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: DS.S.l) {
                Spacer(minLength: DS.S.xxl)
                Companion(mood: .idle, size: 96)
                VStack(spacing: DS.S.s) {
                    Text(greeting).font(DS.F.title).foregroundStyle(DS.C.ink)
                    Text(model.isConnected ? "Hermes is ready on \(model.profile?.name ?? "your server")." : "Connect to start chatting.")
                        .font(DS.F.small).foregroundStyle(DS.C.ink2)
                }
                if model.isConnected {
                    VStack(spacing: DS.S.s) {
                        ForEach(Self.suggestions, id: \.text) { s in
                                    Button { Task { await model.send(s.text) } } label: {
                                HStack(spacing: DS.S.s + 4) {
                                    Text(s.emoji).font(.system(size: 20))
                                    Text(s.text).font(DS.F.small).foregroundStyle(DS.C.ink).multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.ink3)
                                }
                                .padding(DS.S.m)
                                .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DS.S.m)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    struct Suggestion { var emoji: String; var text: String }
    static let suggestions: [Suggestion] = [
        .init(emoji: "🩺", text: "Check the server's health and tell me anything unusual"),
        .init(emoji: "🗓️", text: "What scheduled jobs do I have, and when do they run next?"),
        .init(emoji: "📬", text: "Summarise what happened in my Telegram chats today"),
        .init(emoji: "🧠", text: "What do you remember about my projects?"),
    ]
}

struct TodoPanel: View {
    var todos: [TodoItem]
    @Binding var expanded: Bool

    var body: some View {
        let done = todos.filter { $0.status == "completed" }.count
        VStack(alignment: .leading, spacing: DS.S.s) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack {
                    Label("Plan · \(done)/\(todos.count)", systemImage: "checklist").font(DS.F.captionStrong).foregroundStyle(DS.C.ink2)
                    Spacer()
                    ProgressView(value: Double(done), total: Double(max(todos.count, 1))).frame(width: 64).tint(DS.C.volt)
                    Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.ink3)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(todos, id: \.id) { todo in
                    HStack(spacing: DS.S.s) {
                        Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : todo.status == "in_progress" ? "circle.dotted.circle" : "circle")
                            .foregroundStyle(todo.status == "completed" ? DS.C.good : todo.status == "in_progress" ? DS.C.volt : DS.C.ink3)
                        Text(todo.content).font(DS.F.small).foregroundStyle(todo.status == "completed" ? DS.C.ink3 : DS.C.ink)
                            .strikethrough(todo.status == "completed").lineLimit(2)
                    }
                }
            }
        }
        .padding(DS.S.s + 4)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.line, lineWidth: 1))
        .padding(.horizontal, DS.S.m)
    }
}

// MARK: - Composer

struct Composer: View {
    var chat: String?
    var busy: Bool
    var status: String?

    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var suggestions: [SlashSuggestion] = []
    @State private var catalog: [SlashSuggestion] = []
    @FocusState private var focused: Bool
    @State private var voice = Voice.shared

    var body: some View {
        VStack(spacing: DS.S.s) {
            if !suggestions.isEmpty { suggestionList }
            if !attachments.isEmpty { attachmentStrip }
            if voice.phase == .recording || voice.phase == .transcribing || voice.phase == .speaking { voiceBar }
            if case .failed(let message) = voice.phase {
                ErrorBanner(message: message) { voice.phase = .idle }.padding(.horizontal, DS.S.m)
            }
            HStack(alignment: .bottom, spacing: DS.S.s) {
                Menu {
                    Button { showPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                    Divider()
                    Button { text = "/"; focused = true } label: { Label("Commands", systemImage: "command") }
                    Button { text = "/btw "; focused = true } label: { Label("Side question (/btw)", systemImage: "bubble.left") }
                    Button { text = "/bg "; focused = true } label: { Label("Background task (/bg)", systemImage: "moon.stars") }
                    Divider()
                    Button { startConversation() } label: { Label("Voice conversation", systemImage: "waveform") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(DS.C.ink)
                        .frame(width: 44, height: 44).background(DS.C.surface, in: Circle())
                        .overlay(Circle().stroke(DS.C.line, lineWidth: 1))
                }
                .disabled(!model.isConnected)

                HStack(alignment: .bottom, spacing: DS.S.xs) {
                    TextField(model.isConnected ? (busy ? "Message Hermes (queued after this turn)" : "Message Hermes") : "Offline",
                              text: $text, axis: .vertical)
                        .font(DS.F.body)
                        .lineLimit(1...8)
                        .focused($focused)
                        .padding(.leading, DS.S.m)
                        .padding(.vertical, DS.S.s + 4)
                        .onChange(of: text) { _, new in updateSuggestions(new) }
                    trailingButton
                        .padding(.trailing, DS.S.xs)
                        .padding(.bottom, DS.S.xs)
                }
                .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(focused ? DS.C.volt.opacity(0.6) : DS.C.line, lineWidth: 1))
            }
            .padding(.horizontal, DS.S.m)
            .padding(.bottom, DS.S.s)
        }
        .padding(.top, DS.S.s)
        .background(DS.C.canvas.opacity(0.94).ignoresSafeArea(edges: .bottom))
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for url in urls { addFile(url) } }
        }
        .onChange(of: photoItems) { _, items in Task { await loadPhotos(items) } }
        .onChange(of: model.sharedAttachments) { _, shared in
            if !shared.isEmpty { attachments.append(contentsOf: shared); model.sharedAttachments.removeAll() }
        }
        .onChange(of: chat) { _, newChat in
            if let newChat, let prefill = model.composerPrefill.removeValue(forKey: newChat) { text = prefill }
        }
        .onChange(of: model.composerPrefill) { _, map in
            if let chat, let prefill = map[chat] { text = prefill; model.composerPrefill[chat] = nil; focused = true }
        }
        .onChange(of: model.voiceRequested) { _, wanted in
            if wanted { model.voiceRequested = false; startConversation() }
        }
        .task(id: model.isConnected) { await loadCatalog() }
    }

    @ViewBuilder private var trailingButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        if busy && !hasContent {
            Button { Task { await model.stop() } } label: {
                Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.C.userText)
                    .frame(width: 36, height: 36).background(DS.C.ink, in: Circle())
            }
            .accessibilityLabel("Stop")
        } else if hasContent {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(DS.C.volt, in: Circle())
            }
            .disabled(!model.isConnected)
            .accessibilityLabel("Send")
        } else {
            Image(systemName: voice.phase == .recording ? "waveform" : "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(voice.phase == .recording ? .white : DS.C.ink2)
                .frame(width: 36, height: 36)
                .background(voice.phase == .recording ? DS.C.bad : Color.clear, in: Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if voice.phase != .recording, model.isConnected {
                                Haptic.tap()
                                Task { await voice.startRecording(model: model) }
                            }
                        }
                        .onEnded { value in
                            if value.translation.width < -80 { voice.cancelRecording() }
                            else { Task { await voice.finishRecording() } }
                        }
                )
                .accessibilityLabel("Hold to talk")
        }
    }

    private var voiceBar: some View {
        HStack(spacing: DS.S.s + 4) {
            switch voice.phase {
            case .recording:
                Circle().fill(DS.C.bad).frame(width: 10, height: 10)
                Text(voice.conversation ? "Listening… pause to send" : "Listening… release to send, slide left to cancel")
                    .font(DS.F.caption).foregroundStyle(DS.C.ink2)
                Spacer()
                LevelBars(level: voice.level)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Turning speech into text on your server…").font(DS.F.caption).foregroundStyle(DS.C.ink2)
                Spacer()
            case .speaking:
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(DS.C.volt)
                Text("Speaking the reply").font(DS.F.caption).foregroundStyle(DS.C.ink2)
                Spacer()
                Button("Stop") { voice.stopSpeaking(); voice.conversation = false }.font(DS.F.captionStrong)
            default:
                EmptyView()
            }
            if voice.conversation {
                Button("End") { voice.cancelRecording(); voice.stopSpeaking() }.font(DS.F.captionStrong).foregroundStyle(DS.C.bad)
            }
        }
        .padding(.horizontal, DS.S.m).padding(.vertical, DS.S.s + 2)
        .background(DS.C.surface, in: Capsule())
        .padding(.horizontal, DS.S.m)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.S.s) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, a in
                    HStack(spacing: DS.S.xs) {
                        if a.isImage, let image = UIImage(data: a.data) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: "doc").foregroundStyle(DS.C.ink2)
                        }
                        Text(a.filename).font(DS.F.caption).foregroundStyle(DS.C.ink).lineLimit(1).frame(maxWidth: 140)
                        Button { attachments.remove(at: index) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.C.ink3) }
                    }
                    .padding(.horizontal, DS.S.s).padding(.vertical, DS.S.xs + 2)
                    .background(DS.C.surface, in: Capsule())
                }
            }
            .padding(.horizontal, DS.S.m)
        }
    }

    private var suggestionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions.prefix(12)) { s in
                    Button {
                        text = s.command + " "
                        suggestions = []
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: DS.S.s + 4) {
                            Text(s.command).font(DS.F.mono).foregroundStyle(DS.C.volt)
                            Text(s.detail).font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DS.S.m).padding(.vertical, DS.S.s + 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DS.C.line).padding(.leading, DS.S.m)
                }
            }
        }
        .frame(maxHeight: 260)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.line, lineWidth: 1))
        .padding(.horizontal, DS.S.m)
    }

    private func send() {
        let message = text
        let files = attachments
        text = ""
        attachments = []
        suggestions = []
        Task { await model.send(message, attachments: files) }
    }

    private func startConversation() {
        guard model.isConnected else { return }
        voice.conversation = true
        model.preferences.speakReplies = true
        Task { await voice.startRecording(model: model) }
    }

    private func updateSuggestions(_ value: String) {
        guard value.hasPrefix("/"), !value.contains(" ") else { suggestions = []; return }
        let query = value.lowercased()
        let local = SlashSuggestion.appCommands + catalog
        suggestions = local.filter { $0.command.lowercased().hasPrefix(query) }
        if suggestions.isEmpty, value.count > 1 {
            Task {
                guard let result = try? await model.engine.call(nil, "complete.slash", ["text": .string(value)]) else { return }
                let items = (result["items"]?.arrayValue ?? []).compactMap { item -> SlashSuggestion? in
                    guard let display = item["display"]?.stringValue ?? item["text"]?.stringValue else { return nil }
                    return SlashSuggestion(command: display.hasPrefix("/") ? display : "/" + display, detail: item["meta"]?.stringValue ?? "")
                }
                if text == value { suggestions = items }
            }
        }
    }

    private func loadCatalog() async {
        guard model.isConnected, let result = try? await model.engine.call(nil, "commands.catalog") else { return }
        catalog = (result["pairs"]?.arrayValue ?? []).compactMap { pair in
            guard let arr = pair.arrayValue, let cmd = arr.first?.stringValue else { return nil }
            return SlashSuggestion(command: cmd, detail: arr.dropFirst().first?.stringValue ?? "")
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let jpeg = UIImage(data: data).flatMap { Self.downscale($0).jpegData(compressionQuality: 0.85) } ?? data
                attachments.append(Attachment(filename: "photo-\(attachments.count + 1).jpg", data: jpeg, isImage: true))
            }
        }
        photoItems = []
    }

    private func addFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        attachments.append(Attachment(filename: url.lastPathComponent, data: data, isImage: isImage))
    }

    static func downscale(_ image: UIImage, max side: CGFloat = 2048) -> UIImage {
        let longest = Swift.max(image.size.width, image.size.height)
        guard longest > side else { return image }
        let scale = side / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

struct SlashSuggestion: Identifiable, Hashable {
    var command: String
    var detail: String
    var id: String { command }

    /// Handled by the app itself (Desktop's local commands).
    static let appCommands: [SlashSuggestion] = [
        .init(command: "/new", detail: "Start a new chat"),
        .init(command: "/btw", detail: "Side question that doesn't change the conversation"),
        .init(command: "/bg", detail: "Run a task in the background; the answer lands here"),
        .init(command: "/stop", detail: "Stop the current turn"),
    ]
}

struct LevelBars: View {
    var level: Double
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(DS.C.bad.opacity(level * 5 > Double(i) ? 1 : 0.2)).frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
    }
}

// MARK: - Model picker

struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [JSONValue] = []
    @State private var loading = true
    @State private var error: String?
    @State private var makeDefault = false
    @State private var search = ""

    var body: some View {
        List {
            Section {
                Toggle("Use as default for new chats", isOn: $makeDefault)
            } footer: {
                Text("Off: only this chat switches. On: Hermes saves it to config (all surfaces, including Telegram).")
            }
            if let error { Section { ErrorBanner(message: error) } }
            ForEach(Array(filtered.enumerated()), id: \.offset) { _, provider in
                let slug = provider["slug"]?.stringValue ?? ""
                Section {
                    ForEach(provider["models"]?.arrayValue?.compactMap(\.stringValue) ?? [], id: \.self) { name in
                        Button {
                            Task {
                                await model.setModel("\(name) --provider \(slug)" + (makeDefault ? " --global" : ""))
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(name).font(DS.F.small).foregroundStyle(DS.C.ink)
                                Spacer()
                                if provider["is_current"]?.boolValue == true, name == currentModel {
                                    Image(systemName: "checkmark").foregroundStyle(DS.C.volt)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(provider["name"]?.stringValue ?? slug)
                        if provider["authenticated"]?.boolValue == false { Text("· not signed in").foregroundStyle(DS.C.ink3) }
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .searchable(text: $search, prompt: "Search models")
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await load() }
    }

    private var currentModel: String? { model.currentChat.flatMap { model.transcripts[$0]?.model } }

    private var filtered: [JSONValue] {
        let authed = providers.filter { $0["authenticated"]?.boolValue != false || $0["is_current"]?.boolValue == true }
        guard !search.isEmpty else { return authed }
        return authed.compactMap { p in
            let models = (p["models"]?.arrayValue ?? []).filter { $0.stringValue?.localizedCaseInsensitiveContains(search) == true }
            guard !models.isEmpty || (p["name"]?.stringValue?.localizedCaseInsensitiveContains(search) ?? false) else { return nil }
            var copy = p.objectValue ?? [:]
            if !models.isEmpty { copy["models"] = .array(models) }
            return .object(copy)
        }
    }

    private func load() async {
        loading = true
        do {
            let result = try await model.engine.call(nil, "model.options", [:], timeout: 60)
            providers = result["providers"]?.arrayValue ?? []
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
