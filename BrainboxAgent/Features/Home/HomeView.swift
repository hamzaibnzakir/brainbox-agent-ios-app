import SwiftUI
import BrainboxCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var metrics: ServerMetrics?
    @State private var info: ServerInfo?
    @State private var cpuHistory: [Double] = []
    @State private var serverError: AgentError?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BB.Space.xl) {
                    hero.bbEntrance(index: 0)
                    backendCard.bbEntrance(index: 1)
                    serverCard.bbEntrance(index: 2)
                    quickActions.bbEntrance(index: 3)
                    recentConversations.bbEntrance(index: 4)
                    recentTasks.bbEntrance(index: 5)
                }
                .padding(.horizontal, BB.Space.gutter)
                .padding(.top, BB.Space.s)
                .padding(.bottom, BB.Space.xxl)
            }
            .refreshable { await refreshServer() }
            .bbScreen()
            .toolbar(.hidden, for: .navigationBar)
            .task(id: model.settings.providerKind) { await streamServer() }
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: BB.Space.l) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Brainbox Agent").bbLabelStyle(BB.Palette.signalText)
                Text(greeting)
                    .font(BB.Font.display)
                    .foregroundStyle(BB.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    StatusPill(tone: model.agentStatus.tone, text: model.agentStatus.label)
                    StatusPill(tone: model.connectionState.tone, text: model.connectionState.label)
                }
            }
            Spacer(minLength: 0)
            AgentOrb(mode: OrbMode(status: model.agentStatus, connection: model.connectionState), size: 92)
                .onTapGesture { withAnimation(Motion.standard) { model.selectedTab = .agent } }
                .accessibilityAddTraits(.isButton)
        }
        .padding(.top, BB.Space.l)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Late night ops"
        }
    }

    // MARK: Backend

    private var backendCard: some View {
        BBCard {
            HStack(spacing: BB.Space.m) {
                Image(systemName: model.isMock ? "testtube.2" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BB.Palette.signalText)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BB.Palette.surfaceHigh))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected agent").bbLabelStyle()
                    HStack(spacing: 6) {
                        Text(model.agentDescriptor.name).font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                        if model.isMock { Badge(text: "Mock") }
                        if model.settings.providerKind == .hermes { Badge(text: "Pending", color: BB.Palette.ion) }
                    }
                    Text(model.agentDescriptor.summary).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(Motion.standard) { model.selectedTab = .settings }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(BB.Palette.textTertiary)
                }
                .buttonStyle(.pressableSubtle)
                .accessibilityLabel("Connection settings")
            }
            if let error = model.connectionError {
                ErrorBanner(error: error, retry: { model.reconnect() })
                    .padding(.top, BB.Space.m)
                    .transition(.bbRise)
            }
        }
        .animation(Motion.standard, value: model.connectionError)
    }

    // MARK: Server

    @ViewBuilder
    private var serverCard: some View {
        VStack(alignment: .leading, spacing: BB.Space.s) {
            SectionHeader(title: "Server", trailing: "Open", action: { withAnimation(Motion.standard) { model.selectedTab = .vps } })
            BBCard {
                if let metrics {
                    VStack(alignment: .leading, spacing: BB.Space.m) {
                        HStack {
                            StatusDot(tone: metrics.health == .healthy ? .live : (metrics.health == .degraded ? .warning : .danger))
                            Text(info?.hostname ?? "Server").font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                            Text(metrics.health.label).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                            Spacer()
                            if let info { Text("up " + DurationFormatter.short(info.uptime())).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary) }
                        }
                        HStack(spacing: BB.Space.l) {
                            miniMetric("CPU", metrics.cpuUsage)
                            miniMetric("RAM", metrics.memoryUsage)
                            miniMetric("Disk", metrics.diskUsage)
                        }
                        if cpuHistory.count > 2 {
                            Sparkline(values: cpuHistory)
                                .stroke(BB.Palette.signal, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .frame(height: 34)
                                .animation(Motion.standard, value: cpuHistory)
                        }
                    }
                } else if let serverError {
                    Label(serverError.title, systemImage: "server.rack").font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                } else if model.suite.vps == nil {
                    Label("This backend doesn't expose server metrics.", systemImage: "server.rack").font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBlock(height: 16, width: 140)
                        SkeletonBlock(height: 40)
                    }
                }
            }
        }
    }

    private func miniMetric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).bbLabelStyle()
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(BB.Font.monoSmall)
                    .foregroundStyle(BB.Palette.textPrimary)
                    .contentTransition(.numericText(value: value))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(BB.Palette.surfaceHigh)
                    Capsule().fill(value > 0.85 ? BB.Palette.danger : BB.Palette.signal)
                        .frame(width: max(4, proxy.size.width * value))
                }
            }
            .frame(height: 5)
            .animation(Motion.standard, value: value)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: BB.Space.s) {
            SectionHeader(title: "Quick actions")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                quickAction("New chat", "plus.bubble", 0) {
                    model.chat.newConversation()
                    model.selectedTab = .agent
                }
                quickAction("Check health", "waveform.path.ecg", 1) {
                    model.chat.newConversation()
                    model.selectedTab = .agent
                    model.chat.send("Check server status and health")
                }
                quickAction("Live logs", "text.alignleft", 2) {
                    model.selectedTab = .vps
                }
                quickAction("Config files", "doc.badge.gearshape", 3) {
                    model.selectedTab = .files
                }
            }
        }
    }

    private func quickAction(_ title: String, _ symbol: String, _ index: Int, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.standard) { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BB.Palette.signalText)
                Text(title).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
        }
        .buttonStyle(.pressable)
        .bbEntrance(index: index + 4)
    }

    // MARK: Recent

    @ViewBuilder
    private var recentConversations: some View {
        let recent = Array(model.chat.conversations.filter { !$0.messages.isEmpty }.prefix(4))
        VStack(alignment: .leading, spacing: BB.Space.s) {
            SectionHeader(title: "Recent conversations")
            if recent.isEmpty {
                BBCard {
                    Text("No conversations yet. Ask the agent something to get started.")
                        .font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                }
            } else {
                BBCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, conversation in
                            Button {
                                model.chat.select(conversation.id)
                                withAnimation(Motion.standard) { model.selectedTab = .agent }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bubble.left.and.text.bubble.right")
                                        .foregroundStyle(BB.Palette.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conversation.title).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                                        Text(conversation.preview).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(conversation.updatedAt, style: .relative).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                                }
                                .padding(.horizontal, BB.Space.l)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressableSubtle)
                            if index < recent.count - 1 { Divider().overlay(BB.Palette.stroke).padding(.leading, 48) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentTasks: some View {
        let tasks = model.chat.recentTasks
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: BB.Space.s) {
                SectionHeader(title: "Recent activity")
                BBCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(tasks.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 10) {
                                ToolStatusIcon(status: item.call.status, size: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.call.title).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                                    Text(item.call.input).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).lineLimit(1)
                                }
                                Spacer()
                                Text(item.call.startedAt, style: .relative).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Data

    private func refreshServer() async {
        guard let vps = model.suite.vps else { return }
        do {
            async let i = vps.serverInfo()
            async let m = vps.metrics()
            let (newInfo, newMetrics) = try await (i, m)
            info = newInfo
            withAnimation(Motion.standard) { metrics = newMetrics }
            serverError = nil
        } catch {
            serverError = error.asAgentError
        }
    }

    private func streamServer() async {
        metrics = nil
        info = nil
        cpuHistory = []
        serverError = nil
        if let cached = model.snapshotCache.load() {
            info = cached.info
            metrics = cached.metrics
        }
        guard let vps = model.suite.vps else { return }
        await refreshServer()
        do {
            for try await sample in vps.metricsStream(interval: 2) {
                withAnimation(Motion.standard) {
                    metrics = sample
                    cpuHistory.append(sample.cpuUsage)
                    if cpuHistory.count > 30 { cpuHistory.removeFirst() }
                }
            }
        } catch {
            if !(error is CancellationError) { serverError = error.asAgentError }
        }
    }
}
