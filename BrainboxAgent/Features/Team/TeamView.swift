import SwiftUI
import BrainboxCore

/// AI teammates: named personas layered on Hermes, each with an original
/// mascot whose mood follows its real work.
struct TeamView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Teammate?
    @State private var creating = false
    @State private var hopTargets: [UUID: Int] = [:]

    private var workspace: HermesWorkspace { model.hermes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BB.Space.xl) {
                    hero.bbEntrance(index: 0)
                    if !model.isHermes {
                        BBCard {
                            EmptyStateView(systemImage: "bolt.horizontal.circle", title: "Connect Hermes",
                                           message: "Teammates run on your Hermes agent. Add its URL and device token in Settings → Hermes, then tap “Use Hermes as the backend”.")
                        }
                        .bbEntrance(index: 1)
                    }
                    if !model.chat.pendingApprovals.isEmpty {
                        approvalsBanner.bbEntrance(index: 1)
                    }
                    ParallelTasksSection().bbEntrance(index: 2)
                    SectionHeader(title: "Presets", trailing: "New preset") { creating = true }
                    Text("Presets are saved instructions, model and profile choices for your one Hermes agent — not separate agents. Real parallel work runs above.")
                        .font(BB.Font.caption)
                        .foregroundStyle(BB.Palette.textTertiary)
                        .padding(.horizontal, BB.Space.xs)
                    VStack(spacing: 10) {
                        ForEach(Array(workspace.visibleTeammates.enumerated()), id: \.element.id) { index, mate in
                            TeammateCard(teammate: mate, mood: mood(for: mate), isActive: mate.id == workspace.activeTeammateID,
                                         conversationCount: model.chat.conversations(for: mate.id).filter { !$0.messages.isEmpty }.count,
                                         hop: hopTargets[mate.id, default: 0],
                                         onChat: { open(mate) }, onEdit: { editing = mate })
                                .bbEntrance(index: index + 2)
                        }
                    }
                    if !workspace.archivedTeammates.isEmpty {
                        DisclosureGroup("Archived (\(workspace.archivedTeammates.count))") {
                            ForEach(workspace.archivedTeammates) { mate in
                                HStack {
                                    MascotView(style: mate.mascot, mood: .offline, size: 30, seed: mate.id)
                                    Text(mate.name).foregroundStyle(BB.Palette.textSecondary)
                                    Spacer()
                                    Button("Restore") { workspace.setArchived(mate.id, false) }
                                        .foregroundStyle(BB.Palette.signalText)
                                }
                            }
                        }
                        .font(BB.Font.subhead)
                        .tint(BB.Palette.textSecondary)
                    }
                    if model.isHermes {
                        SectionHeader(title: "Hermes")
                        VStack(spacing: 10) {
                            NavigationLink { SessionsBrowserView() } label: {
                                navRow("Sessions", "Every conversation, including Telegram", "tray.full")
                            }
                            .accessibilityIdentifier("team.sessions")
                            NavigationLink { ProfilesView() } label: {
                                navRow("Profiles", "Separate Hermes homes for teammates", "person.crop.rectangle.stack")
                            }
                            NavigationLink { CapabilitiesView() } label: {
                                navRow("Tools & skills", "What this Hermes can do", "wrench.and.screwdriver")
                            }
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, BB.Space.gutter)
                .padding(.bottom, BB.Space.xxl)
            }
            .bbScreen()
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New preset")
                        .accessibilityIdentifier("team.new")
                }
            }
            .sheet(item: $editing) { mate in
                TeammateEditorView(original: mate).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $creating) {
                TeammateEditorView(original: nil).presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack {
            MascotConstellation(
                members: workspace.visibleTeammates.prefix(6).map { MascotConstellation.Member(id: $0.id, style: $0.mascot, mood: mood(for: $0)) },
                radius: 128, mascotSize: 48,
                onTap: { id in if let mate = workspace.teammate(id) { open(mate) } })
            VStack(spacing: 6) {
                Text("Agent workspace").font(BB.Font.display).foregroundStyle(BB.Palette.textPrimary)
                LiveIndicator(state: model.connectionState)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(BB.Palette.background.opacity(0.75)).blur(radius: 12))
        }
        .frame(height: 230)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent workspace")
    }

    private var approvalsBanner: some View {
        Button {
            model.selectedTab = .tasks
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(BB.Palette.warning)
                Text("\(model.chat.pendingApprovals.count) action\(model.chat.pendingApprovals.count == 1 ? "" : "s") waiting for your approval")
                    .font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(BB.Palette.textTertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.warning.opacity(0.12)))
        }
        .buttonStyle(.pressable)
    }

    private func navRow(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(BB.Palette.signalText).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary)
                Text(subtitle).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BB.Palette.textTertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
    }

    // MARK: Helpers

    func mood(for mate: Teammate) -> MascotMood {
        MascotMood.derive(status: model.agentStatus, connected: model.connectionState.isConnected,
                          latest: model.chat.latestReply(for: mate.id),
                          isActiveTeammate: mate.id == workspace.activeTeammateID && model.chat.isStreaming)
    }

    private func open(_ mate: Teammate) {
        model.selectTeammate(mate.id)
        hopTargets[mate.id, default: 0] += 1
        if let existing = model.chat.conversations(for: mate.id).first {
            model.chat.select(existing.id)
        } else {
            model.chat.newConversation()
        }
        withAnimation(Motion.smooth) { model.selectedTab = .agent }
    }
}

struct TeammateCard: View {
    let teammate: Teammate
    let mood: MascotMood
    let isActive: Bool
    let conversationCount: Int
    var hop: Int
    var onChat: () -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            MascotView(style: teammate.mascot, mood: mood, size: 54, seed: teammate.id, hopTrigger: hop)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(teammate.name).font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                    if isActive { Badge(text: "Active", color: BB.Palette.signalText) }
                    if let profile = teammate.profile, !profile.isEmpty, profile != "default" { Badge(text: profile, color: BB.Palette.ion) }
                }
                Text(teammate.role.isEmpty ? "Teammate" : teammate.role.capitalized)
                    .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(mood.label).bbLabelStyle(mood == .waitingApproval ? BB.Palette.warning : (mood == .idle ? BB.Palette.textTertiary : BB.Palette.signalText))
                        .contentTransition(.interpolate)
                    Text("· \(conversationCount) chat\(conversationCount == 1 ? "" : "s")").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
            }
            Spacer()
            Menu {
                Button { onChat() } label: { Label("Chat", systemImage: "bubble.left") }
                Button { onEdit() } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(BB.Palette.textTertiary).frame(width: 36, height: 36)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: BB.Radius.l, style: .continuous).fill(BB.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.l, style: .continuous).strokeBorder(isActive ? BB.Palette.signal.opacity(0.5) : BB.Palette.stroke))
        .bbAuraBorder(mood == .working || mood == .thinking, cornerRadius: BB.Radius.l)
        .contentShape(Rectangle())
        .onTapGesture(perform: onChat)
        .animation(Motion.smooth, value: mood)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("teammate.\(teammate.name)")
    }
}

// MARK: - Editor

struct TeammateEditorView: View {
    let original: Teammate?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Teammate
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var shake = 0

    init(original: Teammate?) {
        self.original = original
        _draft = State(initialValue: original ?? Teammate(name: "", role: "", instructions: "",
                                                           mascot: MascotStyle(shape: MascotShape.allCases.randomElement() ?? .orb, hue: Double.random(in: 0...1))))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        MascotView(style: draft.mascot, mood: .happy, size: 96, seed: draft.id)
                            .animation(Motion.bouncy, value: draft.mascot)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    Picker("Shape", selection: $draft.mascot.shape) {
                        ForEach(MascotShape.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Colour").font(BB.Font.callout)
                        Slider(value: $draft.mascot.hue, in: 0...1)
                            .tint(draft.mascot.color)
                    }
                } header: { Text("Mascot").bbLabelStyle() }

                Section {
                    TextField("Name", text: $draft.name).bbShake(shake).accessibilityIdentifier("editor.name")
                    TextField("Role (e.g. Shopify store manager)", text: $draft.role)
                } header: { Text("Identity").bbLabelStyle() }

                Section {
                    TextEditor(text: $draft.instructions)
                        .frame(minHeight: 120)
                        .font(BB.Font.callout)
                } header: { Text("Instructions").bbLabelStyle() } footer: {
                    Text("Layered on top of Hermes' own system prompt for every message (the `instructions` field of a Hermes run). \(draft.instructions.count)/4000")
                        .font(BB.Font.caption)
                }

                Section {
                    TextField("Model (blank = Hermes default)", text: Binding(get: { draft.model ?? "" }, set: { draft.model = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Provider (optional)", text: Binding(get: { draft.provider ?? "" }, set: { draft.provider = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Hermes profile", selection: Binding(get: { draft.profile ?? "default" }, set: { draft.profile = $0 == "default" ? nil : $0 })) {
                        Text("default").tag("default")
                        ForEach(model.hermes.profiles.filter { $0.name != "default" }) { profile in
                            Text(profile.routable ? profile.name : "\(profile.name) (not routable)").tag(profile.name)
                        }
                        if let current = draft.profile, !model.hermes.profiles.contains(where: { $0.name == current }) {
                            Text(current).tag(current)
                        }
                    }
                } header: { Text("Runtime").bbLabelStyle() } footer: {
                    Text("A Hermes profile gives a teammate its own memory, config, skills and schedules. It is not a sandbox: every profile runs as the same user on the same VPS.")
                        .font(BB.Font.caption)
                }

                Section {
                    Picker("Approvals", selection: $draft.approvalScope) {
                        ForEach(ApprovalScopeLimit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: { Text("Permissions").bbLabelStyle() } footer: {
                    Text("Hermes decides when an action needs approval. This only limits which of Hermes' choices you'll be offered — the app never approves anything on its own.")
                        .font(BB.Font.caption)
                }

                if let error {
                    Text(error).foregroundStyle(BB.Palette.danger).font(BB.Font.caption)
                }

                if let original, original.id != Teammate.mainAssistantID {
                    Section {
                        Button(original.isArchived ? "Restore" : "Archive") {
                            model.hermes.setArchived(original.id, !original.isArchived)
                            dismiss()
                        }
                        Button("Delete teammate", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deleting removes the teammate from this app. Its Hermes sessions stay on the server.").font(BB.Font.caption)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BB.Palette.backgroundRaised)
            .navigationTitle(original == nil ? "New teammate" : "Edit teammate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold).accessibilityIdentifier("editor.save")
                }
            }
            .confirmationDialog("Delete \(original?.name ?? "teammate")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let original { model.hermes.delete(original.id) }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        do {
            try model.hermes.save(draft)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            shake += 1
        }
    }
}

// MARK: - Profiles

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var description = ""
    @State private var clone = true
    @State private var working = false
    @State private var error: AgentError?
    @State private var created: String?

    var body: some View {
        List {
            Section {
                if model.hermes.gatewayInfo == nil {
                    Text("Profile listing needs the Brainbox Hermes proxy. Direct connections can't list profiles.")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
                ForEach(model.hermes.profiles) { profile in
                    HStack {
                        Image(systemName: "person.crop.square").foregroundStyle(BB.Palette.signalText)
                        Text(profile.name).font(BB.Font.mono)
                        Spacer()
                        Text(profile.routable ? "Routable" : (profile.hasAPIKey ? "Routing off" : "No API key"))
                            .bbLabelStyle(profile.routable ? BB.Palette.success : BB.Palette.textTertiary)
                    }
                }
            } header: { Text("Profiles on the VPS").bbLabelStyle() } footer: {
                Text("A teammate can use a profile once Hermes serves it (gateway.multiplex_profiles) and the profile has its own API_SERVER_KEY. Profiles separate memory, config, sessions and skills — not the filesystem or browser.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            if model.hermes.canCreateProfiles {
                Section {
                    TextField("name (lowercase, e.g. research)", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(BB.Font.mono)
                    TextField("Description (optional)", text: $description)
                    Toggle("Copy config & skills from default", isOn: $clone).tint(BB.Palette.signal)
                    Button(working ? "Creating…" : "Create profile") { Task { await create() } }
                        .disabled(working || !HermesConfiguration.isValidProfileName(name))
                        .foregroundStyle(BB.Palette.signalText)
                    if let error { ErrorBanner(error: error, dismiss: { self.error = nil }) }
                    if let created { Label("Created \(created)", systemImage: "checkmark.circle.fill").foregroundStyle(BB.Palette.success) }
                } header: { Text("New profile").bbLabelStyle() } footer: {
                    Text("Runs `hermes profile create <name>` on the server through the proxy's restricted admin action. You'll confirm with \(model.gate.biometryName). This device must be marked admin in the proxy config.")
                        .font(BB.Font.caption)
                }
                .listRowBackground(BB.Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Profiles")
        .refreshable { await model.hermes.reloadProfiles() }
        .task { await model.hermes.reloadProfiles() }
    }

    private func create() async {
        guard await model.gate.authorize(.changeAgentConfiguration) else { return }
        working = true
        defer { working = false }
        do {
            try await model.hermes.createProfile(name: name, description: description.isEmpty ? nil : description, clone: clone)
            created = name
            name = ""
            description = ""
        } catch {
            self.error = error.asAgentError
        }
    }
}

// MARK: - Capabilities

struct CapabilitiesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(HermesCompatibilityReport.Feature.allCases, id: \.self) { feature in
                    HStack {
                        Text(feature.title).font(BB.Font.callout)
                        Spacer()
                        Image(systemName: model.hermes.report?.supports(feature) == true ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(model.hermes.report?.supports(feature) == true ? BB.Palette.success : BB.Palette.textTertiary)
                    }
                }
                if let problems = model.hermes.report?.problems, !problems.isEmpty {
                    ForEach(problems, id: \.self) { Text($0).font(BB.Font.caption).foregroundStyle(BB.Palette.warning) }
                }
            } header: { Text("Server features").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)

            Section {
                if model.hermes.toolsets.isEmpty { Text("No toolsets reported.").foregroundStyle(BB.Palette.textTertiary) }
                ForEach(model.hermes.toolsets) { toolset in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(toolset.label ?? toolset.name).font(BB.Font.callout.weight(.medium))
                            Spacer()
                            Text(toolset.enabled ? (toolset.configured ? "On" : "Needs keys") : "Off")
                                .bbLabelStyle(toolset.enabled && toolset.configured ? BB.Palette.success : BB.Palette.textTertiary)
                        }
                        if !toolset.tools.isEmpty {
                            Text(toolset.tools.joined(separator: ", ")).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).lineLimit(2)
                        }
                    }
                }
            } header: { Text("Toolsets (read-only)").bbLabelStyle() } footer: {
                Text("Toolsets are configured per Hermes profile on the server; a run can't change them, so the app shows them read-only.").font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                if model.hermes.skills.isEmpty { Text("No skills reported.").foregroundStyle(BB.Palette.textTertiary) }
                ForEach(model.hermes.skills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(BB.Font.mono)
                        if let d = skill.description { Text(d).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(2) }
                    }
                }
            } header: { Text("Skills").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Tools & skills")
    }
}
