import BrainboxCore
import HermesKit
import SwiftUI

struct AgentsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Scheduled").tag(0)
                Text("Sub-agents").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DS.S.m)
            .padding(.vertical, DS.S.s)
            if tab == 0 { CronList() } else { SubagentList() }
        }
        .screenBackground()
        .navigationTitle("Agents")
    }
}

// MARK: - Scheduled jobs (cron)

struct CronJob: Identifiable, Hashable {
    var raw: JSONValue
    var id: String { raw["id"]?.stringValue ?? "" }
    var name: String { raw["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? String(prompt.prefix(40)) }
    var prompt: String { raw["prompt"]?.stringValue ?? "" }
    var schedule: String { raw["schedule_display"]?.stringValue ?? raw["schedule"]?["display"]?.stringValue ?? "" }
    var state: String { raw["state"]?.stringValue ?? (raw["enabled"]?.boolValue == true ? "scheduled" : "paused") }
    var paused: Bool { state == "paused" || raw["enabled"]?.boolValue == false }
    var nextRun: Date? { raw["next_run_at"]?.stringValue.flatMap(Self.parse) }
    var lastRun: Date? { raw["last_run_at"]?.stringValue.flatMap(Self.parse) }
    var lastStatus: String? { raw["last_status"]?.stringValue }
    var lastError: String? { raw["last_error"]?.stringValue }
    var deliver: String { raw["deliver"]?.stringValue ?? "local" }

    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

struct CronList: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [CronJob] = []
    @State private var error: String?
    @State private var loading = false
    @State private var showNew = false
    @State private var detail: CronJob?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.S.m) {
                if let error { ErrorBanner(message: error) { Task { await load() } } }
                if jobs.isEmpty && !loading {
                    EmptyState(symbol: "calendar.badge.clock", title: "No scheduled jobs",
                               message: "Have Hermes do something on a schedule — a morning brief, a server check, a weekly report.",
                               action: (label: "New job", run: { showNew = true }))
                }
                ForEach(jobs) { job in
                    Button { detail = job } label: { CronRow(job: job) }.buttonStyle(.plain)
                }
            }
            .padding(DS.S.m)
        }
        .overlay { if loading && jobs.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }.disabled(!model.isConnected)
            }
        }
        .sheet(isPresented: $showNew, onDismiss: { Task { await load() } }) { NavigationStack { NewCronJob() } }
        .sheet(item: $detail, onDismiss: { Task { await load() } }) { job in NavigationStack { CronDetail(job: job) } }
        .task(id: model.isConnected) { await load() }
    }

    private func load() async {
        guard model.isConnected else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.client().get("/api/cron/jobs")
            jobs = (result.arrayValue ?? result["jobs"]?.arrayValue ?? []).map(CronJob.init)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CronRow: View {
    var job: CronJob
    var body: some View {
        HStack(spacing: DS.S.m) {
            IconTile(symbol: job.paused ? "pause.fill" : "calendar.badge.clock", index: job.paused ? 5 : 2, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(DS.F.bodyStrong).foregroundStyle(DS.C.ink).lineLimit(1)
                Text(job.schedule).font(DS.F.monoSmall).foregroundStyle(DS.C.ink3)
                HStack(spacing: DS.S.s) {
                    Pill(text: job.state.capitalized, color: job.paused ? DS.C.ink3 : DS.C.good)
                    if let next = job.nextRun { Text("Next \(Fmt.relative(next))").font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                    if job.lastStatus == "error" || job.lastStatus == "failed" { Pill(text: "Last run failed", color: DS.C.bad) }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.ink3)
        }
        .card(padding: DS.S.m)
    }
}

struct CronDetail: View {
    @State var job: CronJob
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [JSONValue] = []
    @State private var prompt = ""
    @State private var schedule = ""
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("What it does") {
                TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(3...10)
                TextField("Schedule (cron or 'every 2h')", text: $schedule).font(DS.F.mono).textInputAutocapitalization(.never)
                LabeledContent("Delivers to", value: job.deliver)
                if prompt != job.prompt || schedule != job.schedule {
                    Button("Save changes") { Task { await save() } }
                }
            }
            Section {
                Button { Task { await act(job.paused ? "resume" : "pause") } } label: {
                    Label(job.paused ? "Resume" : "Pause", systemImage: job.paused ? "play.fill" : "pause.fill")
                }
                Button { Task { await act("trigger") } } label: { Label("Run now", systemImage: "bolt.fill") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete job", systemImage: "trash") }
            }
            if let message { Section { Text(message).font(DS.F.small) } }
            if let error = job.lastError, !error.isEmpty {
                Section("Last error") { Text(error).font(DS.F.monoSmall).foregroundStyle(DS.C.bad) }
            }
            Section("Recent runs") {
                if runs.isEmpty { Text("No runs yet").foregroundStyle(DS.C.ink3) }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(run["status"]?.stringValue?.capitalized ?? "Run").font(DS.F.smallStrong)
                            Spacer()
                            Text(run["started_at"]?.stringValue ?? run["run_at"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                        }
                        if let out = run["output"]?.stringValue ?? run["response"]?.stringValue ?? run["summary"]?.stringValue {
                            Text(out).font(DS.F.caption).foregroundStyle(DS.C.ink2).lineLimit(6)
                        }
                    }
                }
            }
        }
        .disabled(busy)
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog("Delete \(job.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        }
        .onAppear { prompt = job.prompt; schedule = job.schedule }
        .task { await loadRuns() }
    }

    private func loadRuns() async {
        guard let result = try? await model.client().get("/api/cron/jobs/\(job.id)/runs") else { return }
        runs = result["runs"]?.arrayValue ?? []
    }

    private func act(_ action: String) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await model.client().send("POST", "/api/cron/jobs/\(job.id)/\(action)")
            if result.objectValue?["id"] != nil { job = CronJob(raw: result) }
            else if let fresh = try? await model.client().get("/api/cron/jobs/\(job.id)") { job = CronJob(raw: fresh["job"] ?? fresh) }
            message = action == "trigger" ? "Started. Results show up under Recent runs." : nil
            Haptic.success()
            await loadRuns()
        } catch {
            message = error.localizedDescription
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await model.client().send("PUT", "/api/cron/jobs/\(job.id)",
                                                       json: ["updates": ["prompt": .string(prompt), "schedule": .string(schedule)]])
            job = CronJob(raw: result["job"] ?? result)
            message = "Saved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func delete() async {
        do {
            _ = try await model.client().send("DELETE", "/api/cron/jobs/\(job.id)")
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

struct NewCronJob: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var blueprints: [JSONValue] = []
    @State private var chosen: JSONValue?
    @State private var values: [String: String] = [:]
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = "0 9 * * *"
    @State private var deliver = "local"
    @State private var targets: [JSONValue] = []
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Picker("", selection: $mode) {
                Text("From a blueprint").tag(0)
                Text("Custom").tag(1)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if mode == 0 { blueprintSection } else { customSection }
            if let error { Section { Text(error).foregroundStyle(DS.C.bad).font(DS.F.small) } }
        }
        .navigationTitle("New job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await create() } }.disabled(saving || (mode == 0 ? chosen == nil : prompt.isEmpty || schedule.isEmpty))
            }
        }
        .task { await load() }
    }

    @ViewBuilder private var blueprintSection: some View {
        Section("Pick one") {
            ForEach(Array(blueprints.enumerated()), id: \.offset) { _, bp in
                Button {
                    chosen = bp
                    values = [:]
                    for f in bp["fields"]?.arrayValue ?? [] {
                        if let n = f["name"]?.stringValue { values[n] = f["default"]?.displayText ?? "" }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bp["title"]?.stringValue ?? "").font(DS.F.body).foregroundStyle(DS.C.ink)
                            Text(bp["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(2)
                        }
                        Spacer()
                        if chosen?["key"] == bp["key"] { Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.C.volt) }
                    }
                }
            }
        }
        if let chosen {
            Section(chosen["scheduleHuman"]?.stringValue ?? "Details") {
                ForEach(Array((chosen["fields"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, field in
                    let fieldName = field["name"]?.stringValue ?? ""
                    let options = field["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if !options.isEmpty {
                        Picker(field["label"]?.stringValue ?? fieldName, selection: binding(fieldName)) {
                            ForEach(options, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField(field["label"]?.stringValue ?? fieldName, text: binding(fieldName))
                    }
                }
            }
        }
    }

    @ViewBuilder private var customSection: some View {
        Section("What should Hermes do?") {
            TextField("Name", text: $name)
            TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(3...10)
        }
        Section {
            TextField("Schedule", text: $schedule).font(DS.F.mono).textInputAutocapitalization(.never).autocorrectionDisabled()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Self.presets, id: \.expr) { preset in
                        Button(preset.label) { schedule = preset.expr }.buttonStyle(ChipButtonStyle(selected: schedule == preset.expr))
                    }
                }
            }
            Picker("Deliver to", selection: $deliver) {
                ForEach(targets.compactMap { $0["id"]?.stringValue }, id: \.self) { id in
                    Text(targets.first { $0["id"]?.stringValue == id }?["name"]?.stringValue ?? id).tag(id)
                }
                if targets.isEmpty { Text("Local (save only)").tag("local") }
            }
        } header: { Text("When") } footer: { Text("Cron (minute hour day month weekday), or phrases Hermes understands like \"every 2h\".") }
    }

    struct Preset { var label: String; var expr: String }
    static let presets = [Preset(label: "Daily 9:00", expr: "0 9 * * *"), Preset(label: "Hourly", expr: "0 * * * *"),
                          Preset(label: "Weekdays 8:30", expr: "30 8 * * 1-5"), Preset(label: "Mondays", expr: "0 9 * * 1"),
                          Preset(label: "Every 2h", expr: "every 2h")]

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func load() async {
        if let result = try? await model.client().get("/api/cron/blueprints") { blueprints = result["blueprints"]?.arrayValue ?? [] }
        if let result = try? await model.client().get("/api/cron/delivery-targets") { targets = result["targets"]?.arrayValue ?? [] }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        do {
            if mode == 0, let key = chosen?["key"]?.stringValue {
                _ = try await model.client().send("POST", "/api/cron/blueprints/instantiate",
                                                  json: ["blueprint": .string(key), "values": .object(values.mapValues { .string($0) })])
            } else {
                _ = try await model.client().send("POST", "/api/cron/jobs",
                                                  json: ["name": .string(name), "prompt": .string(prompt), "schedule": .string(schedule),
                                                         "deliver": .string(deliver)])
            }
            Haptic.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Sub-agents

struct SubagentList: View {
    @Environment(AppModel.self) private var model
    @State private var agents: [JSONValue] = []
    @State private var selected: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.S.m) {
                if model.currentChat == nil {
                    EmptyState(symbol: "person.2", title: "No chat open", message: "Sub-agents belong to a chat. Open one and ask Hermes to delegate.")
                } else if agents.isEmpty {
                    EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No sub-agents running",
                               message: "When Hermes delegates work (delegate_task), each helper shows up here live. You can steer or stop them.")
                }
                ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                    let id = agent["subagent_id"]?.stringValue ?? ""
                    Button { selected = id } label: { SubagentRow(agent: agent) }.buttonStyle(.plain)
                }
            }
            .padding(DS.S.m)
        }
        .sheet(item: Binding(get: { selected.map { IdentifiedString(id: $0) } }, set: { selected = $0?.id })) { item in
            NavigationStack { SubagentDetail(subagentID: item.id, agent: agents.first { $0["subagent_id"]?.stringValue == item.id } ?? .null) }
        }
        .task(id: model.currentChat) {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func poll() async {
        guard let chat = model.currentChat, model.isConnected,
              let result = try? await model.engine.call(chat, "subagent.list") else { return }
        agents = result["subagents"]?.arrayValue ?? []
    }
}

struct IdentifiedString: Identifiable { var id: String }

struct SubagentRow: View {
    var agent: JSONValue
    var body: some View {
        let status = agent["status"]?.stringValue ?? "running"
        HStack(alignment: .top, spacing: DS.S.m) {
            IconTile(symbol: "person.fill.viewfinder", index: (agent["depth"]?.intValue ?? 0) + 1, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent["goal"]?.stringValue ?? "Sub-agent").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink).lineLimit(3)
                HStack(spacing: DS.S.s) {
                    Pill(text: status.capitalized, color: status == "running" ? DS.C.volt : status == "failed" ? DS.C.bad : DS.C.good)
                    if let m = agent["model"]?.stringValue { Text(m).font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                    if let n = agent["tool_count"]?.intValue { Text("\(n) tools").font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                }
                if let tool = agent["last_tool"]?.stringValue { Text("Last: \(tool)").font(DS.F.monoSmall).foregroundStyle(DS.C.ink3) }
            }
            Spacer(minLength: 0)
        }
        .card(padding: DS.S.m)
    }
}

struct SubagentDetail: View {
    var subagentID: String
    var agent: JSONValue
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tail = ""
    @State private var steer = ""
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.m) {
                    Text(agent["goal"]?.stringValue ?? "").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
                    if let note { Text(note).font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                    Text(tail.isEmpty ? "Waiting for output…" : tail).font(DS.F.monoSmall).foregroundStyle(DS.C.ink2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DS.S.m)
            }
            HStack(spacing: DS.S.s) {
                TextField("Steer this sub-agent", text: $steer)
                    .padding(.horizontal, DS.S.m).frame(minHeight: 44)
                    .background(DS.C.surface, in: Capsule())
                Button("Send") { Task { await sendSteer() } }.buttonStyle(SecondaryButtonStyle()).disabled(steer.isEmpty)
            }
            .padding(DS.S.m)
        }
        .screenBackground()
        .navigationTitle("Sub-agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) {
                Button("Stop", role: .destructive) { Task { await interrupt() } }
            }
        }
        .task {
            while !Task.isCancelled {
                if let chat = model.currentChat,
                   let result = try? await model.engine.call(chat, "subagent.tail", ["subagent_id": .string(subagentID)]) {
                    tail = result["text"]?.stringValue ?? tail
                    if result["available"]?.boolValue == false, tail.isEmpty { note = "This helper has finished." }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func sendSteer() async {
        guard let chat = model.currentChat else { return }
        let text = steer
        steer = ""
        let result = try? await model.engine.call(chat, "subagent.steer", ["subagent_id": .string(subagentID), "text": .string(text)])
        note = result?["status"]?.stringValue == "queued" ? "Steer queued — it lands at the helper's next step." : "Couldn't steer (it may have finished)."
    }

    private func interrupt() async {
        guard let chat = model.currentChat else { return }
        let result = try? await model.engine.call(chat, "subagent.interrupt", ["subagent_id": .string(subagentID)])
        note = result?["found"]?.boolValue == true ? "Stopping…" : "It already finished."
    }
}
