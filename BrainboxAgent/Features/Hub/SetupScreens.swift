import BrainboxCore
import HermesKit
import SwiftUI

// MARK: - Messaging platforms

struct MessagingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: String?

    var body: some View {
        RemoteJSON("/api/messaging/platforms") { value, reload in
            let platforms = value["platforms"]?.arrayValue ?? []
            let configured = platforms.filter { $0["configured"]?.boolValue == true || $0["enabled"]?.boolValue == true }
            let others = platforms.filter { !($0["configured"]?.boolValue == true || $0["enabled"]?.boolValue == true) }
            List {
                Section {
                    GatewayStatusCard().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    HStack {
                        Button("Restart gateway") { confirm = "restart" }.buttonStyle(SecondaryButtonStyle(tint: DS.C.warn))
                        Button("Stop") { confirm = "stop" }.buttonStyle(SecondaryButtonStyle(tint: DS.C.bad))
                        Button("Start") { confirm = "start" }.buttonStyle(SecondaryButtonStyle(tint: DS.C.good))
                    }
                } footer: { Text("The gateway is what runs your Telegram bot. Restarting it briefly disconnects every platform.") }
                if !configured.isEmpty {
                    Section("Connected") { ForEach(configured, id: \.self) { platformRow($0, reload: reload) } }
                }
                Section("Available") { ForEach(others, id: \.self) { platformRow($0, reload: reload) } }
            }
            .refreshable { await reload() }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                Button(confirm?.capitalized ?? "OK", role: confirm == "stop" ? .destructive : nil) {
                    let action = confirm ?? ""
                    Task {
                        guard await Biometrics.authenticate(reason: "\(action.capitalized) the Hermes messaging gateway") else { return }
                        _ = await perform(model, "POST", "/api/gateway/\(action)", success: "Gateway \(action) requested")
                        await reload()
                    }
                }
            } message: { Text("This affects your live Telegram bot and every other connected platform.") }
        }
        .navigationTitle("Messaging")
    }

    private var confirmTitle: String {
        switch confirm {
        case "restart": return "Restart the messaging gateway?"
        case "stop": return "Stop the messaging gateway?"
        default: return "Start the messaging gateway?"
        }
    }

    private func platformRow(_ p: JSONValue, reload: @escaping () async -> Void) -> some View {
        NavigationLink {
            PlatformDetail(platform: p, reload: reload)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p["name"]?.stringValue ?? "").font(DS.F.body)
                    Text(p["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(1)
                }
                Spacer()
                let state = p["state"]?.stringValue ?? ""
                Pill(text: state.capitalized, color: state == "connected" || state == "running" ? DS.C.good : state == "error" ? DS.C.bad : DS.C.ink3)
            }
        }
    }
}

struct PlatformDetail: View {
    var platform: JSONValue
    var reload: () async -> Void
    @Environment(AppModel.self) private var model
    @State private var values: [String: String] = [:]
    @State private var enabled = false

    private var id: String { platform["id"]?.stringValue ?? "" }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $enabled)
                if let err = platform["error_message"]?.stringValue { Text(err).font(DS.F.caption).foregroundStyle(DS.C.bad) }
                if let docs = platform["docs_url"]?.stringValue, let url = URL(string: docs) { Link("Setup guide", destination: url) }
            }
            Section {
                ForEach(platform["env_vars"]?.arrayValue ?? [], id: \.self) { env in
                    let key = env["key"]?.stringValue ?? ""
                    VStack(alignment: .leading, spacing: 4) {
                        Text(env["prompt"]?.stringValue ?? key).font(DS.F.small)
                        if env["is_password"]?.boolValue == true {
                            SecureField(env["is_set"]?.boolValue == true ? "•••••• (set — leave blank to keep)" : key, text: binding(key))
                        } else {
                            TextField(env["redacted_value"]?.stringValue ?? key, text: binding(key)).textInputAutocapitalization(.never)
                        }
                        Text(env["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                    }
                }
            } header: { Text("Settings") } footer: { Text("Values are written to ~/.hermes/.env on the server. Secrets are never shown back.") }
            Section {
                Button("Save") { Task { await save() } }
                Button("Send a test") { Task { _ = await perform(model, "POST", "/api/messaging/platforms/\(id)/test", success: "Test sent") } }
            } footer: { Text("Changes take effect when the gateway restarts.") }
        }
        .navigationTitle(platform["name"]?.stringValue ?? "")
        .onAppear { enabled = platform["enabled"]?.boolValue ?? false }
    }

    private func binding(_ key: String) -> Binding<String> { Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }) }

    private func save() async {
        let env = values.filter { !$0.value.isEmpty }.mapValues { JSONValue.string($0) }
        _ = await perform(model, "PUT", "/api/messaging/platforms/\(id)", json: ["enabled": .bool(enabled), "env": .object(env)], success: "Saved")
        values = [:]
        await reload()
    }
}

// MARK: - Webhooks

struct WebhooksScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RemoteJSON("/api/webhooks") { value, reload in
            List {
                Section {
                    Toggle("Webhooks on", isOn: Binding(get: { value["enabled"]?.boolValue ?? false }, set: { on in
                        Task { _ = await perform(model, "POST", "/api/webhooks/enable", json: ["enabled": .bool(on)]); await reload() }
                    }))
                    LabeledContent("Base URL", value: value["base_url"]?.stringValue ?? "")
                } footer: { Text("Let other services start Hermes runs by calling a URL on your server.") }
                Section("Subscriptions") {
                    let subs = value["subscriptions"]?.arrayValue ?? []
                    if subs.isEmpty { Text("None yet. Ask Hermes: \"create a webhook for GitHub pushes\".").foregroundStyle(DS.C.ink3) }
                    ForEach(subs, id: \.self) { sub in
                        let name = sub["name"]?.stringValue ?? ""
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(name).font(DS.F.bodyStrong)
                                Spacer()
                                Toggle("", isOn: Binding(get: { sub["enabled"]?.boolValue ?? true }, set: { on in
                                    Task { _ = await perform(model, "PUT", "/api/webhooks/\(name)/enabled", json: ["enabled": .bool(on)]); await reload() }
                                })).labelsHidden()
                            }
                            if let url = sub["url"]?.stringValue { Text(url).font(DS.F.monoSmall).foregroundStyle(DS.C.ink3).textSelection(.enabled) }
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { _ = await perform(model, "DELETE", "/api/webhooks/\(name)"); await reload() } } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Webhooks")
    }
}

// MARK: - Pairing (who may talk to your bot)

struct PairingScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RemoteJSON("/api/pairing") { value, reload in
            List {
                Section("Waiting for approval") {
                    let pending = value["pending"]?.arrayValue ?? []
                    if pending.isEmpty { Text("Nobody is waiting.").foregroundStyle(DS.C.ink3) }
                    ForEach(pending, id: \.self) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p["user_name"]?.stringValue ?? p["user_id"]?.displayText ?? "Someone").font(DS.F.body)
                                Text("\(p["platform"]?.stringValue ?? "") · code \(p["code"]?.stringValue ?? "")").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                            }
                            Spacer()
                            Button("Approve") {
                                Task {
                                    _ = await perform(model, "POST", "/api/pairing/approve",
                                                      json: ["platform": p["platform"] ?? "", "code": p["code"] ?? "", "request_id": p["request_id"] ?? p["id"] ?? ""],
                                                      success: "Approved")
                                    await reload()
                                }
                            }.buttonStyle(SecondaryButtonStyle(tint: DS.C.good))
                        }
                    }
                }
                Section("Allowed") {
                    ForEach(value["approved"]?.arrayValue ?? [], id: \.self) { a in
                        Text("\(a["user_name"]?.stringValue ?? a["user_id"]?.displayText ?? "") · \(a["platform"]?.stringValue ?? "")")
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        _ = await perform(model, "POST", "/api/pairing/revoke",
                                                          json: ["platform": a["platform"] ?? "", "user_id": .string(a["user_id"]?.displayText ?? "")])
                                        await reload()
                                    }
                                } label: { Label("Revoke", systemImage: "person.badge.minus") }
                            }
                    }
                }
            }
        }
        .navigationTitle("Pairing")
    }
}

// MARK: - Profiles

struct ProfilesScreen: View {
    var body: some View {
        RemoteJSON("/api/profiles") { value, reload in
            List {
                ForEach(value["profiles"]?.arrayValue ?? [], id: \.self) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(p["display_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? p["name"]?.stringValue ?? "").font(DS.F.bodyStrong)
                            if p["is_default"]?.boolValue == true { Pill(text: "Default", color: DS.C.volt) }
                            Spacer()
                            if p["gateway_running"]?.boolValue == true { Pill(text: "Bot online", color: DS.C.good) }
                        }
                        Text("\(p["model"]?.stringValue ?? "") · \(p["provider"]?.stringValue ?? "") · \(p["skill_count"]?.intValue ?? 0) skills")
                            .font(DS.F.caption).foregroundStyle(DS.C.ink3)
                        if let d = p["description"]?.stringValue, !d.isEmpty { Text(d).font(DS.F.caption).foregroundStyle(DS.C.ink2) }
                        Text(p["path"]?.stringValue ?? "").font(DS.F.monoSmall).foregroundStyle(DS.C.ink3)
                    }
                }
                Section { Text("Profiles are separate Hermes setups (own config, memory, bot). Create them with `hermes profile create` in the Terminal.").font(DS.F.caption).foregroundStyle(DS.C.ink3) }
            }
            .refreshable { await reload() }
        }
        .navigationTitle("Profiles")
    }
}

// MARK: - Models

struct ModelsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    var body: some View {
        RemoteJSON("/api/model/info") { info, _ in
            List {
                Section("Main model") {
                    LabeledContent("Model", value: info["model"]?.stringValue ?? "")
                    LabeledContent("Provider", value: info["provider"]?.stringValue ?? "")
                    LabeledContent("Context", value: Fmt.tokens(info["effective_context_length"]?.intValue ?? 0))
                    Button("Change model…") { showPicker = true }
                }
                Section {
                    AuxiliaryModels()
                } header: { Text("Helpers") } footer: { Text("Side tasks (titles, vision, compression, approvals) can use cheaper models. \"auto\" follows the main model.") }
                Section("Reasoning") {
                    ForEach(["low", "medium", "high", "xhigh", "none"], id: \.self) { effort in
                        Button(effort.capitalized) {
                            Task {
                                _ = try? await model.engine.call(model.currentChat, "config.set", ["key": "reasoning", "value": .string(effort)])
                                model.toast = "Reasoning effort: \(effort)"
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) { NavigationStack { ModelPicker() } }
        .navigationTitle("Models")
    }
}

struct AuxiliaryModels: View {
    var body: some View {
        RemoteJSON("/api/model/auxiliary") { value, _ in
            ForEach(value["tasks"]?.arrayValue ?? [], id: \.self) { t in
                LabeledContent(t["task"]?.stringValue?.replacingOccurrences(of: "_", with: " ").capitalized ?? "",
                               value: [t["provider"]?.stringValue, t["model"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            }
        }
    }
}

// MARK: - Usage

struct UsageScreen: View {
    var body: some View {
        RemoteJSON("/api/analytics/usage") { u, reload in
            let daily = u["daily"]?.arrayValue ?? []
            let input = daily.reduce(0) { $0 + ($1["input_tokens"]?.intValue ?? 0) }
            let output = daily.reduce(0) { $0 + ($1["output_tokens"]?.intValue ?? 0) }
            let cost = daily.reduce(0.0) { $0 + ($1["actual_cost"]?.doubleValue ?? $1["estimated_cost"]?.doubleValue ?? 0) }
            let maxDay = max(daily.map { ($0["input_tokens"]?.intValue ?? 0) + ($0["output_tokens"]?.intValue ?? 0) }.max() ?? 1, 1)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.m) {
                    HStack(spacing: DS.S.s + 4) {
                        stat("Tokens in", Fmt.tokens(input))
                        stat("Tokens out", Fmt.tokens(output))
                        stat("Cost", String(format: "$%.2f", cost))
                    }
                    VStack(alignment: .leading, spacing: DS.S.s) {
                        Text("Daily tokens").font(DS.F.smallStrong)
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(Array(daily.suffix(30).enumerated()), id: \.offset) { _, d in
                                let total = (d["input_tokens"]?.intValue ?? 0) + (d["output_tokens"]?.intValue ?? 0)
                                RoundedRectangle(cornerRadius: 3).fill(DS.C.volt)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: max(4, 120 * CGFloat(total) / CGFloat(maxDay)))
                            }
                        }
                        .frame(height: 124, alignment: .bottom)
                    }
                    .card(padding: DS.S.m)
                    VStack(alignment: .leading, spacing: DS.S.s) {
                        Text("By model").font(DS.F.smallStrong)
                        ForEach(u["by_model"]?.arrayValue ?? [], id: \.self) { m in
                            HStack {
                                Text(m["model"]?.stringValue ?? "").font(DS.F.small)
                                Spacer()
                                Text("\(Fmt.tokens((m["input_tokens"]?.intValue ?? 0) + (m["output_tokens"]?.intValue ?? 0))) · \(m["api_calls"]?.intValue ?? 0) calls")
                                    .font(DS.F.caption).foregroundStyle(DS.C.ink3)
                            }
                        }
                    }
                    .card(padding: DS.S.m)
                }
                .padding(DS.S.m)
            }
            .refreshable { await reload() }
        }
        .screenBackground()
        .navigationTitle("Usage")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(DS.F.number).foregroundStyle(DS.C.ink).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(DS.F.caption).foregroundStyle(DS.C.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: DS.S.m)
    }
}

// MARK: - Plugins

struct PluginsScreen: View {
    var body: some View {
        RemoteJSON("/api/dashboard/plugins") { value, reload in
            List {
                ForEach(value.arrayValue ?? [], id: \.self) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p["label"]?.stringValue ?? p["name"]?.stringValue ?? "").font(DS.F.body)
                            Spacer()
                            Text(p["version"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                        }
                        Text(p["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                    }
                }
            }
            .refreshable { await reload() }
        }
        .navigationTitle("Plugins")
    }
}

// MARK: - Code review (git)

struct GitScreen: View {
    @Environment(AppModel.self) private var model
    @State private var repo = ""
    @State private var status: JSONValue?
    @State private var error: String?
    @State private var message = ""
    @State private var diffFile: String?
    @State private var diff = ""

    var body: some View {
        List {
            Section("Repository") {
                TextField("Path on the server", text: $repo).font(DS.F.mono).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await load() } }
                Button("Open") { Task { await load() } }
            }
            if let error { Section { Text(error).foregroundStyle(DS.C.bad).font(DS.F.small) } }
            if let status {
                Section("Branch") {
                    Text(status["branch"]?.stringValue ?? status["head"]?.stringValue ?? "").font(DS.F.mono)
                    if let ahead = status["ahead"]?.intValue, ahead > 0 { Text("\(ahead) commits to push").font(DS.F.caption) }
                }
                Section("Changes") {
                    let files = (status["files"]?.arrayValue ?? status["changes"]?.arrayValue ?? [])
                    if files.isEmpty { Text("Working tree clean").foregroundStyle(DS.C.ink3) }
                    ForEach(files, id: \.self) { f in
                        let path = f["path"]?.stringValue ?? f["file"]?.stringValue ?? f.displayText
                        Button {
                            Task { await showDiff(path) }
                        } label: {
                            HStack {
                                Text(f["status"]?.stringValue ?? "M").font(DS.F.monoSmall).foregroundStyle(DS.C.warn).frame(width: 24)
                                Text(path).font(DS.F.monoSmall).foregroundStyle(DS.C.ink).lineLimit(1)
                            }
                        }
                    }
                }
                Section("Commit") {
                    TextField("Message", text: $message, axis: .vertical)
                    Button("Commit") { Task { await commit(push: false) } }.disabled(message.isEmpty)
                    Button("Commit and push") { Task { await commit(push: true) } }.disabled(message.isEmpty)
                    Button("Ask Hermes to write the message") {
                        Task { await model.send("Look at the uncommitted changes in \(repo) and write a commit message for them."); model.selectedTab = .chat }
                    }
                }
            }
        }
        .navigationTitle("Code review")
        .sheet(item: Binding(get: { diffFile.map { IdentifiedString(id: $0) } }, set: { diffFile = $0?.id })) { item in
            NavigationStack {
                ScrollView { DiffText(diff: diff).padding(DS.S.m) }
                    .navigationTitle((item.id as NSString).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            if repo.isEmpty, let cwd = try? await model.client().get("/api/fs/default-cwd") { repo = cwd["cwd"]?.stringValue ?? "" }
            if !repo.isEmpty { await load() }
        }
    }

    private func load() async {
        do {
            status = try await model.client().get("/api/git/status" + HermesClient.query(["path": repo]))
            error = nil
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
    }

    private func showDiff(_ file: String) async {
        if let r = try? await model.client().get("/api/git/file-diff" + HermesClient.query(["path": repo, "file": file])) {
            diff = r["diff"]?.stringValue ?? r.displayText
            diffFile = file
        }
    }

    private func commit(push: Bool) async {
        if await perform(model, "POST", "/api/git/review/commit", json: ["path": .string(repo), "message": .string(message), "push": .bool(push)],
                         success: push ? "Committed and pushed" : "Committed") != nil {
            message = ""
            await load()
        }
    }
}

// MARK: - Import chats from other agents

struct ImportScreen: View {
    @Environment(AppModel.self) private var model
    @State private var items: [JSONValue] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            Section {
                Text("Hermes can import history from other agents and browsers it finds on the server (Claude Code, Codex, and others).")
                    .font(DS.F.caption).foregroundStyle(DS.C.ink3)
            }
            if let error { Section { Text(error).foregroundStyle(DS.C.bad) } }
            ForEach(items, id: \.self) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s["title"]?.stringValue ?? s["id"]?.stringValue ?? "").font(DS.F.body).lineLimit(2)
                        Text(s["source"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                    }
                    Spacer()
                    Button("Import") {
                        Task {
                            do {
                                _ = try await model.engine.call(nil, "session.foreign.import", ["id": s["id"] ?? ""], timeout: 120)
                                model.toast = "Imported"
                                await model.refreshSessions()
                            } catch { model.toast = error.localizedDescription }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .overlay { if loading { ProgressView() } else if items.isEmpty && error == nil { Text("Nothing to import").foregroundStyle(DS.C.ink3) } }
        .navigationTitle("Import chats")
        .task {
            defer { loading = false }
            do {
                let r = try await model.engine.call(nil, "session.foreign.list", ["limit": 50], timeout: 60)
                items = r["sessions"]?.arrayValue ?? r["items"]?.arrayValue ?? r.arrayValue ?? []
            } catch { self.error = error.localizedDescription }
        }
    }
}
