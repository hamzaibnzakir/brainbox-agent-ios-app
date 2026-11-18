import HermesKit
import Observation
import SwiftTerm
import SwiftUI
import UIKit

/// A real shell on the server over the same SSH connection (a PTY channel).
///
/// When the server has tmux, the shell runs inside a tmux session named `brainbox`: it keeps running
/// when you leave the terminal, lock the phone or lose the connection, and Brainbox re-attaches to
/// it — same programs, same output — as soon as it's connected again. Without tmux it's a plain shell.
@MainActor
@Observable
final class ShellSession {
    enum Phase: Equatable { case idle, opening, open, reattaching, closed(String) }
    var phase: Phase = .idle
    /// Running inside tmux (survives disconnects).
    private(set) var persistent = false
    /// The next key is sent with Ctrl / Alt (sticky modifiers from the key bar).
    var ctrlArmed = false
    var altArmed = false
    var fontSize: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "terminal.fontSize") as? Double ?? 13) {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "terminal.fontSize") }
    }
    var onOutput: (([UInt8]) -> Void)?
    /// Cleared screen before re-attaching, so tmux redraws cleanly.
    var onReset: (() -> Void)?
    private var stream: SSHByteStream?
    private var reader: Task<Void, Never>?
    private var size = (cols: 80, rows: 24)
    private var userClosed = false

    static let tmuxCommand = "tmux new-session -A -s brainbox"

    func open(model: AppModel) async {
        userClosed = false
        phase = phase == .reattaching ? .reattaching : .opening
        do {
            let client = try await model.client()
            let hasTmux = model.preferences.persistentTerminal
                && ((try? await client.ssh.exec("command -v tmux >/dev/null 2>&1 && echo yes", timeout: 10).output.contains("yes")) ?? false)
            persistent = hasTmux
            if hasTmux { onReset?() }
            let stream = try await client.ssh.openShell(columns: size.cols, rows: size.rows,
                                                        command: hasTmux ? Self.tmuxCommand : nil)
            self.stream?.close()
            self.stream = stream
            phase = .open
            reader?.cancel()
            reader = Task { [weak self] in
                var exited = false
                do {
                    for try await event in stream.events {
                        switch event {
                        case .data(let d), .stderr(let d):
                            let bytes = [UInt8](d)
                            await MainActor.run { self?.onOutput?(bytes) }
                        case .exit(let code):
                            exited = true
                            await MainActor.run { self?.ended("Shell exited (\(code)).", connectionLost: false) }
                        case .eof:
                            break
                        }
                    }
                    if !exited { await MainActor.run { self?.ended("Shell closed.", connectionLost: true) } }
                } catch {
                    await MainActor.run { self?.ended(error.localizedDescription, connectionLost: true) }
                }
            }
        } catch {
            phase = .closed(error.localizedDescription)
        }
    }

    /// The link dropped: a tmux session is still running on the server, so wait to re-attach.
    private func ended(_ reason: String, connectionLost: Bool) {
        guard phase == .open, !userClosed else { return }
        stream = nil
        phase = connectionLost && persistent ? .reattaching : .closed(reason)
    }

    /// Called when Brainbox is connected again.
    func reattachIfNeeded(model: AppModel) {
        guard phase == .reattaching else { return }
        Task { await open(model: model) }
    }

    /// Keystrokes go out in the exact order they were typed (no racing tasks); sticky Ctrl/Alt apply
    /// to the next key.
    func input(_ bytes: [UInt8]) {
        var out = bytes
        if ctrlArmed, let first = out.first {
            ctrlArmed = false
            let lower = first | 0x20
            if (0x61...0x7a).contains(lower) { out[0] = lower & 0x1f }          // a…z → ^A…^Z
            else if first == 0x20 { out[0] = 0 }                                 // ^Space
            else if (0x5b...0x5f).contains(first) { out[0] = first & 0x1f }      // ^[ ^\ ^] ^^ ^_
        }
        if altArmed { altArmed = false; out = [0x1b] + out }
        guard let stream else { return }
        let sent = stream.send(Data(out)) { [weak self] error in
            Task { @MainActor in self?.ended("Lost the shell: \(error.localizedDescription)", connectionLost: true) }
        }
        if !sent { ended("The shell connection closed — that input wasn't sent.", connectionLost: true) }
    }

    func send(_ text: String) { input(Array(text.utf8)) }

    /// Pastes as one block (bracketed paste), so a multi-line paste isn't run line by line.
    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let block = text.contains("\n") ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
        ctrlArmed = false; altArmed = false
        input(Array(block.utf8))
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        stream?.resize(columns: cols, rows: rows)
    }

    /// Leaves the terminal. A tmux session keeps running on the server; a plain shell ends.
    func detach() {
        userClosed = true
        reader?.cancel()
        stream?.close()
        stream = nil
        phase = .idle
    }

    /// Ends the tmux session on the server too.
    func killSession(model: AppModel) async {
        detach()
        _ = try? await model.client().ssh.exec("tmux kill-session -t brainbox 2>/dev/null; true", timeout: 10)
    }
}

struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @State private var authorized = false
    private var session: ShellSession { model.shell }

    var body: some View {
        VStack(spacing: 0) {
            switch session.phase {
            case .idle, .opening:
                ProgressView("Opening a shell over SSH…").tint(.white).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .open, .reattaching:
                ZStack(alignment: .top) {
                    SwiftTermView(session: session)
                    if session.phase == .reattaching {
                        Label("Reconnecting — your session is still running on the server", systemImage: "arrow.triangle.2.circlepath")
                            .font(DS.F.caption).foregroundStyle(.white)
                            .padding(.horizontal, DS.S.m).padding(.vertical, DS.S.s)
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(.top, DS.S.s)
                    }
                }
                keyBar
            case .closed(let reason):
                VStack(spacing: DS.S.m) {
                    Image(systemName: "terminal").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.5))
                    Text(reason).font(DS.F.small).foregroundStyle(Color.white.opacity(0.8)).multilineTextAlignment(.center)
                    Button("New shell") { Task { await session.open(model: model) } }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(DS.S.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: 0x0A0A0C).ignoresSafeArea())
        .navigationTitle(session.persistent ? "Terminal · tmux" : "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: 0x0A0A0C), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { session.paste(UIPasteboard.general.string ?? "") } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    Button { session.fontSize = min(22, session.fontSize + 1) } label: { Label("Bigger text", systemImage: "textformat.size.larger") }
                    Button { session.fontSize = max(9, session.fontSize - 1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                    Divider()
                    if session.persistent {
                        Button(role: .destructive) { Task { await session.killSession(model: model); await session.open(model: model) } } label: {
                            Label("End session and start fresh", systemImage: "xmark.octagon")
                        }
                    } else {
                        Button { session.detach(); Task { await session.open(model: model) } } label: { Label("New shell", systemImage: "plus.rectangle") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            if model.preferences.lockWithFaceID, !authorized {
                authorized = await Biometrics.authenticate(reason: "Open a root shell on your server")
                guard authorized else { session.phase = .closed("Face ID is needed to open the terminal."); return }
            }
            if session.phase == .idle { await session.open(model: model) }
        }
        // Leaving the screen detaches: a tmux session keeps running and is re-attached next time.
        .onDisappear { if !session.persistent { session.detach() } }
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc", "\u{1b}")
                toggle("ctrl", on: session.ctrlArmed) { session.ctrlArmed.toggle() }
                toggle("alt", on: session.altArmed) { session.altArmed.toggle() }
                key("tab", "\t")
                key("↑", "\u{1b}[A"); key("↓", "\u{1b}[B"); key("←", "\u{1b}[D"); key("→", "\u{1b}[C")
                if session.persistent {
                    // tmux: page through the scrollback (copy mode); q leaves it.
                    key("⇞", "\u{02}[\u{1b}[5~"); key("⇟", "\u{1b}[6~"); key("q", "q")
                } else {
                    key("⇞", "\u{1b}[5~"); key("⇟", "\u{1b}[6~")
                }
                key("^C", "\u{03}"); key("^D", "\u{04}"); key("^Z", "\u{1a}"); key("^L", "\u{0c}"); key("^R", "\u{12}")
                key("home", "\u{01}"); key("end", "\u{05}")
                key("|", "|"); key("~", "~"); key("/", "/"); key("-", "-"); key("$", "$")
                Button { session.paste(UIPasteboard.general.string ?? ""); Haptic.tap() } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(KeyCapStyle())
                key("hermes", "hermes ")
            }
            .padding(.horizontal, DS.S.s)
            .padding(.vertical, 6)
        }
        .background(Color(hex: 0x141418))
    }

    private func key(_ label: String, _ sequence: String) -> some View {
        Button(label) { session.send(sequence); Haptic.tap() }.buttonStyle(KeyCapStyle())
    }

    private func toggle(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(label) { action(); Haptic.tap() }.buttonStyle(KeyCapStyle(highlighted: on))
    }
}

/// A terminal key cap.
struct KeyCapStyle: ButtonStyle {
    var highlighted = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(highlighted ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .frame(minWidth: 40, minHeight: 34)
            .background(highlighted ? DS.C.volt : Color.white.opacity(configuration.isPressed ? 0.22 : 0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct SwiftTermView: UIViewRepresentable {
    var session: ShellSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.font = UIFont.monospacedSystemFont(ofSize: session.fontSize, weight: .regular)
        session.onOutput = { [weak view] bytes in view?.feed(byteArray: bytes[...]) }
        session.onReset = { [weak view] in view?.getTerminal().resetToInitialState() }
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        if uiView.font.pointSize != session.fontSize {
            uiView.font = UIFont.monospacedSystemFont(ofSize: session.fontSize, weight: .regular)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: ShellSession
        init(session: ShellSession) { self.session = session }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated { session.input(bytes) }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) { Haptic.tap() }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
