import SwiftUI
import BrainboxCore

/// Agent Workspace → parallel tasks. Every agent card is a real Hermes run;
/// its state, output and errors come from that run's stream or status.
struct ParallelTasksSection: View {
    @Environment(AppModel.self) private var model
    @State private var composing = false

    private var store: ParallelAgentsStore { model.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Parallel agents", trailing: model.isHermes ? "New" : nil) { composing = true }
            if !model.isHermes {
                BBCard {
                    Text("Parallel agents run as separate Hermes runs. Connect Hermes in Settings to use them.")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
            } else if store.tasks.isEmpty {
                Button { composing = true } label: {
                    BBCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Split work across agents", systemImage: "square.split.2x2")
                                .font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                            Text("Each part runs as its own Hermes run at the same time, with its own progress, stop and result — then one run combines them. Or type /parallel a | b in chat.")
                                .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("parallel.empty")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.tasks.prefix(6)) { task in
                        NavigationLink { ParallelTaskDetailView(taskID: task.id) } label: { ParallelTaskRow(task: task) }
                            .buttonStyle(.pressable)
                    }
                }
            }
        }
        .sheet(isPresented: $composing) { StartParallelTaskView().presentationDragIndicator(.visible) }
    }
}

struct ParallelTaskRow: View {
    let task: ParallelTask

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -10) {
                ForEach(task.agents.prefix(4)) { agent in
                    MascotView(style: .brainbox, mood: ParallelAgentCard.mood(agent), size: 30, seed: agent.id)
                        .background(Circle().fill(BB.Palette.surface).padding(-2))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                Text(summary).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(BB.Palette.textTertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let done = task.agents.filter { $0.state == .completed }.count
        let running = task.agents.filter { !$0.state.isTerminal && $0.state != .waiting }.count
        let waiting = task.agents.filter { $0.state == .waiting }.count
        let failed = task.agents.filter { $0.state == .failed || $0.state == .lost }.count
        var parts = ["\(done)/\(task.agents.count) done"]
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting for a slot") }
        if failed > 0 { parts.append("\(failed) failed") }
        if let synthesis = task.synthesis { parts.append(synthesis.state == .completed ? "combined" : "combining…") }
        return parts.joined(separator: " · ")
    }
}

struct ParallelTaskDetailView: View {
    @Environment(AppModel.self) private var model
    let taskID: UUID

    var body: some View {
        ScrollView {
            if let task = model.agents.task(taskID) {
                VStack(alignment: .leading, spacing: BB.Space.l) {
                    Text(task.title).font(BB.Font.title).foregroundStyle(BB.Palette.textPrimary)
                    Text("\(task.agents.count) independent Hermes runs · up to \(model.agents.maxConcurrent) at once")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    ForEach(Array(task.agents.enumerated()), id: \.element.id) { index, agent in
                        ParallelAgentCard(agent: agent, index: index + 1,
                                          cancel: { model.agents.cancel(agent: agent.id, in: taskID) },
                                          retry: { model.agents.retry(agent: agent.id, in: taskID) })
                    }
                    if let synthesis = task.synthesis {
                        SectionHeader(title: "Combined result")
                        ParallelAgentCard(agent: synthesis, index: nil,
                                          cancel: { model.agents.cancel(agent: synthesis.id, in: taskID) }, retry: nil)
                    } else if task.wantsSynthesis {
                        Text(task.agentsSettled ? "No agent finished, so there's nothing to combine." : "A combined result runs once every agent has finished.")
                            .font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                    }
                }
                .padding(.horizontal, BB.Space.gutter)
                .padding(.bottom, BB.Space.xxl)
            } else {
                EmptyStateView(systemImage: "square.split.2x2", title: "Task removed", message: "This parallel task is no longer on this device.")
            }
        }
        .bbScreen()
        .navigationTitle("Parallel task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let task = model.agents.task(taskID) {
                ToolbarItem(placement: .topBarTrailing) {
                    if task.isFinished {
                        Button("Remove", role: .destructive) { model.agents.remove(taskID) }
                    } else {
                        Button("Stop all", role: .destructive) { model.agents.cancelAll(in: taskID) }
                            .accessibilityIdentifier("parallel.stopAll")
                    }
                }
            }
        }
    }
}

struct ParallelAgentCard: View {
    let agent: ParallelAgent
    let index: Int?
    let cancel: () -> Void
    let retry: (() -> Void)?
    @State private var expanded = false

    static func mood(_ agent: ParallelAgent) -> MascotMood {
        switch agent.state {
        case .waiting: return .idle
        case .starting, .running: return agent.activity.last?.hasPrefix("Using") == true ? .working : .thinking
        case .waitingForApproval: return .waitingApproval
        case .stopping, .cancelled: return .interrupted
        case .completed: return .happy
        case .failed, .lost: return .failed
        }
    }

    var body: some View {
        BBCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MascotView(style: .brainbox, mood: Self.mood(agent), size: 36, seed: agent.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index.map { "Agent \($0) · \(agent.title)" } ?? agent.title)
                            .font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                        Label(stateText, systemImage: stateSymbol)
                            .font(BB.Font.caption).foregroundStyle(stateColor)
                    }
                    Spacer()
                    if !agent.state.isTerminal && agent.state != .stopping {
                        Button("Stop", role: .destructive, action: cancel)
                            .font(BB.Font.subhead)
                            .accessibilityIdentifier("parallel.stop")
                    } else if let retry, agent.state != .completed, agent.state != .stopping {
                        Button("Retry", action: retry).font(BB.Font.subhead)
                    }
                }
                if let error = agent.error {
                    Text(error).font(BB.Font.caption).foregroundStyle(BB.Palette.danger).fixedSize(horizontal: false, vertical: true)
                }
                if !agent.subagents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hermes sub-agents (stop with this agent)").font(BB.Font.label).foregroundStyle(BB.Palette.textTertiary)
                        ForEach(agent.subagents) { sub in
                            Label((sub.goal ?? "Sub-task") + (sub.finished ? " — \(sub.status ?? "done")" : ""),
                                  systemImage: sub.finished ? "checkmark.circle" : "circle.dotted")
                                .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(2)
                        }
                    }
                }
                if !agent.output.isEmpty {
                    MarkdownView(text: expanded ? agent.output : String(agent.output.prefix(600)), isStreaming: !agent.state.isTerminal, onCopy: { Clipboard.copy($0) })
                    if agent.output.count > 600 {
                        Button(expanded ? "Show less" : "Show all") { expanded.toggle() }.font(BB.Font.caption)
                    }
                } else if let last = agent.activity.last {
                    Text(last).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
                Text(agent.prompt).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).lineLimit(expanded ? nil : 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("parallel.agent")
    }

    private var stateText: String {
        switch agent.state {
        case .waiting: return "Waiting for a free slot"
        case .starting: return "Starting on Hermes…"
        case .running: return agent.runID.map { "Running · \($0.prefix(12))" } ?? "Running"
        case .waitingForApproval: return "Waiting for your approval (Tasks)"
        case .stopping: return "Stopping — waiting for Hermes"
        case .completed: return "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .lost: return "Lost contact"
        }
    }

    private var stateSymbol: String {
        switch agent.state {
        case .waiting: return "clock"
        case .starting, .running: return "bolt.horizontal"
        case .waitingForApproval: return "hand.raised"
        case .stopping, .cancelled: return "stop.circle"
        case .completed: return "checkmark.circle"
        case .failed, .lost: return "exclamationmark.triangle"
        }
    }

    private var stateColor: Color {
        switch agent.state {
        case .completed: return BB.Palette.success
        case .failed, .lost: return BB.Palette.danger
        case .waitingForApproval: return BB.Palette.ion
        default: return BB.Palette.textSecondary
        }
    }
}

struct StartParallelTaskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var parts: [String] = ["", ""]
    @State private var presetID: UUID?
    @State private var synthesize = true

    private var cleaned: [String] { parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("What is this for?", text: $title) } header: { Text("Task").bbLabelStyle() }
                Section {
                    ForEach(parts.indices, id: \.self) { index in
                        TextField("Agent \(index + 1) does…", text: $parts[index], axis: .vertical)
                            .lineLimit(1...4)
                            .accessibilityIdentifier("parallel.part.\(index)")
                    }
                    if parts.count < 10 {
                        Button { parts.append("") } label: { Label("Add an agent", systemImage: "plus") }
                    }
                } header: { Text("Agents").bbLabelStyle() } footer: {
                    Text("Each runs as its own Hermes run, in its own session, at the same time (up to \(model.agents.maxConcurrent) at once; more wait for a slot).")
                }
                Section {
                    Picker("Preset", selection: $presetID) {
                        Text("Main assistant").tag(UUID?.none)
                        ForEach(model.hermes.visibleTeammates) { mate in Text(mate.name).tag(UUID?.some(mate.id)) }
                    }
                    Toggle("Combine results at the end", isOn: $synthesize).tint(BB.Palette.signal)
                    Stepper("At once: \(model.agents.maxConcurrent)", value: Binding(get: { model.agents.maxConcurrent },
                                                                                      set: { model.agents.maxConcurrent = $0 }), in: 1...10)
                } footer: {
                    Text("Hermes allows 10 concurrent runs by default (gateway.api_server.max_concurrent_runs). Brainbox waits and retries if it's busy, without starting anything twice.")
                }
            }
            .navigationTitle("Parallel agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let mate = presetID.flatMap { model.hermes.teammate($0) } ?? model.hermes.activeTeammate
                        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? cleaned.joined(separator: " · ") : title
                        model.agents.start(title: String(name.prefix(80)),
                                           prompts: cleaned.map { (title: String($0.prefix(40)), prompt: $0, instructions: mate.runInstructions, model: mate.model) },
                                           synthesize: synthesize)
                        dismiss()
                    }
                    .disabled(cleaned.isEmpty || !model.isHermes)
                    .accessibilityIdentifier("parallel.start")
                }
            }
        }
    }
}
