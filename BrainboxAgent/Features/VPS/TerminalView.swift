import SwiftUI
import UIKit
import BrainboxCore

struct TerminalLine: Identifiable, Hashable {
    enum Kind: Hashable { case command, stdout, stderr, system }
    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
@Observable
final class TerminalSessionModel: Identifiable {
    let id = UUID()
    var session: TerminalSession?
    var lines: [TerminalLine] = []
    var history = CommandHistory()
    var isRunning = false
    var lastExitCode: Int?
    var error: AgentError?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    var title: String { session.map { "\($0.title) · \(FilePath.lastComponent(of: $0.workingDirectory))" } ?? "Session" }

    func open(using provider: TerminalProvider, isMock: Bool) async {
        do {
            session = try await provider.openSession()
            if isMock { lines.append(TerminalLine(kind: .system, text: MockShell.banner)) }
        } catch {
            self.error = error.asAgentError
        }
    }

    func run(_ command: String, using provider: TerminalProvider) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning, let session else { return }
        history.record(trimmed)
        if trimmed == "clear" { lines.removeAll(); return }
        lines.append(TerminalLine(kind: .command, text: trimmed))
        isRunning = true
        lastExitCode = nil
        runTask = Task { [weak self] in
            do {
                for try await output in provider.run(trimmed, in: session.id) {
                    guard let self else { return }
                    switch output {
                    case .stdout(let text): self.append(.stdout, text)
                    case .stderr(let text): self.append(.stderr, text)
                    case .exit(let code): self.lastExitCode = code
                    }
                }
            } catch {
                self?.append(.stderr, error.asAgentError.title + ": " + error.asAgentError.message + "\n")
            }
            self?.isRunning = false
        }
    }

    func cancel(using provider: TerminalProvider) {
        guard let session, isRunning else { return }
        Task { await provider.cancel(sessionID: session.id) }
    }

    func close(using provider: TerminalProvider) {
        runTask?.cancel()
        if let session { Task { await provider.closeSession(session.id) } }
    }

    private func append(_ kind: TerminalLine.Kind, _ text: String) {
        guard !text.isEmpty else { return }
        // Merge consecutive stdout chunks into one line block for performance.
        if let last = lines.last, last.kind == kind, kind != .command, !last.text.hasSuffix("\n") || lines.count > 400 {
            lines[lines.count - 1].text += text
        } else {
            lines.append(TerminalLine(kind: kind, text: text))
        }
        if lines.count > 1_000 { lines.removeFirst(lines.count - 1_000) }
    }

    var transcript: String {
        lines.map { $0.kind == .command ? "$ " + $0.text + "\n" : $0.text }.joined()
    }
}

struct TerminalView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [TerminalSessionModel] = []
    @State private var selected: UUID?
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var current: TerminalSessionModel? { sessions.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            sessionStrip
            if let current {
                output(for: current)
                inputBar(for: current)
            } else {
                Spacer()
                ProgressView().tint(BB.Palette.signal)
                Spacer()
            }
        }
        .background(BB.Palette.terminalBackground.ignoresSafeArea())
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BB.Palette.terminalBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if let current {
                        Clipboard.copy(current.transcript)
                        model.toasts.show("Transcript copied")
                    }
                } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy transcript")
                Button {
                    withAnimation(Motion.standard) { current?.lines.removeAll() }
                } label: { Image(systemName: "eraser") }
                .accessibilityLabel("Clear display")
            }
        }
        .task {
            if sessions.isEmpty { await addSession() }
            inputFocused = true
        }
        .onDisappear {
            if let provider = model.suite.terminal { sessions.forEach { $0.close(using: provider) } }
        }
    }

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions) { session in
                    Button {
                        withAnimation(Motion.snappy) { selected = session.id }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(session.isRunning ? BB.Palette.signal : (session.session == nil ? BB.Palette.danger : BB.Palette.success)).frame(width: 6, height: 6)
                            Text(session.title).font(BB.Font.monoSmall)
                        }
                        .foregroundStyle(selected == session.id ? BB.Palette.onSignal : BB.Palette.terminalText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selected == session.id ? BB.Palette.signal : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.pressable)
                    .contextMenu {
                        Button(role: .destructive) { closeSession(session) } label: { Label("Close session", systemImage: "xmark") }
                    }
                }
                Button {
                    Task { await addSession() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(BB.Palette.terminalText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("New session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func output(for session: TerminalSessionModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let error = session.error {
                        Text("\(error.title): \(error.message)").foregroundStyle(BB.Palette.danger)
                    }
                    ForEach(session.lines) { line in
                        lineView(line, cwd: session.session?.workingDirectory)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                    HStack(spacing: 6) {
                        if session.isRunning {
                            ProgressView().controlSize(.mini).tint(BB.Palette.signal)
                            Text("running… tap ■ to interrupt").foregroundStyle(BB.Palette.textTertiary)
                        } else if let code = session.lastExitCode {
                            Text("exit \(code)").foregroundStyle(code == 0 ? BB.Palette.success.opacity(0.8) : BB.Palette.danger)
                        }
                    }
                    .font(BB.Font.monoSmall)
                    .id("end")
                }
                .font(BB.Font.mono)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: session.lines.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .animation(Motion.fade, value: session.lines.count)
        }
    }

    @ViewBuilder
    private func lineView(_ line: TerminalLine, cwd: String?) -> some View {
        switch line.kind {
        case .command:
            (Text((cwd.map(FilePath.lastComponent) ?? "~") + " ").foregroundColor(BB.Palette.ion)
             + Text("❯ ").foregroundColor(BB.Palette.signal)
             + Text(line.text).foregroundColor(.white))
                .padding(.top, 6)
        case .stdout:
            Text(line.text).foregroundStyle(BB.Palette.terminalText)
        case .stderr:
            Text(line.text).foregroundStyle(BB.Palette.danger)
        case .system:
            Text(line.text).foregroundStyle(BB.Palette.textTertiary)
        }
    }

    private func inputBar(for session: TerminalSessionModel) -> some View {
        HStack(spacing: 8) {
            Text("❯").font(BB.Font.mono).foregroundStyle(BB.Palette.signal)
            TextField("command", text: $input)
                .font(BB.Font.mono)
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($inputFocused)
                .submitLabel(.go)
                .onSubmit { submit(session) }
                .disabled(session.session == nil || model.suite.terminal == nil)
                .accessibilityIdentifier("terminal.input")
            Button { if let v = session.history.previous() { input = v } } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous command")
            Button { if let v = session.history.next() { input = v } } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next command")
            Button {
                if session.isRunning, let provider = model.suite.terminal { session.cancel(using: provider) } else { submit(session) }
            } label: {
                Image(systemName: session.isRunning ? "stop.fill" : "return")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(BB.Palette.onSignal)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(session.isRunning ? BB.Palette.danger : BB.Palette.signal))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(session.isRunning ? "Interrupt" : "Run")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(BB.Palette.terminalText.opacity(0.7))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        .animation(Motion.snappy, value: session.isRunning)
    }

    private func submit(_ session: TerminalSessionModel) {
        guard let provider = model.suite.terminal else { return }
        let command = input
        input = ""
        session.run(command, using: provider)
        inputFocused = true
    }

    private func addSession() async {
        guard let provider = model.suite.terminal else { return }
        let session = TerminalSessionModel()
        withAnimation(Motion.standard) {
            sessions.append(session)
            selected = session.id
        }
        await session.open(using: provider, isMock: model.isMock)
    }

    private func closeSession(_ session: TerminalSessionModel) {
        if let provider = model.suite.terminal { session.close(using: provider) }
        withAnimation(Motion.standard) {
            sessions.removeAll { $0.id == session.id }
            if selected == session.id { selected = sessions.last?.id }
        }
    }
}
