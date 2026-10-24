import SwiftUI
import BrainboxCore

/// The welcome dashboard. Every number and status here comes from the live
/// connection, the server's own report, or what's stored on this device —
/// when something isn't known, the card says so instead of guessing.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabIsActive) private var isActive
    @State private var taskDraft = ""
    @FocusState private var taskFocused: Bool

    private var workspace: HermesWorkspace { model.hermes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BB.Space.xl) {
                    greeting.bbEntrance(index: 0)
                    taskComposer.bbEntrance(index: 1)
                    connectionCard.bbEntrance(index: 1)
                    if !model.chat.pendingApprovals.isEmpty { approvalsCard.bbEntrance(index: 2) }
                    quickActions.bbEntrance(index: 3)
                    if model.isHermes { activityCard.bbEntrance(index: 4) }
                    recentChats.bbEntrance(index: 5)
                    if model.isHermes { serverCard.bbEntrance(index: 6) }
                }
                .padding(.horizontal, BB.Space.gutter)
                .padding(.bottom, BB.Space.xxl)
            }
            .refreshable { await refresh() }
            .bbScreen()
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("home.settings")
                }
            }
            .task(id: "\(isActive)-\(model.connectionState.isConnected)") {
                if isActive { await refresh() }
            }
        }
    }

    private func refresh() async {
        guard model.isHermes, model.connectionState.isConnected else { return }
        await workspace.refreshOverview()
        await workspace.scheduledJobs.refresh()
    }

    // MARK: Greeting

    /// The bot's mood reflects only real state: connection, a running reply,
    /// approvals waiting, parallel agents at work.
    private var botMood: MascotMood {
        guard model.connectionState.isConnected else { return .offline }
        if !model.chat.pendingApprovals.isEmpty { return .waitingApproval }
        if model.chat.isStreaming {
            if case .runningTool = model.agentStatus { return .working }
            return .thinking
        }
        if !model.agents.active.isEmpty || !workspace.activeRuns.isEmpty { return .working }
        return .idle
    }

    private var greeting: some View {
        VStack(spacing: 10) {
            MascotView(style: .brainbox, mood: botMood, size: 132)
                .padding(.top, BB.Space.l)
                .accessibilityIdentifier("home.bot")
            Text(Self.salutation(for: Date()))
                .font(BB.Font.display)
                .foregroundStyle(BB.Palette.textPrimary)
            Text(botMood == .offline ? "Not connected" : botMood.label == "Idle" ? "Ready when you are" : botMood.label)
                .font(BB.Font.subhead)
                .foregroundStyle(BB.Palette.textSecondary)
                .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var taskComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("What should Brainbox do?", text: $taskDraft, axis: .vertical)
                .font(BB.Font.body)
                .lineLimit(1...4)
                .focused($taskFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .accessibilityIdentifier("home.composer")
            Button {
                let text = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                taskDraft = ""
                taskFocused = false
                model.chat.newConversation()
                model.selectedTab = .agent
                Task { _ = await model.chat.submit(text) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(taskDraft.isEmpty ? BB.Palette.textTertiary : BB.Palette.onSignal)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(taskDraft.isEmpty ? BB.Palette.surfaceHigh : BB.Palette.signal))
            }
            .buttonStyle(.pressable)
            .disabled(taskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.chat.isStreaming)
            .padding(5)
            .accessibilityLabel("Start")
            .accessibilityIdentifier("home.start")
        }
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(BB.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(taskFocused ? BB.Palette.strokeStrong : BB.Palette.stroke))
    }

    static func salutation(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }

    // MARK: Connection

    private var connectionCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.settings.providerKind.displayName).font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                    Spacer()
                    StatusPill(tone: model.connectionState.tone, text: model.connectionState.label)
                }
                switch model.settings.providerKind {
                case .mock:
                    Text("Simulated agent for trying the app. Nothing here talks to a server.")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                case .remote:
                    Text("Brainbox gateway protocol connection.")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                case .hermes:
                    hermesDetails
                }
                if let error = model.connectionError {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.warning)
                }
                if !model.connectionState.isConnected {
                    Button { model.showSettings = true } label: {
                        Text(model.isHermes ? "Check connection settings" : "Set up a connection")
                            .font(BB.Font.subhead).foregroundStyle(BB.Palette.signalText)
                    }
                    .buttonStyle(.pressableSubtle)
                }
            }
        }
        .accessibilityIdentifier("home.connection")
    }

    @ViewBuilder
    private var hermesDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hermes = workspace.overview?.hermes {
                detailRow("Hermes", hermes.reachable ? "Responding" + (hermes.latencyMs.map { " · \(Int($0)) ms" } ?? "") : "Not responding",
                          tone: hermes.reachable ? .live : .danger)
            }
            if let info = workspace.gatewayInfo {
                detailRow("Brainbox proxy", "v\(info.version ?? "?")" + (info.deviceName.map { " · \($0)" } ?? ""), tone: .live)
            } else if model.connectionState.isConnected {
                detailRow("Brainbox proxy", "Not in use (direct Hermes connection)", tone: .idle)
            }
            detailRow("Notifications", pushSummary.text, tone: pushSummary.tone)
        }
    }

    private var pushSummary: (text: String, tone: StatusTone) {
        switch model.notifications.permission {
        case .authorized, .provisional, .ephemeral: return ("On (local, from this iPhone)", .live)
        case .denied: return ("Blocked in iOS Settings", .warning)
        case .notDetermined: return ("Not set up", .idle)
        @unknown default: return ("Unknown", .idle)
        }
    }

    private func detailRow(_ title: String, _ value: String, tone: StatusTone) -> some View {
        HStack(spacing: 8) {
            StatusDot(tone: tone, pulsing: false, size: 6)
            Text(title).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            Spacer()
            Text(value).font(BB.Font.caption).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Needs you

    private var approvalsCard: some View {
        Button { model.selectedTab = .tasks } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(BB.Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.chat.pendingApprovals.count) approval\(model.chat.pendingApprovals.count == 1 ? "" : "s") waiting")
                        .font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                    Text("A task is paused until you decide.").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(BB.Palette.textTertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.warning.opacity(0.12)))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("home.approvals")
    }

    // MARK: Quick actions

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            action("New chat", "square.and.pencil", id: "home.newChat") {
                model.chat.newConversation()
                model.selectedTab = .agent
            }
            action("Parallel agents", "square.split.2x2", id: "home.startTask") { model.selectedTab = .team }
            action("Files", "folder", id: "home.files") { model.open(.files) }
            action("Terminal", "terminal", id: "home.terminal") { model.open(.terminal) }
        }
    }

    private func action(_ title: String, _ symbol: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(BB.Palette.signalText)
                Text(title).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier(id)
    }

    // MARK: Activity (runs + scheduled)

    private var nextJob: (job: HermesJob, date: Date)? {
        workspace.scheduledJobs.jobs
            .filter(\.enabled)
            .compactMap { job in job.nextRun.flatMap(HermesDates.parse).map { (job: job, date: $0) } }
            .filter { $0.date > Date().addingTimeInterval(-60) }
            .min { $0.date < $1.date }
    }

    private var activityCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Activity").bbLabelStyle()
                let running = workspace.activeRuns
                if running.isEmpty {
                    Text("No tasks running right now.").font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                } else {
                    ForEach(running.prefix(3)) { run in
                        Button { model.selectedTab = .tasks } label: {
                            HStack {
                                StatusDot(tone: .busy, size: 7)
                                Text(run.title).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                                Spacer()
                                Text(run.state.label).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                            }
                        }
                        .buttonStyle(.pressableSubtle)
                    }
                }
                Divider().overlay(BB.Palette.stroke)
                if let next = nextJob {
                    HStack {
                        Image(systemName: "clock").foregroundStyle(BB.Palette.textTertiary)
                        Text(next.job.name).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                        Spacer()
                        Text(next.date, style: .relative).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Next scheduled task \(next.job.name)")
                } else if let unavailable = workspace.scheduledJobs.unavailable {
                    Text(unavailable).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                } else {
                    Text("No upcoming scheduled tasks.").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
            }
        }
        .accessibilityIdentifier("home.activity")
    }

    // MARK: Recent chats

    private var recentChats: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent chats", trailing: "All") {
                model.selectedTab = .agent
            }
            let recent = model.chat.activeConversations.filter { !$0.messages.isEmpty }.prefix(3)
            if recent.isEmpty {
                BBCard {
                    Text("Your conversations will show up here.").font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(recent)) { conversation in
                        Button {
                            model.chat.select(conversation.id)
                            model.selectedTab = .agent
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(conversation.title).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                                    Spacer()
                                    Text(conversation.updatedAt, style: .relative).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                                }
                                Text(conversation.preview).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(1)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("home.recent")
                    }
                }
            }
        }
    }

    // MARK: Server

    private var serverCard: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Server").bbLabelStyle()
                    Spacer()
                    if let updated = workspace.overviewUpdated {
                        Text(updated, style: .time).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                    }
                }
                if let host = workspace.overview?.host {
                    ServerFactsView(host: host, compact: true)
                } else {
                    Text(workspace.overviewError ?? "Connect to see your server's details.")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
            }
        }
        .onTapGesture { model.selectedTab = .vps }
        .accessibilityIdentifier("home.server")
    }
}

/// Real host facts from /brainbox/system; missing values read "unavailable".
struct ServerFactsView: View {
    let host: BrainboxSystemOverview.Host
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("Host", host.hostname ?? "unavailable")
            if !compact {
                fact("System", [host.os, host.kernel].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "unavailable")
                fact("CPU cores", host.cpuCount.map(String.init) ?? "unavailable")
            }
            fact("Up for", host.uptimeSeconds.map(Self.duration) ?? "unavailable")
            fact("Load (1/5/15 min)", host.loadAverage.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " / ") } ?? "unavailable")
            if let memory = host.memory {
                usage("Memory", memory.usedFraction,
                      "\(ByteCountFormatter.string(fromByteCount: memory.totalBytes - memory.availableBytes, countStyle: .memory)) of \(ByteCountFormatter.string(fromByteCount: memory.totalBytes, countStyle: .memory))")
            } else {
                fact("Memory", "unavailable")
            }
            ForEach(compact ? Array(host.disks.prefix(1)) : host.disks) { disk in
                usage("Disk \(disk.path)", disk.usedFraction,
                      "\(ByteCountFormatter.string(fromByteCount: disk.usedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: disk.totalBytes, countStyle: .file))")
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            Spacer()
            Text(value).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func usage(_ title: String, _ fraction: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fact(title, detail)
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(fraction > 0.9 ? BB.Palette.danger : fraction > 0.75 ? BB.Palette.warning : BB.Palette.signal)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
