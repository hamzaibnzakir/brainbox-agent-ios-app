import SwiftUI
import UIKit
import SwiftTerm
import BrainboxCore

/// One interactive shell on the VPS through the Brainbox proxy's PTY WebSocket.
/// Keystrokes go straight to the shell (no approval step); commands that look
/// destructive get a warning first. A dropped connection reattaches to the same
/// shell automatically, and the server replays recent output.
@MainActor
@Observable
final class PtySessionModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected(user: String)
        case reconnecting(attempt: Int)
        case ended(code: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var sessionID: String?
    /// A command waiting for the user to confirm a risk warning.
    private(set) var pendingWarning: String?

    @ObservationIgnored var onOutput: ((String) -> Void)?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var client: HermesAPIClient?
    @ObservationIgnored private var size = (cols: 80, rows: 24)
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var lineBuffer = ""
    @ObservationIgnored private var lineReliable = true
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    func start(client: HermesAPIClient, cols: Int, rows: Int) {
        guard phase == .idle || isFinished else { return }
        self.client = client
        size = (cols, rows)
        closing = false
        connect(reattach: false)
    }

    var isFinished: Bool {
        switch phase {
        case .ended, .failed: return true
        default: return false
        }
    }

    private func connect(reattach: Bool) {
        guard let client else { return }
        let socketInfo = client.terminalSocket(session: reattach ? sessionID : nil, cols: size.cols, rows: size.rows)
        var request = URLRequest(url: socketInfo.url, timeoutInterval: 20)
        for (name, value) in socketInfo.headers { request.setValue(value, forHTTPHeaderField: name) }
        if !reattach { phase = .connecting }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        socket = task
        task.resume()
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        var reconnectAttempt = 0
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                reconnectAttempt = 0
                guard case .string(let text) = message, let frame = TerminalServerFrame.decode(text) else { continue }
                handle(frame)
                if case .exit = frame { return }
            } catch {
                guard !closing, socket === task else { return }
                if case .connecting = phase {
                    phase = .failed(Self.describe(error, task: task))
                    return
                }
                // Dropped mid-session: reattach to the same shell.
                guard sessionID != nil, reconnectAttempt < 5 else {
                    phase = .failed("The connection to the terminal was lost.")
                    return
                }
                reconnectAttempt += 1
                phase = .reconnecting(attempt: reconnectAttempt)
                try? await Task.sleep(nanoseconds: UInt64(reconnectAttempt) * 1_000_000_000)
                guard !closing, !Task.isCancelled else { return }
                connect(reattach: true)
                return
            }
        }
    }

    private static func describe(_ error: Error, task: URLSessionWebSocketTask) -> String {
        if let response = task.response as? HTTPURLResponse {
            switch response.statusCode {
            case 401: return "The server rejected this device's token."
            case 403: return "This device isn't allowed to open a terminal. Set terminal = true for it on the server."
            case 404: return "The terminal is turned off on the server, or that session has ended."
            case 429: return "Too many terminals open. Close one first."
            case 503: return "The server couldn't start a shell. Check the terminal account (docs/TERMINAL.md)."
            default: return "The server answered HTTP \(response.statusCode)."
            }
        }
        return error.asAgentError.message
    }

    private func handle(_ frame: TerminalServerFrame) {
        switch frame {
        case .ready(let id, let user, let reattached, _, _):
            sessionID = id
            phase = .connected(user: user)
            if reattached { sendFrame(.resize(cols: size.cols, rows: size.rows)) }
        case .output(let text):
            onOutput?(text)
        case .exit(let code):
            phase = .ended(code: code)
            sessionID = nil
        case .error(let code, let message):
            if code == "taken_over" {
                closing = true
                phase = .failed("This terminal was opened on another connection.")
            } else {
                onOutput?("\r\n[\(message)]\r\n")
            }
        }
    }

    // MARK: Input

    /// Bytes typed or pasted into the terminal.
    func input(_ bytes: [UInt8]) {
        guard case .connected = phase else { return }
        var outgoing: [UInt8] = []
        for byte in bytes {
            switch byte {
            case 0x0d, 0x0a:   // Enter: check the finished line before sending it
                if lineReliable, let warning = CommandRisk.warning(for: lineBuffer) {
                    flush(outgoing)
                    outgoing = []
                    pendingWarning = warning
                    return   // anything typed after Enter in the same chunk is dropped with the line
                }
                outgoing.append(byte)
                lineBuffer = ""
                lineReliable = true
            case 0x7f, 0x08:
                if !lineBuffer.isEmpty { lineBuffer.removeLast() }
                outgoing.append(byte)
            case 0x03, 0x15:   // Ctrl-C / Ctrl-U clear the line
                lineBuffer = ""
                lineReliable = true
                outgoing.append(byte)
            case 0x1b:         // escape sequences (arrows, history): the line is no longer known
                lineReliable = false
                outgoing.append(byte)
            default:
                if byte >= 0x20 { lineBuffer.append(Character(UnicodeScalar(byte))) }
                outgoing.append(byte)
            }
        }
        flush(outgoing)
    }

    func confirmPending(run: Bool) {
        guard pendingWarning != nil else { return }
        pendingWarning = nil
        if run {
            flush([0x0d])
        } else {
            flush([0x15])  // Ctrl-U: clear the typed line in the shell
        }
        lineBuffer = ""
        lineReliable = true
    }

    private func flush(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        sendFrame(.input(String(decoding: bytes, as: UTF8.self)))
    }

    func resize(cols: Int, rows: Int) {
        size = (max(10, min(500, cols)), max(4, min(300, rows)))
        if case .connected = phase { sendFrame(.resize(cols: size.cols, rows: size.rows)) }
    }

    func interrupt() {
        lineBuffer = ""
        lineReliable = true
        sendFrame(.interrupt)
    }

    /// Detach (the shell keeps running for a few minutes and can be reattached).
    func detach() {
        closing = true
        socket?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
    }

    /// Ends the shell on the server.
    func close() {
        sendFrame(.close)
        closing = true
        Task { [socket] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            socket?.cancel(with: .normalClosure, reason: nil)
        }
        receiveTask?.cancel()
        sessionID = nil
        phase = .ended(code: 0)
    }

    func reconnect() {
        guard client != nil else { return }
        closing = false
        if sessionID != nil {
            phase = .reconnecting(attempt: 1)
            connect(reattach: true)
        } else {
            connect(reattach: false)
        }
    }

    private func sendFrame(_ frame: TerminalClientFrame) {
        socket?.send(.string(frame.json)) { _ in }
    }
}

/// The SwiftTerm emulator (full VT100/xterm: colours, cursor, full-screen apps).
struct SwiftTermView: UIViewRepresentable {
    let model: PtySessionModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(BB.Palette.terminalBackground)
        view.nativeForegroundColor = UIColor(BB.Palette.terminalText)
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.accessibilityIdentifier = "pty.terminal"
        model.onOutput = { [weak view] text in view?.feed(text: text) }
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let model: PtySessionModel
        init(model: PtySessionModel) { self.model = model }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { model.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated { model.input(bytes) }
        }

        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Server tab → Terminal (Hermes mode, through the Brainbox proxy).
struct PtyTerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session = PtySessionModel()
    @State private var status: BrainboxTerminalStatus?
    @State private var statusError: String?
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                BB.Palette.terminalBackground.ignoresSafeArea(edges: .bottom)
                if started {
                    SwiftTermView(model: session)
                } else {
                    gate
                }
            }
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if started {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { session.interrupt() } label: { Text("^C").font(BB.Font.mono) }
                        .accessibilityLabel("Interrupt (Control-C)")
                        .accessibilityIdentifier("pty.interrupt")
                    Menu {
                        Button { session.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { session.close() } label: { Label("End shell", systemImage: "xmark.octagon") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task { await loadStatus() }
        .onDisappear { if !session.isFinished { session.detach() } }
        .alert("Run this command?", isPresented: Binding(get: { session.pendingWarning != nil }, set: { _ in })) {
            Button("Run anyway", role: .destructive) { session.confirmPending(run: true) }
            Button("Don't run", role: .cancel) { session.confirmPending(run: false) }
        } message: {
            Text((session.pendingWarning ?? "") + " It runs on your server as the terminal account and can't be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(tone: tone, size: 7)
            Text(phaseText).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(1)
            Spacer()
            if case .failed = session.phase {
                Button("Retry") { session.reconnect() }.font(BB.Font.caption)
            } else if case .ended = session.phase, let client = model.hermes.client {
                Button("New shell") { session.start(client: client, cols: 80, rows: 24) }.font(BB.Font.caption)
            }
        }
        .padding(.horizontal, BB.Space.gutter)
        .padding(.vertical, 8)
        .background(BB.Palette.surface)
        .accessibilityIdentifier("pty.status")
    }

    private var tone: StatusTone {
        switch session.phase {
        case .connected: return .live
        case .connecting, .reconnecting: return .busy
        case .failed: return .danger
        case .idle, .ended: return .idle
        }
    }

    private var phaseText: String {
        switch session.phase {
        case .idle: return status?.available == true ? "Ready · runs as \(status?.user ?? "the terminal account")" : "Not available"
        case .connecting: return "Connecting…"
        case .connected(let user): return "Connected as \(user) · private over Tailscale"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))…"
        case .ended(let code): return "Shell ended (exit \(code))"
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var gate: some View {
        VStack(spacing: 14) {
            if let status, status.available {
                Image(systemName: "terminal").font(.system(size: 34)).foregroundStyle(BB.Palette.terminalText)
                Text("A real shell on your server, as \(status.user ?? "the terminal account") (not root).")
                    .font(BB.Font.callout).foregroundStyle(BB.Palette.terminalText).multilineTextAlignment(.center)
                Text("Commands run immediately. Brainbox warns before ones that look destructive.")
                    .font(BB.Font.caption).foregroundStyle(BB.Palette.terminalText.opacity(0.7)).multilineTextAlignment(.center)
                Button {
                    Task {
                        guard await model.gate.authorize(.openTerminal), let client = model.hermes.client else { return }
                        started = true
                        session.start(client: client, cols: 80, rows: 24)
                    }
                } label: {
                    Text("Open terminal").font(BB.Font.headline).foregroundStyle(BB.Palette.onSignal)
                        .padding(.horizontal, 24).frame(height: 46)
                        .background(Capsule().fill(BB.Palette.signal))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("pty.open")
            } else {
                Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(BB.Palette.terminalText.opacity(0.8))
                Text(status?.reason ?? statusError ?? "Checking…")
                    .font(BB.Font.callout).foregroundStyle(BB.Palette.terminalText).multilineTextAlignment(.center)
                Text("Setup and rollback steps: docs/TERMINAL.md")
                    .font(BB.Font.caption).foregroundStyle(BB.Palette.terminalText.opacity(0.6))
            }
        }
        .padding(28)
    }

    private func loadStatus() async {
        guard let client = model.hermes.client else {
            statusError = "Connect to Hermes through the Brainbox proxy first."
            return
        }
        guard model.hermes.gatewayInfo != nil else {
            statusError = "The terminal needs the Brainbox proxy; this connection goes straight to Hermes."
            return
        }
        do {
            status = try await client.terminalStatus()
        } catch {
            statusError = error.asAgentError.message
        }
    }
}
