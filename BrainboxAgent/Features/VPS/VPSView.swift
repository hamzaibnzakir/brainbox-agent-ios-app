import SwiftUI
import BrainboxCore

struct VPSView: View {
    @Environment(AppModel.self) private var model
    @State private var info: ServerInfo?
    @State private var metrics: ServerMetrics?
    @State private var services: [ServiceStatus] = []
    @State private var rxHistory: [Double] = []
    @State private var txHistory: [Double] = []
    @State private var error: AgentError?
    @State private var isCached = false
    @State private var busyService: String?
    @State private var pendingAction: (ServiceAction, ServiceStatus)?
    @State private var openTerminal = false
    @State private var authMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BB.Space.xl) {
                    header.bbEntrance(index: 0)
                    if model.suite.vps == nil {
                        BBCard {
                            EmptyStateView(systemImage: "server.rack", title: "No server connected", message: "The current backend doesn't expose VPS controls. Switch to Mock or connect the Brainbox gateway in Settings.")
                        }
                    } else {
                        if let error {
                            ErrorBanner(error: error, retry: { Task { await load() } }, dismiss: { self.error = nil })
                                .transition(.bbRise)
                        }
                        if let authMessage {
                            ErrorBanner(error: .permissionDenied(detail: authMessage), dismiss: { self.authMessage = nil })
                                .transition(.bbRise)
                        }
                        metricsSection.bbEntrance(index: 1)
                        toolsSection.bbEntrance(index: 2)
                        servicesSection.bbEntrance(index: 3)
                        systemSection.bbEntrance(index: 4)
                    }
                }
                .padding(.horizontal, BB.Space.gutter)
                .padding(.bottom, BB.Space.xxl)
                .animation(Motion.standard, value: error)
            }
            .refreshable { await load() }
            .bbScreen()
            .navigationTitle("VPS")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $openTerminal) { TerminalView() }
            .task(id: model.settings.providerKind) { await run() }
            .confirmationDialog(
                pendingAction.map { "\($0.0.rawValue.capitalized) \($0.1.name)?" } ?? "",
                isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                titleVisibility: .visible
            ) {
                if let pending = pendingAction {
                    Button(pending.0.rawValue.capitalized, role: pending.0.isDestructive ? .destructive : nil) {
                        Task { await perform(pending.0, on: pending.1) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This runs on the server. You'll confirm with \(model.gate.biometryName).")
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            StatusDot(tone: healthTone)
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.hostname ?? "Server").font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                Text(subtitle).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            }
            Spacer()
            if isCached { Badge(text: "Cached", color: BB.Palette.ion) }
            if model.isMock { Badge(text: "Mock") }
        }
        .padding(.top, 4)
    }

    private var subtitle: String {
        guard let metrics else { return model.connectionState.label }
        var parts = [metrics.health.label]
        if let info { parts.append("up \(DurationFormatter.short(info.uptime()))") }
        if let address = info?.privateAddress { parts.append(address) }
        return parts.joined(separator: " · ")
    }

    private var healthTone: StatusTone {
        guard let metrics else { return .idle }
        switch metrics.health {
        case .healthy: return .live
        case .degraded: return .warning
        case .critical: return .danger
        case .unknown: return .idle
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        BBCard {
            if let metrics {
                VStack(spacing: BB.Space.l) {
                    HStack(alignment: .top) {
                        MetricRing(value: metrics.cpuUsage, label: "CPU", detail: "load \(String(format: "%.2f", metrics.loadAverage.first ?? 0))")
                        MetricRing(value: metrics.memoryUsage, label: "Memory", detail: "\(ByteFormatter.string(metrics.memoryUsedBytes)) / \(ByteFormatter.string(metrics.memoryTotalBytes))")
                        MetricRing(value: metrics.diskUsage, label: "Disk", detail: "\(ByteFormatter.string(metrics.diskUsedBytes)) / \(ByteFormatter.string(metrics.diskTotalBytes))")
                    }
                    Divider().overlay(BB.Palette.stroke)
                    HStack(spacing: BB.Space.l) {
                        networkStat("Down", metrics.networkRxBytesPerSecond, rxHistory, BB.Palette.signal)
                        networkStat("Up", metrics.networkTxBytesPerSecond, txHistory, BB.Palette.ion)
                    }
                }
            } else {
                HStack(spacing: 20) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 10) {
                            Circle().fill(BB.Palette.surfaceHigh).frame(width: 74, height: 74).bbShimmer()
                            SkeletonBlock(height: 10, width: 50)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func networkStat(_ title: String, _ value: Double, _ history: [Double], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).bbLabelStyle()
                Spacer()
                Text(ByteFormatter.rate(value)).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textPrimary)
                    .contentTransition(.numericText(value: value))
            }
            Sparkline(values: history)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity)
    }

    private var toolsSection: some View {
        HStack(spacing: 10) {
            toolButton("Terminal", "terminal", enabled: model.suite.terminal != nil) {
                Task {
                    if await model.gate.authorize(.openTerminal) {
                        openTerminal = true
                    } else if let message = model.gate.lastErrorMessage {
                        authMessage = message
                    }
                }
            }
            .accessibilityIdentifier("vps.terminal")
            NavigationLink { LogViewerView() } label: { toolLabel("Logs", "text.alignleft") }
                .buttonStyle(.pressable)
                .disabled(model.suite.logs == nil)
            NavigationLink { ProcessesView() } label: { toolLabel("Processes", "list.bullet.rectangle") }
                .buttonStyle(.pressable)
        }
    }

    private func toolButton(_ title: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, symbol) }
            .buttonStyle(.pressable)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
    }

    private func toolLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(BB.Palette.signalText)
            Text(title).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: BB.Space.s) {
            SectionHeader(title: "Services")
            BBCard(padding: 0) {
                VStack(spacing: 0) {
                    if services.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(0..<3, id: \.self) { _ in SkeletonBlock(height: 18) }
                        }
                        .padding(BB.Space.l)
                    }
                    ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                        serviceRow(service)
                            .bbEntrance(index: index)
                        if index < services.count - 1 { Divider().overlay(BB.Palette.stroke).padding(.leading, 40) }
                    }
                }
            }
        }
    }

    private func serviceRow(_ service: ServiceStatus) -> some View {
        HStack(spacing: 12) {
            StatusDot(tone: tone(for: service.state), pulsing: service.state == .running || service.state == .restarting)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(BB.Font.mono).foregroundStyle(BB.Palette.textPrimary)
                Text(serviceDetail(service)).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(1)
            }
            Spacer()
            if busyService == service.name {
                ProgressView().controlSize(.small).tint(BB.Palette.signal)
            } else {
                Menu {
                    if service.state != .running {
                        Button { pendingAction = (.start, service) } label: { Label("Start", systemImage: "play.fill") }
                    }
                    if service.state == .running {
                        Button { pendingAction = (.restart, service) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { pendingAction = (.stop, service) } label: { Label("Stop", systemImage: "stop.fill") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(BB.Palette.textSecondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .disabled(model.suite.vps == nil)
                .accessibilityLabel("Actions for \(service.name)")
            }
        }
        .padding(.horizontal, BB.Space.l)
        .padding(.vertical, 11)
        .animation(Motion.standard, value: service.state)
    }

    private func serviceDetail(_ service: ServiceStatus) -> String {
        var parts = [service.state.rawValue.capitalized]
        if let pid = service.pid { parts.append("pid \(pid)") }
        if let memory = service.memoryBytes { parts.append(ByteFormatter.string(memory)) }
        if let since = service.since { parts.append(DurationFormatter.short(Date().timeIntervalSince(since))) }
        return parts.joined(separator: " · ")
    }

    private func tone(for state: ServiceState) -> StatusTone {
        switch state {
        case .running: return .live
        case .restarting: return .busy
        case .stopped, .unknown: return .idle
        case .failed: return .danger
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        if let info {
            VStack(alignment: .leading, spacing: BB.Space.s) {
                SectionHeader(title: "System")
                BBCard {
                    VStack(spacing: 10) {
                        infoRow("OS", info.operatingSystem)
                        infoRow("Kernel", info.kernel)
                        infoRow("Arch", "\(info.architecture) · \(info.cpuCores) cores")
                        infoRow("Booted", info.bootedAt.formatted(date: .abbreviated, time: .shortened))
                        if let address = info.privateAddress { infoRow("Private IP", address) }
                    }
                }
            }
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).bbLabelStyle()
            Spacer()
            Text(value).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
        }
    }

    // MARK: Data

    private func run() async {
        info = nil; metrics = nil; services = []; rxHistory = []; txHistory = []; error = nil
        if let cached = model.snapshotCache.load() {
            info = cached.info
            metrics = cached.metrics
            services = cached.services
            isCached = true
        }
        guard let vps = model.suite.vps else { return }
        await load()
        do {
            for try await sample in vps.metricsStream(interval: 1.5) {
                withAnimation(Motion.standard) {
                    metrics = sample
                    isCached = false
                    rxHistory.append(sample.networkRxBytesPerSecond)
                    txHistory.append(sample.networkTxBytesPerSecond)
                    if rxHistory.count > 40 { rxHistory.removeFirst() }
                    if txHistory.count > 40 { txHistory.removeFirst() }
                }
            }
        } catch {
            if !(error is CancellationError) { self.error = error.asAgentError }
        }
    }

    private func load() async {
        guard let vps = model.suite.vps else { return }
        do {
            async let i = vps.serverInfo()
            async let m = vps.metrics()
            async let s = vps.services()
            let (newInfo, newMetrics, newServices) = try await (i, m, s)
            withAnimation(Motion.standard) {
                info = newInfo
                metrics = newMetrics
                services = newServices
                isCached = false
                error = nil
            }
            model.snapshotCache.store(ServerSnapshot(info: newInfo, metrics: newMetrics, services: newServices))
        } catch {
            withAnimation(Motion.standard) { self.error = error.asAgentError }
        }
    }

    private func perform(_ action: ServiceAction, on service: ServiceStatus) async {
        pendingAction = nil
        guard let vps = model.suite.vps else { return }
        guard await model.gate.authorize(.controlService) else {
            authMessage = model.gate.lastErrorMessage
            return
        }
        busyService = service.name
        defer { busyService = nil }
        do {
            let updated = try await vps.perform(action, service: service.name)
            withAnimation(Motion.standard) {
                if let index = services.firstIndex(where: { $0.name == updated.name }) { services[index] = updated }
            }
            model.toasts.show("\(service.name) \(action == .stop ? "stopped" : (action == .start ? "started" : "restarted"))")
        } catch {
            withAnimation(Motion.standard) { self.error = error.asAgentError }
        }
    }
}
