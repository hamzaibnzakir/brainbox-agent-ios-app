import SwiftUI
import BrainboxCore

// MARK: - List

/// Hermes scheduled jobs with their real lifecycle. Refreshes every 15 s
/// while visible, plus a manual refresh button and pull-to-refresh.
struct ScheduledJobsView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var confirmDelete: HermesJob?

    private var jobs: ScheduledJobsModel { model.hermes.scheduledJobs }

    var body: some View {
        List {
            if let unavailable = jobs.unavailable {
                EmptyStateView(systemImage: "calendar.badge.exclamationmark", title: "Scheduled tasks unavailable", message: unavailable)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("jobs.unavailable")
            }
            if let error = jobs.error {
                ErrorBanner(error: error, retry: { Task { _ = await jobs.refresh() } }, dismiss: { jobs.clearError() })
                    .listRowBackground(Color.clear)
            }
            if jobs.jobs.isEmpty && jobs.unavailable == nil && !jobs.loading && jobs.error == nil && jobs.lastRefreshed != nil {
                EmptyStateView(systemImage: "calendar", title: "No scheduled tasks", message: "Create one to have Hermes run a prompt on a schedule.")
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(jobs.jobs.enumerated()), id: \.element.id) { index, job in
                    NavigationLink {
                        JobDetailView(jobID: job.id)
                    } label: {
                        JobRow(job: job, phase: jobs.phase(of: job), runNow: jobs.runNow[job.id])
                    }
                    .listRowBackground(BB.Palette.surface)
                    .bbEntrance(index: min(index, Motion.maxStaggeredItems))
                    .accessibilityIdentifier("job.\(job.id)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { confirmDelete = job } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            Task { await jobs.runNow(job) }
                        } label: {
                            Label("Run now", systemImage: "play")
                        }
                        .tint(BB.Palette.ion)
                        .disabled(jobs.runNow[job.id].map { !$0.phase.isTerminal } ?? false)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await jobs.setPaused(job, paused: !isPaused(job)) }
                        } label: {
                            Label(isPaused(job) ? "Resume" : "Pause", systemImage: isPaused(job) ? "play.circle" : "pause.circle")
                        }
                        .tint(BB.Palette.warning)
                    }
                }
            } footer: {
                if let refreshed = jobs.lastRefreshed {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .standard)) · refreshes every 15 s while open")
                        .font(BB.Font.caption)
                }
            }
            if jobs.loading && jobs.jobs.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Scheduled")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { _ = await jobs.refresh() }
                } label: {
                    if jobs.loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(jobs.loading)
                .accessibilityLabel("Refresh")
                .accessibilityIdentifier("jobs.refresh")
                Button { creating = true } label: { Image(systemName: "plus") }
                    .disabled(jobs.unavailable != nil || model.hermes.client == nil)
                    .accessibilityLabel("New scheduled task")
            }
        }
        .refreshable { _ = await jobs.refresh() }
        .task { await jobs.autoRefresh() }
        .sheet(isPresented: $creating) { JobEditorView { _ = await jobs.refresh() } }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "job")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let job = confirmDelete { Task { await jobs.delete(job) } }
            }
        } message: { Text(JobDeletion.warning) }
    }

    private func isPaused(_ job: HermesJob) -> Bool { !job.enabled || job.paused }
}

/// Verified against Hermes 284d220 `cron/jobs.py` `remove_job`: the job and
/// its saved output folder are removed; a running attempt is not interrupted.
enum JobDeletion {
    static let warning = "Stops future runs and permanently erases this job's saved results on the server. A run that is already in progress is not stopped."
}

struct JobRow: View {
    let job: HermesJob
    let phase: HermesJobPhase
    let runNow: ScheduledJobsModel.RunNowState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.name).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary).lineLimit(2)
                Spacer()
                JobPhaseBadge(phase: phase)
            }
            Label(job.schedule.isEmpty ? "—" : job.schedule, systemImage: "clock")
                .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            HStack(spacing: 10) {
                if let next = job.nextRun, job.enabled, !job.paused {
                    Text("Next \(JobTime.relative(next))").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
                if let last = job.lastRun {
                    Text("Last \(JobTime.relative(last))").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
                if job.failureStreak > 0 {
                    Label("\(job.failureStreak) failed in a row", systemImage: "exclamationmark.triangle")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.warning)
                }
            }
            .lineLimit(1)
            if phase == .failed || phase == .completedDeliveryFailed || phase == .unknown,
               let detail = HermesJobLifecycle.failureDetail(of: job) {
                Text(detail).font(BB.Font.caption).foregroundStyle(BB.Palette.danger).lineLimit(2)
            }
            if let runNow {
                RunNowStatusLine(phase: runNow.phase)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct JobPhaseBadge: View {
    let phase: HermesJobPhase

    var body: some View {
        HStack(spacing: 4) {
            if phase.isActive { ProgressView().controlSize(.mini).tint(color) }
            Text(phase.label).bbLabelStyle(color)
        }
        .accessibilityLabel("Status: \(phase.label)")
    }

    private var color: Color {
        switch phase {
        case .completed, .finished: return BB.Palette.success
        case .failed: return BB.Palette.danger
        case .completedDeliveryFailed, .unknown: return BB.Palette.warning
        case .queued, .starting, .running: return BB.Palette.signalText
        case .paused, .scheduled: return BB.Palette.textTertiary
        }
    }
}

struct RunNowStatusLine: View {
    let phase: RunNowTracker.Phase

    var body: some View {
        HStack(spacing: 6) {
            if !phase.isTerminal { ProgressView().controlSize(.mini) }
            Image(systemName: symbol).foregroundStyle(color)
            Text("Run now: \(phase.label)").font(BB.Font.caption).foregroundStyle(color)
        }
        .accessibilityIdentifier("runnow.status")
    }

    private var symbol: String {
        switch phase {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        default: return "play.circle"
        }
    }

    private var color: Color {
        switch phase {
        case .completed: return BB.Palette.success
        case .failed: return BB.Palette.danger
        case .unknown: return BB.Palette.warning
        default: return BB.Palette.signalText
        }
    }
}

enum JobTime {
    /// "in 5 min" / "3 min ago" for Hermes ISO timestamps; the raw text if unparseable.
    static func relative(_ iso: String, now: Date = Date()) -> String {
        guard let date = HermesDates.parse(iso) else { return iso }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func absolute(_ iso: String?) -> String {
        guard let iso else { return "—" }
        guard let date = HermesDates.parse(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Detail

struct JobDetailView: View {
    let jobID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [CronRun] = []
    @State private var runsLoading = false
    @State private var runsError: AgentError?
    @State private var confirmDelete = false

    private var jobs: ScheduledJobsModel { model.hermes.scheduledJobs }

    var body: some View {
        List {
            if let job = jobs.job(jobID) {
                content(job)
            } else {
                EmptyStateView(systemImage: "calendar.badge.minus", title: "Job not found", message: "It may have been deleted on Hermes.")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle(jobs.job(jobID)?.name ?? "Scheduled task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh")
                    .accessibilityIdentifier("job.refresh")
            }
        }
        .refreshable { await reload() }
        .task { await loadRuns() }
        .task { await jobs.autoRefresh() }
        .onChange(of: jobs.runNow[jobID]?.phase) { _, phase in
            if phase?.isTerminal == true { Task { await loadRuns() } }
        }
        .confirmationDialog("Delete this job?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let job = jobs.job(jobID) {
                    Task {
                        await jobs.delete(job)
                        dismiss()
                    }
                }
            }
        } message: { Text(JobDeletion.warning) }
    }

    @ViewBuilder
    private func content(_ job: HermesJob) -> some View {
        let phase = jobs.phase(of: job)
        Section {
            HStack {
                JobPhaseBadge(phase: phase)
                Spacer()
                Text(job.enabled && !job.paused ? "Enabled" : "Disabled").bbLabelStyle(job.enabled && !job.paused ? BB.Palette.success : BB.Palette.textTertiary)
            }
            if let detail = HermesJobLifecycle.failureDetail(of: job) {
                Text(detail).font(BB.Font.caption).foregroundStyle(BB.Palette.danger).textSelection(.enabled)
                    .accessibilityIdentifier("job.error")
            }
        } header: { Text("Status").bbLabelStyle() }
        .listRowBackground(BB.Palette.surface)

        Section {
            fact("Schedule", job.schedule.isEmpty ? "—" : job.schedule)
            fact("Next run", job.enabled && !job.paused ? JobTime.absolute(job.nextRun) : "—")
            fact("Last run", JobTime.absolute(job.lastRun))
            fact("Last result", lastResultLabel(job))
            fact("Failures in a row", "\(job.failureStreak)")
            if let execution = job.latestExecution {
                fact("Latest attempt", execution.rawStatus.capitalized)
                fact("Started", JobTime.absolute(execution.startedAt ?? execution.claimedAt))
                if execution.finishedAt != nil { fact("Finished", JobTime.absolute(execution.finishedAt)) }
            }
            fact("Delivery", job.deliver ?? "local")
        } header: { Text("Timing").bbLabelStyle() } footer: {
            Text("Times are shown in your time zone. Hermes interprets schedules like “9am” in its own server time zone.")
                .font(BB.Font.caption)
        }
        .listRowBackground(BB.Palette.surface)

        Section {
            runNowControl(job)
        } header: { Text("Run now").bbLabelStyle() } footer: {
            Text("Hermes starts it on its next scheduler pass (usually within a minute). The app follows it every 5 s for up to \(Int(RunNowTracker.timeout / 60)) min and never starts it twice.")
                .font(BB.Font.caption)
        }
        .listRowBackground(BB.Palette.surface)

        Section {
            if runsLoading && runs.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let runsError {
                ErrorBanner(error: runsError, retry: { Task { await loadRuns() } })
            } else if runs.isEmpty {
                Text("No runs found yet. Runs appear here once Hermes has executed this job.")
                    .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            }
            ForEach(runs.prefix(25)) { run in
                NavigationLink {
                    CronRunResultView(run: run, jobName: job.name)
                } label: {
                    CronRunRow(run: run)
                }
                .accessibilityIdentifier("cronrun.\(run.sessionID)")
            }
        } header: { Text("Runs").bbLabelStyle() } footer: {
            Text("Each run is stored by Hermes as its own session; opening one only reads it.")
                .font(BB.Font.caption)
        }
        .listRowBackground(BB.Palette.surface)

        if !job.prompt.isEmpty {
            Section {
                Text(job.prompt).font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary).textSelection(.enabled)
            } header: { Text("Prompt").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)
        }

        Section {
            Button(job.enabled && !job.paused ? "Pause" : "Resume") {
                Task { await jobs.setPaused(job, paused: job.enabled && !job.paused) }
            }
            .foregroundStyle(BB.Palette.signalText)
            Button("Delete", role: .destructive) { confirmDelete = true }
                .accessibilityIdentifier("job.delete")
        }
        .listRowBackground(BB.Palette.surface)
    }

    @ViewBuilder
    private func runNowControl(_ job: HermesJob) -> some View {
        let state = jobs.runNow[job.id]
        if let state {
            RunNowStatusLine(phase: state.phase)
            switch state.phase {
            case .failed(let detail?):
                Text(detail).font(BB.Font.caption).foregroundStyle(BB.Palette.danger).textSelection(.enabled)
            case .unknown(let reason):
                Text(reason).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            default:
                EmptyView()
            }
            if let run = state.resultRun {
                NavigationLink {
                    CronRunResultView(run: run, jobName: job.name)
                } label: {
                    Label("View result", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("runnow.viewresult")
            } else if state.phase == .completed || isFailed(state.phase) {
                Text("The run finished, but its session wasn't found yet. Pull to refresh the runs below.")
                    .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            }
            if state.phase.isTerminal {
                Button("Clear") { jobs.dismissRunNow(job.id) }.font(BB.Font.caption)
            }
        }
        if state == nil || state?.phase.isTerminal == true {
            Button {
                Task { await jobs.runNow(job) }
            } label: {
                Label("Run now", systemImage: "play.fill")
            }
            .foregroundStyle(BB.Palette.signalText)
            .disabled(!job.enabled || job.paused)
            .accessibilityIdentifier("job.runnow")
        }
    }

    private func isFailed(_ phase: RunNowTracker.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func lastResultLabel(_ job: HermesJob) -> String {
        switch job.lastStatus {
        case nil: return "Never run"
        case "ok"?: return "OK"
        case "error"?: return "Error"
        case "delivery_failed"?: return "Ran, delivery failed"
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
            Spacer()
            Text(value).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        await jobs.refresh()
        await loadRuns()
    }

    private func loadRuns() async {
        guard let job = jobs.job(jobID) else { return }
        runsLoading = true
        defer { runsLoading = false }
        do {
            runs = try await jobs.runs(for: job)
            runsError = nil
        } catch {
            runsError = error.asAgentError
        }
    }
}

struct CronRunRow: View {
    let run: CronRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(run.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? (run.title ?? run.sessionID))
                .font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary)
            HStack(spacing: 8) {
                if let ended = run.endedAt, let started = run.startedAt {
                    Text(Duration.seconds(max(0, ended.timeIntervalSince(started))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
                } else if run.endedAt == nil {
                    Text("In progress or not closed")
                }
                if let count = run.messageCount { Text("\(count) messages") }
            }
            .font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
        }
    }
}

// MARK: - Result

struct CronRunResultView: View {
    let run: CronRun
    let jobName: String
    @Environment(AppModel.self) private var model
    @State private var result: CronRunResult?
    @State private var messages: [HermesMessage] = []
    @State private var loading = true
    @State private var error: AgentError?
    @State private var showTranscript = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(jobName).font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                    if let started = run.startedAt {
                        Text(started.formatted(date: .abbreviated, time: .standard)).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    }
                    Text("Session \(run.sessionID)").font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).textSelection(.enabled)
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { ErrorBanner(error: error, retry: { Task { await load() } }) }
                switch result {
                case .text(let text)?:
                    Text("Result").bbLabelStyle()
                    MarkdownView(text: text, onCopy: { Clipboard.copy($0) })
                        .accessibilityIdentifier("cronrun.result")
                case .noReply?:
                    EmptyStateView(systemImage: "text.badge.xmark", title: "No reply in this run",
                                   message: "Hermes recorded this run but it ended without a final answer — it may have failed or been stopped. The transcript below shows what happened.")
                        .accessibilityIdentifier("cronrun.noreply")
                case .empty?:
                    EmptyStateView(systemImage: "tray", title: "Nothing recorded yet",
                                   message: "This run's session has no messages. It may still be starting, or Hermes didn't save any.")
                        .accessibilityIdentifier("cronrun.empty")
                case nil:
                    EmptyView()
                }
                if !messages.isEmpty {
                    DisclosureGroup(isExpanded: $showTranscript) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(sortedMessages.enumerated()), id: \.offset) { _, message in
                                TranscriptBubble(message: message)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Full transcript (\(messages.count))").font(BB.Font.subhead)
                    }
                    .tint(BB.Palette.signalText)
                }
            }
            .padding(BB.Space.gutter)
        }
        .background(ScreenBackground())
        .navigationTitle("Run result")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private var sortedMessages: [HermesMessage] {
        messages.enumerated().sorted { a, b in
            switch (a.element.timestamp, b.element.timestamp) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let loaded = try await model.hermes.scheduledJobs.result(for: run)
            result = loaded.result
            messages = loaded.messages
            error = nil
        } catch {
            self.error = error.asAgentError
        }
    }
}
