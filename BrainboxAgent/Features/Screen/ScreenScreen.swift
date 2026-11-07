import BrainboxCore
import HermesKit
import SwiftUI
import UIKit
import WebKit

/// Hermes' own computer (its Bot Screen): watch the bot's browser live, take over for a login,
/// CAPTCHA, 2FA or payment step, then hand back so it continues with what you signed in to.
/// The same screen and the same control lock as Hermes Desktop's Screen pane.
struct ScreenScreen: View {
    @Environment(AppModel.self) private var model
    @State private var session = ScreenSession()
    @State private var typed = ""
    @State private var hideTyping = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            content
            if session.inControl, session.phase == .live { keyboardBar }
        }
        .background(Self.ink.ignoresSafeArea())
        .navigationTitle("Hermes' screen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Self.ink, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)   // without it the dark scheme isn't applied
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { menu }
        .overlay(alignment: .top) { noticeView }
        .task { await session.open(model: model) }
        .onDisappear { session.close() }
        .onChange(of: model.lastEvent) { _, event in
            if let event { session.handle(event) }
        }
        .onChange(of: model.connection) { _, state in
            // A new gateway connection needs a new viewer (viewer ids don't survive reconnects).
            if state.isConnected, session.phase != .live { Task { await session.open(model: model) } }
        }
    }

    static let ink = Color(hex: 0x0B0C0F)
    static let bar = Color(hex: 0x16171C)

    // MARK: Header

    private var controlBar: some View {
        HStack(spacing: DS.S.s + 4) {
            leaseChip
            Spacer(minLength: 0)
            controlButton
        }
        .padding(.horizontal, DS.S.m)
        .padding(.vertical, DS.S.s + 2)
        .background(Self.bar)
    }

    @ViewBuilder private var leaseChip: some View {
        if session.inControl {
            Pill(text: "You're in control", color: DS.C.bad, symbol: "hand.raised.fill")
        } else if session.someoneElseInControl {
            Pill(text: "Someone else is in control", color: DS.C.warn, symbol: "person.fill")
        } else if session.phase == .live {
            Pill(text: "Hermes is in control", color: Color(hex: 0x8C82FF), symbol: "sparkles")
        } else {
            Pill(text: phaseLabel, color: Color.white.opacity(0.7))
        }
    }

    private var phaseLabel: String {
        switch session.phase {
        case .checking: return "Checking"
        case .connecting: return "Connecting"
        case .starting: return "Starting the screen"
        case .live: return "Live"
        case .stopped: return "Screen off"
        case .notInstalled: return "Not installed"
        case .unsupported: return "Unavailable"
        case .failed: return "Problem"
        }
    }

    @ViewBuilder private var controlButton: some View {
        if session.phase == .live {
            if session.inControl {
                Button { Task { await session.handBack() } } label: {
                    Label("Hand back", systemImage: "arrow.uturn.backward.circle.fill")
                }
                .buttonStyle(ScreenButtonStyle(tint: DS.C.good))
                .disabled(session.busy)
            } else {
                Button { Task { await session.takeOver() } } label: {
                    Label("Take over", systemImage: "hand.tap.fill")
                }
                .buttonStyle(ScreenButtonStyle(tint: DS.C.bad))
                .disabled(session.busy)
            }
        }
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .live, .connecting, .starting:
            liveView
        case .checking:
            ProgressView("Checking Hermes' screen…").tint(.white).foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unsupported(let message):
            infoView(symbol: "display.trianglebadge.exclamationmark", title: "Screen not available", text: message)
        case .notInstalled(let command, let missing):
            installView(command: command, missing: missing)
        case .stopped(let blocker):
            stoppedView(blocker: blocker)
        case .failed(let message):
            VStack(spacing: DS.S.m) {
                ErrorBanner(message: message) { Task { await session.open(model: model) } }
            }
            .padding(DS.S.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var liveView: some View {
        ZStack {
            ScreenWebView(session: session)
                .overlay(
                    Rectangle().stroke(session.inControl ? DS.C.bad : Color.clear, lineWidth: 3)
                )
            if session.phase != .live {
                VStack(spacing: DS.S.s) {
                    ProgressView().tint(.white)
                    Text(session.phase == .starting ? "Starting the screen…" : "Connecting to the screen…")
                        .font(DS.F.small).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoView(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: DS.S.m) {
            Image(systemName: symbol).font(.system(size: 40, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Text(title).font(DS.F.bodyStrong).foregroundStyle(.white)
            Text(text).font(DS.F.small).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
        }
        .padding(DS.S.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installView(command: String?, missing: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            Text("The screen needs a few packages on the server").font(DS.F.bodyStrong).foregroundStyle(.white)
            Text("Hermes runs a private desktop (TigerVNC + Xfce) for the bot's browser. Install them once on the server, then come back. Missing: \(missing.joined(separator: ", ")).")
                .font(DS.F.small).foregroundStyle(.white.opacity(0.75))
            if let command, !command.isEmpty {
                Text(command)
                    .font(DS.F.monoSmall).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(DS.S.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                Button("Copy command") { UIPasteboard.general.string = command; model.toast = "Copied" }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Button("Check again") { Task { await session.refresh() } }.buttonStyle(SecondaryButtonStyle(tint: .white))
        }
        .padding(DS.S.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func stoppedView(blocker: String?) -> some View {
        VStack(spacing: DS.S.m) {
            Image(systemName: "display").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Text("The screen is off").font(DS.F.bodyStrong).foregroundStyle(.white)
            Text(blocker ?? "Start it to watch Hermes' browser live. It stops again by itself when nobody has used it for a while.")
                .font(DS.F.small).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            Button { Task { await session.startScreen() } } label: {
                if session.busy { ProgressView().tint(.white) } else { Text("Start screen") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(blocker != nil || session.busy)
            .frame(maxWidth: 260)
        }
        .padding(DS.S.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Keyboard

    private var keyboardBar: some View {
        VStack(spacing: DS.S.s) {
            HStack(spacing: DS.S.s) {
                Group {
                    if hideTyping {
                        SecureField("Type on the screen", text: $typed)
                    } else {
                        TextField("Type on the screen", text: $typed)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .submitLabel(.send)
                .onSubmit { sendTyped(enter: true) }
                .font(DS.F.small)
                .foregroundStyle(.white)
                .padding(.horizontal, DS.S.m)
                .frame(height: 40)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button { hideTyping.toggle() } label: {
                    Image(systemName: hideTyping ? "eye.slash.fill" : "eye.fill")
                }
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel(hideTyping ? "Show what I type" : "Hide what I type")

                Button { sendTyped(enter: false) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                    .foregroundStyle(Color(hex: 0x8C82FF))
                    .disabled(typed.isEmpty)
                    .accessibilityLabel("Type it without pressing Enter")
            }
            keyRow
        }
        .padding(.horizontal, DS.S.m)
        .padding(.vertical, DS.S.s)
        .background(Self.bar)
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.S.s) {
                key("↵", "Enter")
                key("⌫", "Backspace")
                key("tab", "Tab")
                key("esc", "Escape")
                key("←", "ArrowLeft")
                key("↑", "ArrowUp")
                key("↓", "ArrowDown")
                key("→", "ArrowRight")
                Button("paste") {
                    // Typed into whatever has focus on the screen (a paste into the remote clipboard
                    // would still need Ctrl+V there).
                    if let text = UIPasteboard.general.string { session.type(text) }
                }
                .modifier(KeyCap())
            }
        }
    }

    private func key(_ label: String, _ name: String) -> some View {
        Button(label) { session.key(name); Haptic.tap() }.modifier(KeyCap())
    }

    private func sendTyped(enter: Bool) {
        let text = typed
        typed = ""
        if !text.isEmpty { session.type(text) }
        if enter { session.key("Enter") }
    }

    // MARK: Menu & notices

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { session.setFit(!session.fitToScreen) } label: {
                    Label(session.fitToScreen ? "Actual size (pan)" : "Fit to screen",
                          systemImage: session.fitToScreen ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                if session.someoneElseInControl {
                    Button(role: .destructive) { Task { await session.handBack(force: true) } } label: {
                        Label("Hand back (force)", systemImage: "arrow.uturn.backward")
                    }
                }
                Button { Task { await session.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                if session.status?.running == true {
                    Button(role: .destructive) { Task { await session.stopScreen() } } label: { Label("Turn screen off", systemImage: "power") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18, weight: .semibold))
            }
        }
    }

    @ViewBuilder private var noticeView: some View {
        if let notice = session.notice {
            ToastView(text: notice)
                .padding(.top, DS.S.xl + DS.S.l)
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    session.notice = nil
                }
                .onTapGesture { session.notice = nil }
        }
    }
}

private struct KeyCap: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DS.F.monoSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.S.s + 4)
            .frame(minWidth: 44, minHeight: 36)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ScreenButtonStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.F.smallStrong)
            .foregroundStyle(.white)
            .padding(.horizontal, DS.S.m)
            .frame(minHeight: 36)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

/// The noVNC page from the app bundle, wired to a `ScreenSession`.
struct ScreenWebView: UIViewRepresentable {
    var session: ScreenSession

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(ScreenBridge(session: session), name: "bb")
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.suppressesIncrementalRendering = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.043, green: 0.047, blue: 0.059, alpha: 1)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        session.webView = web
        if let folder = Bundle.main.url(forResource: "ScreenViewer", withExtension: nil) {
            web.loadFileURL(folder.appendingPathComponent("screen.html"), allowingReadAccessTo: folder)
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "bb")
    }
}

/// A one-line bar above the composer that opens Hermes' screen.
struct ScreenPromptBar: View {
    var text: String
    var urgent: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.S.s + 4) {
                Image(systemName: urgent ? "hand.raised.fill" : "display")
                    .foregroundStyle(urgent ? DS.C.bad : DS.C.volt)
                Text(text).font(DS.F.smallStrong).foregroundStyle(DS.C.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.C.ink3)
            }
            .padding(.horizontal, DS.S.m)
            .frame(minHeight: 44)
            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous)
                .stroke(urgent ? DS.C.bad.opacity(0.5) : DS.C.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.S.m)
        .accessibilityHint("Opens Hermes' screen")
    }
}
