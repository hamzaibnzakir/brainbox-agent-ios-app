import BrainboxCore
import HermesKit
import SwiftUI

// MARK: - Skills

struct SkillsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var overrides: [String: Bool] = [:]

    var body: some View {
        RemoteJSON("/api/skills") { value, reload in
            let skills = (value.arrayValue ?? []).filter { s in
                search.isEmpty || (s["name"]?.stringValue ?? "").localizedCaseInsensitiveContains(search)
                    || (s["description"]?.stringValue ?? "").localizedCaseInsensitiveContains(search)
            }
            let categories = Array(Set(skills.compactMap { $0["category"]?.stringValue })).sorted()
            List {
                Section {
                    Text("\(value.arrayValue?.count ?? 0) skills installed. Turning one off hides it from Hermes on every surface.")
                        .font(DS.F.caption).foregroundStyle(DS.C.ink3)
                }
                ForEach(categories, id: \.self) { category in
                    Section(category.replacingOccurrences(of: "-", with: " ").capitalized) {
                        ForEach(skills.filter { $0["category"]?.stringValue == category }, id: \.self) { skill in
                            skillRow(skill)
                        }
                    }
                }
            }
            .refreshable { await reload() }
        }
        .searchable(text: $search, prompt: "Search skills")
        .navigationTitle("Skills")
    }

    private func skillRow(_ skill: JSONValue) -> some View {
        let name = skill["name"]?.stringValue ?? ""
        let enabled = overrides[name] ?? skill["enabled"]?.boolValue ?? true
        return HStack(alignment: .top) {
            NavigationLink {
                SkillDetail(name: name)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(DS.F.body)
                    Text(skill["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(2)
                }
            }
            Toggle("", isOn: Binding(get: { enabled }, set: { on in
                overrides[name] = on
                Task {
                    if await perform(model, "PUT", "/api/skills/toggle", json: ["name": .string(name), "enabled": .bool(on)]) == nil { overrides[name] = !on }
                }
            }))
            .labelsHidden()
        }
    }
}

struct SkillDetail: View {
    var name: String
    var body: some View {
        RemoteJSON("/api/skills/content" + HermesClient.query(["name": name])) { value, _ in
            ScrollView { MarkdownText(text: value["content"]?.stringValue ?? "").padding(DS.S.m) }
        }
        .screenBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Toolsets

struct ToolsetsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var overrides: [String: Bool] = [:]

    var body: some View {
        RemoteJSON("/api/tools/toolsets") { value, reload in
            List {
                Section {
                    Text("Which tool groups Hermes can use. These are Hermes' CLI/app toolsets; Telegram has its own list on the server.")
                        .font(DS.F.caption).foregroundStyle(DS.C.ink3)
                }
                ForEach(value.arrayValue ?? [], id: \.self) { toolset in
                    let name = toolset["name"]?.stringValue ?? ""
                    let on = overrides[name] ?? toolset["enabled"]?.boolValue ?? false
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { on }, set: { new in
                            overrides[name] = new
                            Task {
                                if await perform(model, "PUT", "/api/tools/toolsets/\(name)", json: ["enabled": .bool(new)]) == nil { overrides[name] = !new }
                            }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(toolset["label"]?.stringValue ?? name).font(DS.F.body)
                                Text(toolset["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                            }
                        }
                        if toolset["available"]?.boolValue == false || toolset["configured"]?.boolValue == false {
                            Text(toolset["available"]?.boolValue == false ? "Not available on this server" : "Needs setup (keys) on the server")
                                .font(DS.F.caption).foregroundStyle(DS.C.warn)
                        }
                    }
                }
            }
            .refreshable { await reload() }
        }
        .navigationTitle("Tools")
    }
}

// MARK: - MCP

struct MCPScreen: View {
    @Environment(AppModel.self) private var model
    @State private var testing: String?

    var body: some View {
        RemoteJSON("/api/mcp/servers") { value, reload in
            let servers = value["servers"]?.arrayValue ?? []
            List {
                if servers.isEmpty {
                    EmptyState(symbol: "puzzlepiece.extension", title: "No MCP servers",
                               message: "Ask Hermes to add one (for example \"add the GitHub MCP server\") or install from the catalog on Desktop.")
                        .listRowBackground(Color.clear)
                }
                ForEach(servers, id: \.self) { server in
                    let name = server["name"]?.stringValue ?? ""
                    VStack(alignment: .leading, spacing: DS.S.s) {
                        HStack {
                            Text(name).font(DS.F.bodyStrong)
                            Spacer()
                            Toggle("", isOn: Binding(get: { server["enabled"]?.boolValue ?? true }, set: { on in
                                Task { _ = await perform(model, "PUT", "/api/mcp/servers/\(name)/enabled", json: ["enabled": .bool(on)]); await reload() }
                            })).labelsHidden()
                        }
                        Text(server["url"]?.stringValue ?? server["command"]?.stringValue ?? "").font(DS.F.monoSmall).foregroundStyle(DS.C.ink3).lineLimit(2)
                        if let tools = server["tools"]?.arrayValue { Text("\(tools.count) tools").font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                        HStack {
                            Button(testing == name ? "Testing…" : "Test") {
                                Task {
                                    testing = name
                                    if let r = await perform(model, "POST", "/api/mcp/servers/\(name)/test") {
                                        model.toast = r["ok"]?.boolValue == false ? (r["error"]?.stringValue ?? "Test failed") : "\(name) answered"
                                    }
                                    testing = nil
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Spacer()
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { _ = await perform(model, "DELETE", "/api/mcp/servers/\(name)", success: "Removed \(name)"); await reload() }
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }
            .refreshable { await reload() }
        }
        .navigationTitle("MCP servers")
    }
}

// MARK: - Memory

struct MemoryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        RemoteJSON("/api/memory") { value, reload in
            List {
                Section("Provider") {
                    let active = value["active"]?.stringValue ?? ""
                    Picker("Memory provider", selection: Binding(get: { active.isEmpty ? "built-in" : active }, set: { new in
                        Task { _ = await perform(model, "PUT", "/api/memory/provider", json: ["provider": .string(new)], success: "Memory provider set"); await reload() }
                    })) {
                        Text("Built-in").tag("built-in")
                        ForEach(value["providers"]?.arrayValue ?? [], id: \.self) { p in
                            Text(p["name"]?.stringValue ?? "").tag(p["name"]?.stringValue ?? "")
                        }
                    }
                }
                Section("Available") {
                    ForEach(value["providers"]?.arrayValue ?? [], id: \.self) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p["name"]?.stringValue ?? "").font(DS.F.body)
                                Spacer()
                                Pill(text: p["status"]?.stringValue ?? "", color: p["available"]?.boolValue == true ? DS.C.good : DS.C.ink3)
                            }
                            Text(p["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                        }
                    }
                }
                Section {
                    NavigationLink("Browse memory files") { FilesScreen(path: nil) }
                    Button("Reset memory…", role: .destructive) { confirmReset = true }
                }
            }
            .confirmationDialog("Erase Hermes' memory?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Erase memory notes", role: .destructive) { Task { _ = await perform(model, "POST", "/api/memory/reset", json: ["target": "memory"], success: "Memory notes cleared") } }
                Button("Erase what it knows about you", role: .destructive) { Task { _ = await perform(model, "POST", "/api/memory/reset", json: ["target": "user"], success: "User profile cleared") } }
            } message: { Text("This affects every surface, including Telegram. It can't be undone.") }
        }
        .navigationTitle("Memory")
    }
}

// MARK: - Star map (what Hermes has learned)

struct StarMapScreen: View {
    @State private var selected: JSONValue?

    var body: some View {
        RemoteJSON("/api/learning/graph") { graph, reload in
            let nodes = graph["nodes"]?.arrayValue ?? []
            let edges = graph["edges"]?.arrayValue ?? []
            if nodes.isEmpty {
                EmptyState(symbol: "sparkles", title: "Nothing mapped yet",
                           message: "As Hermes learns skills and memories, they appear here as a constellation.")
            } else {
                VStack(spacing: 0) {
                    StarMapCanvas(nodes: nodes, edges: edges, selected: $selected)
                        .frame(maxHeight: .infinity)
                    if let selected {
                        VStack(alignment: .leading, spacing: DS.S.xs) {
                            Text(selected["label"]?.stringValue ?? selected["name"]?.stringValue ?? selected["id"]?.stringValue ?? "")
                                .font(DS.F.bodyStrong)
                            Text(selected["description"]?.stringValue ?? selected["category"]?.stringValue ?? "")
                                .font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: DS.S.m)
                        .padding(DS.S.m)
                    }
                    let stats = graph["stats"]
                    Text("\(stats?["nodes"]?.intValue ?? nodes.count) stars · \(stats?["learned_skills"]?.intValue ?? 0) learned skills · \(stats?["memory_nodes"]?.intValue ?? 0) memories")
                        .font(DS.F.caption).foregroundStyle(DS.C.ink3).padding(.bottom, DS.S.m)
                }
            }
        }
        .background(Color(hex: 0x07080C).ignoresSafeArea())
        .navigationTitle("Star map")
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct StarMapCanvas: View {
    var nodes: [JSONValue]
    var edges: [JSONValue]
    @Binding var selected: JSONValue?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    /// Stable pseudo-random layout seeded by node id, clustered by category.
    private func position(_ node: JSONValue, in size: CGSize) -> CGPoint {
        if let x = node["x"]?.doubleValue, let y = node["y"]?.doubleValue {
            return CGPoint(x: size.width / 2 + x * Double(size.width) * 0.45, y: size.height / 2 + y * Double(size.height) * 0.45)
        }
        let id = node["id"]?.displayText ?? ""
        let cat = node["category"]?.stringValue ?? ""
        let h1 = Double(abs(id.hashValue % 10_000)) / 10_000
        let h2 = Double(abs(cat.hashValue % 10_000)) / 10_000
        let angle = h2 * .pi * 2 + h1 * 0.9
        let radius = 0.15 + h1 * 0.33
        return CGPoint(x: size.width / 2 + cos(angle) * radius * size.width, y: size.height / 2 + sin(angle) * radius * size.height)
    }

    var body: some View {
        GeometryReader { geo in
            let s = scale * pinch
            let o = CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
            let points = Dictionary(nodes.map { ($0["id"]?.displayText ?? UUID().uuidString, position($0, in: geo.size)) }, uniquingKeysWith: { a, _ in a })
            Canvas { ctx, _ in
                ctx.translateBy(x: o.width + geo.size.width / 2 * (1 - s), y: o.height + geo.size.height / 2 * (1 - s))
                ctx.scaleBy(x: s, y: s)
                for edge in edges {
                    guard let a = points[edge["source"]?.displayText ?? ""], let b = points[edge["target"]?.displayText ?? ""] else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    ctx.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.6 / s)
                }
                for node in nodes {
                    guard let p = points[node["id"]?.displayText ?? ""] else { continue }
                    let r = 2.5 + min(Double(node["usage"]?.intValue ?? node["weight"]?.intValue ?? 0), 20) * 0.25
                    let isSel = selected?["id"] == node["id"]
                    let color: Color = node["kind"]?.stringValue == "memory" || node["type"]?.stringValue == "memory" ? Color(hex: 0x7DD3FC) : Color(hex: 0xC4B5FD)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)), with: .color(color.opacity(0.08)))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(isSel ? .white : color))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().updating($drag) { v, state, _ in state = v.translation }
                .onEnded { v in offset.width += v.translation.width; offset.height += v.translation.height })
            .simultaneousGesture(MagnificationGesture().updating($pinch) { v, state, _ in state = v }.onEnded { v in scale = min(max(scale * v, 0.5), 6) })
            .onTapGesture { location in
                // Map the tap back into graph space and pick the nearest star.
                let gx = (location.x - o.width - geo.size.width / 2 * (1 - s)) / s
                let gy = (location.y - o.height - geo.size.height / 2 * (1 - s)) / s
                let nearest = nodes.min { a, b in
                    let pa = points[a["id"]?.displayText ?? ""] ?? .zero, pb = points[b["id"]?.displayText ?? ""] ?? .zero
                    return hypot(pa.x - gx, pa.y - gy) < hypot(pb.x - gx, pb.y - gy)
                }
                selected = nearest
                Haptic.tap()
            }
        }
    }
}

// MARK: - Curator

struct CuratorScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RemoteJSON("/api/curator") { c, reload in
            List {
                Section {
                    LabeledContent("Enabled", value: c["enabled"]?.boolValue == true ? "Yes" : "No")
                    LabeledContent("Runs every", value: "\(c["interval_hours"]?.intValue ?? 0) h")
                    LabeledContent("Last run", value: c["last_run_at"]?.stringValue ?? "never")
                    LabeledContent("Marks stale after", value: "\(c["stale_after_days"]?.intValue ?? 0) days")
                    Toggle("Paused", isOn: Binding(get: { c["paused"]?.boolValue ?? false }, set: { on in
                        Task { _ = await perform(model, "PUT", "/api/curator/paused", json: ["paused": .bool(on)]); await reload() }
                    }))
                } footer: { Text("The curator tidies Hermes' skills: merges duplicates, archives ones you never use.") }
                Section {
                    Button("Run curator now") { Task { _ = await perform(model, "POST", "/api/curator/run", success: "Curator started"); await reload() } }
                }
            }
        }
        .navigationTitle("Curator")
    }
}

// MARK: - Persona (SOUL.md + personality)

extension SoulScreen {
    nonisolated static func names(in message: String) -> [String] {
        guard let range = message.range(of: "Available:") else { return [] }
        return message[range.upperBound...].components(separatedBy: "`").enumerated().compactMap { $0.offset % 2 == 1 ? $0.element : nil }
    }
}

struct SoulScreen: View {
    @Environment(AppModel.self) private var model
    @State private var personality = "none"
    @State private var available = ["none"]

    var body: some View {
        RemoteJSON("/api/profiles/default/soul") { soul, _ in
            List {
                Section {
                    Picker("Personality", selection: Binding(get: { personality }, set: { new in
                        personality = new
                        Task {
                            if let chat = model.currentChat {
                                _ = try? await model.engine.call(chat, "config.set", ["key": "personality", "value": .string(new)])
                            } else {
                                _ = try? await model.engine.call(nil, "config.set", ["key": "personality", "value": .string(new)])
                            }
                            model.toast = "Personality: \(new)"
                        }
                    })) {
                        ForEach(available, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                } footer: { Text("Hermes' built-in personality overlays. \"None\" uses SOUL.md alone.") }
                Section("SOUL.md") {
                    NavigationLink {
                        FileViewer(path: soul["path"]?.stringValue ?? "~/.hermes/SOUL.md")
                    } label: {
                        Text(soul["content"]?.stringValue ?? "").font(DS.F.small).foregroundStyle(DS.C.ink2).lineLimit(12)
                    }
                }
            }
        }
        .navigationTitle("Persona")
        .task {
            if let v = try? await model.engine.call(nil, "config.get", ["key": "personality"]) { personality = v["value"]?.stringValue ?? "none" }
            // Hermes lists the valid names when asked for an unknown one.
            do {
                _ = try await model.engine.call(nil, "config.set", ["key": "personality", "value": "__brainbox_list__"])
            } catch {
                let names = Self.names(in: error.localizedDescription).filter { $0 != "__brainbox_list__" }
                if !names.isEmpty { available = Array(Set(names + [personality])).sorted() }
            }
        }
    }
}
