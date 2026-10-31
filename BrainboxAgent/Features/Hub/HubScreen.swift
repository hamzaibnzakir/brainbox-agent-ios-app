import BrainboxCore
import HermesKit
import SwiftUI

/// Everything Hermes Desktop can manage, as colour-coded cards.
struct HubScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    enum Destination: String, Hashable, CaseIterable, Identifiable {
        case terminal, files, system, logs
        case skills, tools, mcp, memory, starmap, curator, soul
        case messaging, webhooks, pairing
        case profiles, models, usage, plugins
        case updates, git, importer, backups
        var id: String { rawValue }

        var title: String {
            switch self {
            case .terminal: return "Terminal"
            case .files: return "Files"
            case .system: return "Server health"
            case .logs: return "Logs"
            case .skills: return "Skills"
            case .tools: return "Tools"
            case .mcp: return "MCP servers"
            case .memory: return "Memory"
            case .starmap: return "Star map"
            case .curator: return "Curator"
            case .soul: return "Persona"
            case .messaging: return "Messaging"
            case .webhooks: return "Webhooks"
            case .pairing: return "Pairing"
            case .profiles: return "Profiles"
            case .models: return "Models"
            case .usage: return "Usage"
            case .plugins: return "Plugins"
            case .updates: return "Updates & doctor"
            case .git: return "Code review"
            case .importer: return "Import chats"
            case .backups: return "Backups"
            }
        }

        var subtitle: String {
            switch self {
            case .terminal: return "A shell on the server"
            case .files: return "Browse, read, edit"
            case .system: return "CPU, memory, disk"
            case .logs: return "Hermes and gateway logs"
            case .skills: return "Turn skills on or off"
            case .tools: return "Toolsets per platform"
            case .mcp: return "Connected MCP tools"
            case .memory: return "Long-term memory"
            case .starmap: return "What Hermes has learned"
            case .curator: return "Skill upkeep"
            case .soul: return "SOUL.md and personality"
            case .messaging: return "Telegram, WhatsApp, more"
            case .webhooks: return "Triggers from outside"
            case .pairing: return "Approve new chat users"
            case .profiles: return "Separate Hermes setups"
            case .models: return "Providers and auxiliaries"
            case .usage: return "Tokens and cost"
            case .plugins: return "Dashboard and agent plugins"
            case .updates: return "Version, doctor, audit"
            case .git: return "Diffs, commits, PRs"
            case .importer: return "From other agents"
            case .backups: return "Back up ~/.hermes"
            }
        }

        var symbol: String {
            switch self {
            case .terminal: return "terminal.fill"
            case .files: return "folder.fill"
            case .system: return "gauge.with.dots.needle.67percent"
            case .logs: return "doc.text.magnifyingglass"
            case .skills: return "sparkles"
            case .tools: return "wrench.and.screwdriver.fill"
            case .mcp: return "puzzlepiece.extension.fill"
            case .memory: return "brain.head.profile"
            case .starmap: return "sparkle.magnifyingglass"
            case .curator: return "leaf.fill"
            case .soul: return "theatermasks.fill"
            case .messaging: return "paperplane.fill"
            case .webhooks: return "link"
            case .pairing: return "person.badge.key.fill"
            case .profiles: return "person.2.fill"
            case .models: return "cpu.fill"
            case .usage: return "chart.bar.fill"
            case .plugins: return "shippingbox.fill"
            case .updates: return "arrow.down.circle.fill"
            case .git: return "arrow.triangle.branch"
            case .importer: return "square.and.arrow.down.fill"
            case .backups: return "externaldrive.fill"
            }
        }
    }

    struct HubSection: Identifiable {
        var id: String
        var items: [Destination]
    }

    static let sections: [HubSection] = [
        HubSection(id: "Server", items: [.terminal, .files, .system, .logs]),
        HubSection(id: "Agent", items: [.skills, .tools, .mcp, .memory, .starmap, .soul, .curator]),
        HubSection(id: "Channels", items: [.messaging, .webhooks, .pairing]),
        HubSection(id: "Setup", items: [.models, .profiles, .usage, .plugins]),
        HubSection(id: "Maintenance", items: [.updates, .git, .backups, .importer]),
    ]

    private let columns = [GridItem(.flexible(), spacing: DS.S.s + 4), GridItem(.flexible(), spacing: DS.S.s + 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.S.l) {
                ConnectionBanner()
                serverCard
                ForEach(Self.sections) { section in
                    VStack(alignment: .leading, spacing: DS.S.s + 4) {
                        SectionTitle(text: section.id)
                        LazyVGrid(columns: columns, spacing: DS.S.s + 4) {
                            ForEach(Array(section.items.enumerated()), id: \.element) { index, item in
                                NavigationLink(value: item) { tile(item, index: index + section.id.count) }
                                    .buttonStyle(.plain)
                                    .disabled(!model.isConnected)
                            }
                        }
                    }
                }
            }
            .padding(DS.S.m)
        }
        .screenBackground()
        .navigationTitle("Hub")
        .navigationDestination(for: Destination.self) { destination(for: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }.accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsScreen() } }
    }

    private var serverCard: some View {
        HStack(spacing: DS.S.m) {
            Companion(mood: model.isConnected ? .idle : .failed, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.profile?.name ?? "Server").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
                Text(model.profile?.target.display ?? "").font(DS.F.monoSmall).foregroundStyle(DS.C.ink3)
                HStack(spacing: DS.S.s) {
                    ConnectionBadge()
                    if let v = model.serverInfo?.version { Pill(text: "Hermes \(v)", color: DS.C.volt) }
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: DS.S.m)
    }

    private func tile(_ d: Destination, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.S.s + 4) {
            IconTile(symbol: d.symbol, index: index, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(DS.F.smallStrong).foregroundStyle(DS.C.ink).lineLimit(1)
                Text(d.subtitle).font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(2, reservesSpace: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: DS.S.m)
        .opacity(model.isConnected ? 1 : 0.5)
    }

    @ViewBuilder
    private func destination(for d: Destination) -> some View {
        switch d {
        case .terminal: TerminalScreen()
        case .files: FilesScreen(path: nil)
        case .system: SystemScreen()
        case .logs: LogsScreen()
        case .skills: SkillsScreen()
        case .tools: ToolsetsScreen()
        case .mcp: MCPScreen()
        case .memory: MemoryScreen()
        case .starmap: StarMapScreen()
        case .curator: CuratorScreen()
        case .soul: SoulScreen()
        case .messaging: MessagingScreen()
        case .webhooks: WebhooksScreen()
        case .pairing: PairingScreen()
        case .profiles: ProfilesScreen()
        case .models: ModelsScreen()
        case .usage: UsageScreen()
        case .plugins: PluginsScreen()
        case .updates: UpdatesScreen()
        case .git: GitScreen()
        case .importer: ImportScreen()
        case .backups: BackupScreen()
        }
    }
}

// MARK: - Shared loader

/// Loads JSON from Hermes' REST API and renders it, with loading/error/refresh.
struct RemoteJSON<Content: View>: View {
    var path: String
    var content: (JSONValue, @escaping () async -> Void) -> Content
    @Environment(AppModel.self) private var model
    @State private var value: JSONValue?
    @State private var error: String?

    init(_ path: String, @ViewBuilder content: @escaping (JSONValue, @escaping () async -> Void) -> Content) {
        self.path = path
        self.content = content
    }

    var body: some View {
        Group {
            if let value {
                content(value, { await load() })
            } else if let error {
                VStack { ErrorBanner(message: error) { Task { await load() } } }.padding(DS.S.m)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        do {
            value = try await model.client().get(path, timeout: 90)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Runs a REST call and reports the result as a toast.
@MainActor
func perform(_ model: AppModel, _ method: String, _ path: String, json: JSONValue? = nil, success: String? = nil) async -> JSONValue? {
    do {
        let result = try await model.client().send(method, path, json: json, timeout: 180)
        if let success { model.toast = success; Haptic.success() }
        return result
    } catch {
        model.toast = error.localizedDescription
        Haptic.error()
        return nil
    }
}

/// Pretty JSON for anything without a dedicated view.
struct JSONInspector: View {
    var value: JSONValue
    var body: some View {
        ScrollView {
            Text(value.displayText).font(DS.F.monoSmall).foregroundStyle(DS.C.ink2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(DS.S.m)
        }
    }
}
