import HermesKit
import Observation
import SwiftTerm
import SwiftUI
import UIKit

/// A real login shell on the server over the same SSH connection (a PTY channel).
@MainActor
@Observable
final class ShellSession {
    enum Phase: Equatable { case idle, opening, open, closed(String) }
    var phase: Phase = .idle
    var onOutput: (([UInt8]) -> Void)?
    private var stream: SSHByteStream?
    private var reader: Task<Void, Never>?
    private var size = (cols: 80, rows: 24)

    func open(model: AppModel) async {
        phase = .opening
        do {
            let client = try await model.client()
            let stream = try await client.ssh.openShell(columns: size.cols, rows: size.rows)
            self.stream = stream
            phase = .open
            reader = Task { [weak self] in
                do {
                    for try await event in stream.events {
                        switch event {
                        case .data(let d), .stderr(let d):
                            let bytes = [UInt8](d)
                            await MainActor.run { self?.onOutput?(bytes) }
                        case .exit(let code):
                            await MainActor.run { self?.phase = .closed("Shell exited (\(code)).") }
                        case .eof:
                            break
                        }
                    }
                    await MainActor.run { if self?.phase == .open { self?.phase = .closed("Shell closed.") } }
                } catch {
                    await MainActor.run { self?.phase = .closed(error.localizedDescription) }
                }
            }
        } catch {
            phase = .closed(error.localizedDescription)
        }
    }

    func input(_ bytes: [UInt8]) {
        guard let stream else { return }
        Task { try? await stream.write(Data(bytes)) }
    }

    func send(_ text: String) { input(Array(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        stream?.resize(columns: cols, rows: rows)
    }

    func close() {
        reader?.cancel()
        stream?.close()
        stream = nil
        phase = .idle
    }
}

struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @State private var session = ShellSession()
    @State private var authorized = false

    var body: some View {
        VStack(spacing: 0) {
            switch session.phase {
            case .idle, .opening:
                ProgressView("Opening a shell over SSH…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .open:
                SwiftTermView(session: session)
                keyBar
            case .closed(let reason):
                VStack(spacing: DS.S.m) {
                    Text(reason).font(DS.F.small).foregroundStyle(Color.white.opacity(0.8))
                    Button("New shell") { Task { await session.open(model: model) } }.buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: 0x0B0C0F).ignoresSafeArea())
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: 0x0B0C0F), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if model.preferences.lockWithFaceID, !authorized {
                authorized = await Biometrics.authenticate(reason: "Open a root shell on your server")
                guard authorized else { session.phase = .closed("Face ID is needed to open the terminal."); return }
            }
            if session.phase == .idle { await session.open(model: model) }
        }
        .onDisappear { session.close() }
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.S.s) {
                key("esc", "\u{1b}")
                key("tab", "\t")
                key("^C", "\u{03}")
                key("^D", "\u{04}")
                key("^L", "\u{0c}")
                key("↑", "\u{1b}[A")
                key("↓", "\u{1b}[B")
                key("←", "\u{1b}[D")
                key("→", "\u{1b}[C")
                key("|", "|")
                key("~", "~")
                key("/", "/")
                key("hermes", "hermes ")
            }
            .padding(.horizontal, DS.S.s)
            .padding(.vertical, DS.S.s)
        }
        .background(Color(hex: 0x16171C))
    }

    private func key(_ label: String, _ sequence: String) -> some View {
        Button(label) { session.send(sequence); Haptic.tap() }
            .font(DS.F.monoSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.S.s + 4)
            .frame(minWidth: 44, minHeight: 36)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
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
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        session.onOutput = { [weak view] bytes in view?.feed(byteArray: bytes[...]) }
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

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
