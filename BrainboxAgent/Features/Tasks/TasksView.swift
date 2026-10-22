import SwiftUI
import BrainboxCore

enum TaskFilter: String, CaseIterable, Identifiable {
    case active, approval, done, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: return "Active"
        case .approval: return "Approval"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

/// Agent runs started from this app, tracked by their real Hermes run ids
/// and statuses. Nothing here is simulated.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabIsActive) private var isActive
    @State private var filter: TaskFilter = .active
    @Namespace private var pill

    private var workspace: HermesWorkspace { model.hermes }

    private var records: [RunRecord] {
        switch filter {
        case .active: return workspace.activeRuns
        case .approval: return workspace.waitingRuns
        case .done: return workspace.finishedRuns
        case .failed: return workspace.failedRuns
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    filterBar.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                if !model.isHermes {
                    EmptyStateView(systemImage: "checklist", title: "Tasks need Hermes",
                                   message: "Every message to a Hermes teammate becomes a run on your VPS. Connect Hermes in Settings to track them here.")
                        .listRowBackground(Color.clear)
                } else if records.isEmpty {
                    EmptyStateView(systemImage: emptySymbol, title: emptyTitle, message: "Runs you start from this iPhone appear here with their live status.")
                        .listRowBackground(Color.clear)
                        .transition(.opacity)
                }
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    NavigationLink {
                        RunDetailView(runID: record.id)
                    } label: {
                        RunRow(record: record, teammate: workspace.teammate(record.teammateID))
                    }
                    .listRowBackground(BB.Palette.surface)
                    .bbEntrance(index: min(index, Motion.maxStaggeredItems))
                    .accessibilityIdentifier("task.\(record.state.rawValue)")
                }
                Section {
                    NavigationLink { ScheduledJobsView() } label: {
                        Label("Scheduled tasks", systemImage: "calendar.badge.clock").foregroundStyle(BB.Palette.textPrimary)
                    }
                    .accessibilityIdentifier("tasks.scheduled")
                } footer: {
                    Text("Hermes keeps a run's status only for a while after it ends; the full reply always stays in its session.")
                        .font(BB.Font.caption)
                }
                .listRowBackground(BB.Palette.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .bbScreen()
            .navigationTitle("Tasks")
            .animation(Motion.smooth, value: filter)
            .refreshable { await refreshActive() }
            .task(id: isActive) {
                guard isActive else { return }
                while !Task.isCancelled {
                    await refreshActive()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear finished", role: .destructive) { workspace.clearFinishedRuns() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .active: return "bolt.horizontal"
        case .approval: return "checkmark.shield"
        case .done: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .active: return "Nothing running"
        case .approval: return "No approvals waiting"
        case .done: return "No finished runs yet"
        case .failed: return "No failures"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(TaskFilter.allCases) { item in
                let count = countFor(item)
                Button {
                    withAnimation(Motion.smooth) { filter = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(item == .approval ? BB.Palette.warning.opacity(0.3) : BB.Palette.surfaceHigh))
                        }
                    }
                    .font(BB.Font.subhead)
                    .foregroundStyle(item == filter ? BB.Palette.onSignal : BB.Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background {
                        if item == filter {
                            Capsule().fill(BB.Palette.signal).matchedGeometryEffect(id: "pill", in: pill)
                        } else {
                            Capsule().fill(BB.Palette.surface)
                        }
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("tasks.filter.\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func countFor(_ filter: TaskFilter) -> Int {
        switch filter {
        case .active: return workspace.activeRuns.count
        case .approval: return workspace.waitingRuns.count
        case .done: return 0
        case .failed: return 0
        }
    }

    private func refreshActive() async {
        guard model.isHermes else { return }
        for record in workspace.runs where !record.state.isTerminal {
            await workspace.refresh(runID: record.id)
        }
    }
}

struct RunStateIcon: View {
    let state: HermesRunState
    var size: CGFloat = 22

    var body: some View {
        switch state {
        case .queued, .running, .stopping:
            ToolStatusIcon(status: .running, size: size)
        case .waitingForApproval:
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(BB.Palette.warning)
                .frame(width: size, height: size)
                .symbolEffect(.pulse, options: .repeating, isActive: Motion.ambientEnabled)
        case .completed:
            ToolStatusIcon(status: .succeeded, size: size)
        case .failed, .interrupted:
            ToolStatusIcon(status: .failed, size: size)
        case .cancelled, .unknown:
            ToolStatusIcon(status: .cancelled, size: size)
        }
    }
}

struct RunRow: View {
    let record: RunRecord
    let teammate: Teammate?

    var body: some View {
        HStack(spacing: 12) {
            RunStateIcon(state: record.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.state.label).bbLabelStyle(record.state == .waitingForApproval ? BB.Palette.warning : BB.Palette.textTertiary)
                    Text(record.updatedAt, style: .relative).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
                if let last = record.timeline.last, last.kind != .output {
                    Text(last.title).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            if let teammate {
                MascotView(style: teammate.mascot, mood: mood, size: 30, seed: teammate.id)
            }
        }
        .padding(.vertical, 4)
        .animation(Motion.smooth, value: record.state)
    }

    private var mood: MascotMood {
        switch record.state {
        case .waitingForApproval: return .waitingApproval
        case .running, .queued, .stopping: return .working
        case .failed, .interrupted: return .failed
        default: return .idle
        }
    }
}

// MARK: - Run detail

struct RunDetailView: View {
    let runID: String
    @Environment(AppModel.self) private var model
    @State private var steerText = ""
    @State private var working = false
    @State private var error: AgentError?
    @State private var approval: AgentApproval?
    @State private var confirmStop = false

    private var record: RunRecord? { model.hermes.run(runID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BB.Space.l) {
                if let record {
                    header(record).bbEntrance(index: 0)
                    if let error { ErrorBanner(error: error, dismiss: { self.error = nil }).transition(.bbRise) }
                    controls(record).bbEntrance(index: 1)
                    if !record.outputPreview.isEmpty {
                        BBCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Latest output").bbLabelStyle()
                                Text(record.outputPreview).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).textSelection(.enabled)
                            }
                        }
                        .bbEntrance(index: 2)
                    }
                    timeline(record)
                } else {
                    EmptyStateView(systemImage: "questionmark.circle", title: "Run not found", message: "This run is no longer tracked on this device.")
                }
            }
            .padding(BB.Space.gutter)
            .animation(Motion.smooth, value: record?.state)
        }
        .bbScreen()
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await model.hermes.refresh(runID: runID)
                guard let record, !record.state.isTerminal else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .sheet(item: $approval) { approval in
            ApprovalSheet(approval: approval, teammate: model.hermes.teammate(record?.teammateID))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Stop this run?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop run", role: .destructive) { Task { await stop() } }
        } message: {
            Text("Hermes stops the agent at the next safe point. Work already done is not undone.")
        }
    }

    private func header(_ record: RunRecord) -> some View {
        HStack(spacing: 14) {
            if let mate = model.hermes.teammate(record.teammateID) {
                MascotView(style: mate.mascot, mood: RunRow(record: record, teammate: mate).moodForHeader, size: 52, seed: mate.id)
            } else {
                RunStateIcon(state: record.state, size: 36)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                HStack(spacing: 8) {
                    Text(record.state.label).bbLabelStyle(record.state == .waitingForApproval ? BB.Palette.warning : BB.Palette.signalText)
                    Text("Started \(record.createdAt.formatted(date: .omitted, time: .shortened))").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                    if let finished = record.finishedAt {
                        Text("· \(Duration.seconds(finished.timeIntervalSince(record.createdAt)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
                            .font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                    }
                }
                Text(record.id).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func controls(_ record: RunRecord) -> some View {
        let report = model.hermes.report
        VStack(spacing: 10) {
            if record.state == .waitingForApproval {
                Button {
                    Task { approval = await model.hermes.pendingApproval(for: runID) }
                } label: {
                    Label("Review approval", systemImage: "exclamationmark.shield")
                        .font(BB.Font.headline)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundStyle(BB.Palette.onSignal)
                        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.warning))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("run.review")
            }
            if record.state == .running && report?.supports(.steer) == true {
                HStack(spacing: 8) {
                    TextField("Steer: e.g. focus on nginx first", text: $steerText)
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
                    Button {
                        Task { await steer() }
                    } label: {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(BB.Palette.onSignal).frame(width: 44, height: 44)
                            .background(Circle().fill(BB.Palette.signal))
                    }
                    .buttonStyle(.pressable)
                    .disabled(steerText.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
            if !record.state.isTerminal && record.state != .stopping && report?.supports(.stop) != false {
                Button(role: .destructive) { confirmStop = true } label: {
                    Label("Stop run", systemImage: "stop.circle").frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(BB.Palette.danger)
                .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.danger.opacity(0.1)))
                .accessibilityIdentifier("run.stop")
            }
            if let conversationID = record.conversationID, model.chat.conversations.contains(where: { $0.id == conversationID }) {
                Button {
                    model.chat.select(conversationID)
                    model.selectedTab = .agent
                } label: {
                    Label("Open conversation", systemImage: "bubble.left").frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(BB.Palette.signalText)
                .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
            }
        }
    }

    private func timeline(_ record: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity").bbLabelStyle().padding(.bottom, 8)
            ForEach(Array(record.timeline.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        TimelineDot(kind: entry.kind)
                        if index < record.timeline.count - 1 {
                            Rectangle().fill(BB.Palette.stroke).frame(width: 1.5).frame(minHeight: 18)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.title).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .standard)).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary)
                        }
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(detail).font(entry.kind == .output || entry.kind == .reasoning ? BB.Font.caption : BB.Font.monoSmall)
                                .foregroundStyle(BB.Palette.textSecondary).lineLimit(entry.kind == .output ? 6 : 3)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .bbEntrance(index: min(index, Motion.maxStaggeredItems))
            }
        }
    }

    private func steer() async {
        guard let provider = model.hermesProvider else { return }
        working = true
        defer { working = false }
        do {
            try await provider.steer(runID: runID, text: steerText)
            steerText = ""
            model.toasts.show("Steering sent")
        } catch {
            self.error = error.asAgentError
        }
    }

    private func stop() async {
        guard let provider = model.hermesProvider else { return }
        do {
            try await provider.stop(runID: runID)
            await model.hermes.refresh(runID: runID)
        } catch {
            self.error = error.asAgentError
        }
    }
}

extension RunRow {
    var moodForHeader: MascotMood { mood }
}

private struct TimelineDot: View {
    let kind: RunTimelineEntry.Kind
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color.opacity(0.14)))
    }

    private var symbol: String {
        switch kind {
        case .started: return "play.fill"
        case .toolStarted: return "wrench.and.screwdriver"
        case .toolCompleted: return "checkmark"
        case .toolFailed, .failed: return "xmark"
        case .output: return "text.alignleft"
        case .reasoning: return "sparkle"
        case .approvalRequested: return "exclamationmark.shield"
        case .approvalResolved: return "checkmark.shield"
        case .steered: return "arrow.turn.down.right"
        case .subagent: return "person.2"
        case .completed: return "flag.checkered"
        case .cancelled, .stopping: return "stop.fill"
        case .interrupted: return "bolt.slash"
        case .info: return "info"
        }
    }

    private var color: Color {
        switch kind {
        case .toolFailed, .failed, .interrupted: return BB.Palette.danger
        case .approvalRequested: return BB.Palette.warning
        case .completed, .toolCompleted, .approvalResolved: return BB.Palette.success
        case .cancelled, .stopping: return BB.Palette.textTertiary
        default: return BB.Palette.signalText
        }
    }
}

// MARK: - Scheduled jobs (Hermes cron via /api/jobs)

struct JobEditorView: View {
    var onSaved: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var schedule = "every day at 9am"
    @State private var prompt = ""
    @State private var deliver = "local"
    @State private var error: AgentError?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) } header: { Text("Name").bbLabelStyle() }
                Section {
                    TextField("Schedule", text: $schedule).textInputAutocapitalization(.never)
                } header: { Text("Schedule").bbLabelStyle() } footer: {
                    Text("Same formats as `hermes cron`, e.g. “every day at 9am”, “every 2h”, or a cron expression like “0 9 * * 1-5”. Hermes validates it.").font(BB.Font.caption)
                }
                Section {
                    TextEditor(text: $prompt).frame(minHeight: 120)
                } header: { Text("Prompt").bbLabelStyle() } footer: { Text("\(prompt.count)/5000").font(BB.Font.caption) }
                Section {
                    TextField("Deliver to", text: $deliver).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Delivery").bbLabelStyle() } footer: {
                    Text("“local” keeps results in Hermes. A delivery target such as “telegram” sends results through your existing Hermes gateway — the app never posts to Telegram itself.").font(BB.Font.caption)
                }
                if let error { ErrorBanner(error: error, dismiss: { self.error = nil }) }
            }
            .scrollContentBackground(.hidden)
            .background(BB.Palette.backgroundRaised)
            .navigationTitle("New scheduled task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty || prompt.count > 5000)
                }
            }
        }
    }

    private func save() async {
        guard let client = model.hermes.client else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await client.createJob(HermesJobDraft(name: name.trimmingCharacters(in: .whitespaces), schedule: schedule,
                                                          prompt: prompt, deliver: deliver.isEmpty ? "local" : deliver))
            await onSaved()
            dismiss()
        } catch {
            self.error = error.asAgentError
        }
    }
}
