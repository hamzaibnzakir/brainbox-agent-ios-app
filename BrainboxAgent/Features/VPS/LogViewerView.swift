import SwiftUI
import UIKit
import BrainboxCore

/// Live logs. "Clear" only empties this on-device viewer buffer; nothing is
/// ever sent to the server that could delete or rotate real logs.
struct LogViewerView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [LogEntry] = []
    @State private var filter = LogFilter()
    @State private var paused = false
    @State private var buffered: [LogEntry] = []
    @State private var error: AgentError?
    @State private var streamID = UUID()
    private let maxEntries = 2_000

    private var visible: [LogEntry] { entries.filter(filter.matches) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let error {
                ErrorBanner(error: error, retry: { streamID = UUID() }, dismiss: { self.error = nil })
                    .padding(.horizontal, BB.Space.gutter)
                    .padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
                List {
                    ForEach(visible) { entry in
                        LogRow(entry: entry)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                Button {
                                    Clipboard.copy("\(WireCoding.formatDate(entry.timestamp)) \(entry.level.shortLabel) [\(entry.source)] \(entry.message)")
                                    model.toasts.show("Copied")
                                } label: { Label("Copy line", systemImage: "doc.on.doc") }
                            }
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    Color.clear.frame(height: 1).id("tail").listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(BB.Palette.terminalBackground)
                .environment(\.defaultMinListRowHeight, 10)
                .onChange(of: entries.count) { _, _ in
                    if !paused { proxy.scrollTo("tail", anchor: .bottom) }
                }
                .overlay {
                    if visible.isEmpty {
                        Text(entries.isEmpty ? "Waiting for log lines…" : "No lines match the filter")
                            .font(BB.Font.mono)
                            .foregroundStyle(BB.Palette.textTertiary)
                    }
                }
            }
        }
        .background(ScreenBackground())
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter.query, prompt: "Filter lines")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(Motion.snappy) {
                        paused.toggle()
                        if !paused { flushBuffer() }
                    }
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(paused ? "Resume" : "Pause")
                Menu {
                    Button {
                        Clipboard.copy(visible.map { "\(WireCoding.formatDate($0.timestamp)) \($0.level.shortLabel) [\($0.source)] \($0.message)" }.joined(separator: "\n"))
                        model.toasts.show("Copied \(visible.count) lines")
                    } label: { Label("Copy visible lines", systemImage: "doc.on.doc") }
                    Button(role: .destructive) {
                        withAnimation(Motion.standard) { entries.removeAll(); buffered.removeAll() }
                    } label: { Label("Clear viewer (server logs untouched)", systemImage: "eraser") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: streamID) { await stream() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LogCategory.allCases) { category in
                        Chip(title: category.displayName, isSelected: filter.categories.contains(category)) {
                            if filter.categories.contains(category) {
                                if filter.categories.count > 1 { filter.categories.remove(category) }
                            } else {
                                filter.categories.insert(category)
                            }
                        }
                    }
                }
                .padding(.horizontal, BB.Space.gutter)
            }
            HStack {
                Text("Min level").bbLabelStyle()
                Picker("Minimum level", selection: $filter.minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in Text(level.rawValue.capitalized).tag(level) }
                }
                .pickerStyle(.menu)
                .tint(BB.Palette.signalText)
                Spacer()
                if paused {
                    Badge(text: "Paused · \(buffered.count) new", color: BB.Palette.warning)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 6) {
                        StatusDot(tone: .live, size: 6)
                        Text("Live").font(BB.Font.label).foregroundStyle(BB.Palette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, BB.Space.gutter)
            .animation(Motion.snappy, value: paused)
        }
        .padding(.vertical, 8)
    }

    private func stream() async {
        guard let logs = model.suite.logs else {
            error = .providerUnavailable(detail: "This backend doesn't stream logs.")
            return
        }
        error = nil
        if entries.isEmpty, let recent = try? await logs.recent(limit: 40) {
            entries = recent
        }
        do {
            for try await entry in logs.stream(categories: Set(LogCategory.allCases)) {
                if paused {
                    buffered.append(entry)
                    if buffered.count > maxEntries { buffered.removeFirst(buffered.count - maxEntries) }
                } else {
                    withAnimation(Motion.fade) { append([entry]) }
                }
            }
        } catch {
            if !(error is CancellationError) { self.error = error.asAgentError }
        }
    }

    private func flushBuffer() {
        append(buffered)
        buffered.removeAll()
    }

    private func append(_ new: [LogEntry]) {
        entries.append(contentsOf: new)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }
}

struct LogRow: View {
    let entry: LogEntry

    private var levelColor: Color {
        switch entry.level {
        case .debug: return BB.Palette.textTertiary
        case .info: return BB.Palette.ion
        case .notice: return BB.Palette.success
        case .warning: return BB.Palette.warning
        case .error, .critical: return BB.Palette.danger
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .foregroundStyle(BB.Palette.textTertiary)
            Text(entry.level.shortLabel)
                .foregroundStyle(levelColor)
                .fontWeight(entry.level >= .error ? .bold : .regular)
            Text(entry.source).foregroundStyle(BB.Palette.textSecondary)
            Text(entry.message)
                .foregroundStyle(entry.level >= .error ? BB.Palette.danger : BB.Palette.terminalText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(BB.Font.monoSmall)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(entry.level >= .error ? BB.Palette.danger.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
    }
}

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @State private var processes: [ProcessEntry] = []
    @State private var error: AgentError?
    @State private var sortByMemory = false

    var body: some View {
        List {
            if let error {
                ErrorBanner(error: error, retry: { Task { await load() } }).listRowBackground(Color.clear)
            }
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, process in
                HStack(spacing: 12) {
                    Text("\(process.pid)").font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(process.name).font(BB.Font.mono).foregroundStyle(BB.Palette.textPrimary)
                        Text(process.user).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f%%", process.cpu)).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textPrimary)
                        Text(ByteFormatter.string(process.memoryBytes)).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    }
                }
                .listRowBackground(BB.Palette.surface)
                .bbEntrance(index: index)
            }
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Processes")
        .toolbar {
            Button { withAnimation(Motion.standard) { sortByMemory.toggle() } } label: {
                Text(sortByMemory ? "By memory" : "By CPU").font(BB.Font.subhead)
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var sorted: [ProcessEntry] {
        processes.sorted { sortByMemory ? $0.memoryBytes > $1.memoryBytes : $0.cpu > $1.cpu }
    }

    private func load() async {
        guard let vps = model.suite.vps else { error = .providerUnavailable(detail: "No server connected."); return }
        do {
            let result = try await vps.processes()
            withAnimation(Motion.standard) { processes = result; error = nil }
        } catch {
            self.error = error.asAgentError
        }
    }
}
