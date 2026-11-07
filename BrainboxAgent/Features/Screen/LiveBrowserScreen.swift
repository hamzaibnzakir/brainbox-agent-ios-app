import BrainboxCore
import HermesKit
import Observation
import SwiftUI
import UIKit

/// Hermes' browser as a phone page: the page itself (no desktop around it), live. Take over and it
/// becomes a real mobile page you tap, scroll and type into with the iPhone keyboard; hand back and
/// Hermes continues on the desktop page with whatever you signed in to.
@MainActor
@Observable
final class LiveBrowserSession {
    enum Phase: Equatable {
        case connecting
        case live
        case noBrowser(String)
        case failed(String)
    }

    var phase: Phase = .connecting
    var image: UIImage?
    var cssSize = CGSize(width: 393, height: 760)
    var tab: BrowserTab?
    var tabs: [BrowserTab] = []
    var inControl = false
    var someoneElseInControl = false
    var busy = false
    var notice: String?
    var keyboardRequested = false
    /// Mobile site (true) or the desktop site at phone size (false).
    var mobileSite = true

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var browser: LiveBrowser?
    @ObservationIgnored private var screen: BotScreen?
    @ObservationIgnored private var viewerID: String?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored var viewport = CGSize(width: 393, height: 760)
    @ObservationIgnored private var touching = false

    func open(model: AppModel, tab: BrowserTab? = nil) async {
        self.model = model
        if AppModel.isDemo { phase = .noBrowser(LiveBrowserError.noBrowser.localizedDescription); return }
        phase = .connecting
        do {
            let client = try await model.client()
            stopStreams()
            let browser = LiveBrowser(client: client)
            self.browser = browser
            screen = client.screen
            try await browser.open(tab)
            self.tab = browser.tab
            tabs = (try? await browser.tabs()) ?? []
            frameTask = Task { [weak self] in
                for await frame in browser.frames {
                    guard let self else { return }
                    let image = UIImage(data: frame.jpeg)
                    self.image = image
                    if frame.cssWidth > 0, frame.cssHeight > 0 { self.cssSize = CGSize(width: frame.cssWidth, height: frame.cssHeight) }
                    if self.phase != .live { self.phase = .live }
                }
            }
            changeTask = Task { [weak self] in
                for await tab in browser.changes { self?.tab = tab }
            }
            // Watching is free; control needs the screen's lease, so mint a viewer id now.
            if let status = try? await client.screen.status() {
                someoneElseInControl = status.lease.holder == .human && !inControl
            }
        } catch let error as LiveBrowserError {
            phase = .noBrowser(error.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Starts the screen if it's off, opens Hermes' browser the way the screen's dock does, then attaches.
    func launchBrowser() async {
        guard let model, !busy else { return }
        busy = true
        defer { busy = false }
        phase = .connecting
        do {
            let client = try await model.client()
            let screen = client.screen
            let status = try await screen.status()
            guard status.supported, status.installed else {
                phase = .failed("Hermes' screen isn't set up on this server yet. Switch to Desktop for what's missing.")
                return
            }
            if !status.running { _ = try await screen.start() }
            _ = try await LiveBrowser(client: client).launch()
            busy = false
            await open(model: model)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func stopStreams() {
        frameTask?.cancel()
        changeTask?.cancel()
        frameTask = nil
        changeTask = nil
    }

    /// Leaving: give the page back exactly as Hermes left it, and release control.
    func close() async {
        stopStreams()
        if inControl { await handBack() }
        await browser?.stop()
        browser = nil
    }

    // MARK: Control

    func takeOver() async {
        guard let browser, let screen, !busy else { return }
        if model?.preferences.lockWithFaceID == true,
           !(await Biometrics.authenticate(reason: "Take control of Hermes' browser")) {
            notice = "Face ID is needed to take control."
            return
        }
        busy = true
        defer { busy = false }
        do {
            // The lease pauses Hermes' browser and computer tools while you're in.
            let ticket = try await screen.observe(viewerID: viewerID)
            viewerID = ticket.viewerID
            _ = try await screen.takeOver(viewerID: ticket.viewerID, reason: "Brainbox (iPhone, browser)")
            inControl = true
            someoneElseInControl = false
            try await browser.enterPhoneMode(PhoneViewport(width: Int(viewport.width.rounded()), height: Int(viewport.height.rounded()),
                                                           scale: 2, mobile: mobileSite))
            Haptic.success()
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func handBack(force: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        keyboardRequested = false
        await browser?.leavePhoneMode()
        if let screen {
            _ = try? await screen.handBack(viewerID: force ? nil : viewerID, force: force)
        }
        inControl = false
        someoneElseInControl = false
        Haptic.tap()
    }

    func switchSite(mobile: Bool) async {
        mobileSite = mobile
        guard inControl, let browser else { return }
        try? await browser.enterPhoneMode(PhoneViewport(width: Int(viewport.width.rounded()), height: Int(viewport.height.rounded()),
                                                        scale: 2, mobile: mobile))
    }

    // MARK: Input (points in the page view → CSS pixels of the page)

    func touch(_ phase: LiveBrowser.TouchPhase, at point: CGPoint, in rect: CGRect) {
        guard inControl, let browser, rect.width > 0, rect.height > 0 else { return }
        let x = (point.x - rect.minX) / rect.width * cssSize.width
        let y = (point.y - rect.minY) / rect.height * cssSize.height
        browser.touch(phase, points: [(Double(x), Double(y))])
        if phase == .end || phase == .cancel {
            // A tap on a text field brings up the keyboard, like Safari.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let browser = self.browser else { return }
                if await browser.editableFocused() { self.keyboardRequested = true }
            }
        }
    }

    func type(_ text: String) {
        guard inControl, let browser else { return }
        if text == "\n" { browser.press(.enter) } else { browser.insert(text: text) }
    }

    func backspace() { if inControl { browser?.press(.backspace) } }
    func press(_ key: LiveBrowser.Key) { if inControl { browser?.press(key) } }

    func navigate(_ text: String) async {
        do { try await browser?.navigate(text) } catch { notice = error.localizedDescription }
    }

    func back() async { await browser?.goBack() }
    func reload() { browser?.reload() }

    func refreshTabs() async { tabs = (try? await browser?.tabs()) ?? tabs }

    func switchTo(_ tab: BrowserTab) async {
        guard let model else { return }
        let wasInControl = inControl
        if wasInControl { await browser?.leavePhoneMode() }
        await open(model: model, tab: tab)
        if wasInControl, let browser {
            try? await browser.enterPhoneMode(PhoneViewport(width: Int(viewport.width.rounded()), height: Int(viewport.height.rounded()),
                                                            scale: 2, mobile: mobileSite))
            inControl = true
        }
    }
}

struct LiveBrowserScreen: View {
    @Environment(AppModel.self) private var model
    @State private var session = LiveBrowserSession()
    @State private var editingURL = false
    @State private var urlText = ""

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            page
            if session.phase == .live { toolbar }
        }
        .background(Color(hex: 0x0B0C0F).ignoresSafeArea())
        .overlay(alignment: .top) { noticeView }
        .task { await session.open(model: model) }
        .onDisappear { Task { await session.close() } }
        .alert("Go to", isPresented: $editingURL) {
            TextField("Address or search", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
            Button("Go") { Task { await session.navigate(urlText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header

    private var controlBar: some View {
        HStack(spacing: DS.S.s + 4) {
            VStack(alignment: .leading, spacing: 2) {
                if session.inControl {
                    Pill(text: "You're in control", color: DS.C.bad, symbol: "hand.raised.fill")
                } else if session.someoneElseInControl {
                    Pill(text: "Someone else is in control", color: DS.C.warn, symbol: "person.fill")
                } else {
                    Pill(text: session.phase == .live ? "Hermes is browsing" : "Hermes' browser", color: Color(hex: 0x8C82FF), symbol: "sparkles")
                }
                Text(session.tab?.title.isEmpty == false ? session.tab!.title : session.tab?.url ?? "")
                    .font(DS.F.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.phase == .live {
                if session.inControl {
                    Button { Task { await session.handBack() } } label: { Label("Hand back", systemImage: "arrow.uturn.backward.circle.fill") }
                        .buttonStyle(ScreenButtonStyle(tint: DS.C.good)).disabled(session.busy)
                } else {
                    Button { Task { await session.takeOver() } } label: { Label("Take over", systemImage: "hand.tap.fill") }
                        .buttonStyle(ScreenButtonStyle(tint: DS.C.bad)).disabled(session.busy)
                }
            }
        }
        .padding(.horizontal, DS.S.m)
        .padding(.vertical, DS.S.s + 2)
        .background(Color(hex: 0x16171C))
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        switch session.phase {
        case .connecting:
            VStack(spacing: DS.S.s) {
                ProgressView().tint(.white)
                Text("Opening Hermes' browser…").font(DS.F.small).foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noBrowser(let message), .failed(let message):
            VStack(spacing: DS.S.m) {
                Image(systemName: "safari").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Text(message).font(DS.F.bodyStrong).foregroundStyle(.white).multilineTextAlignment(.center)
                Text("Open it here, or it opens by itself when Hermes browses.")
                    .font(DS.F.small).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                Button {
                    Task { await session.launchBrowser() }
                } label: {
                    if session.busy { ProgressView().tint(.white) } else { Text("Open Hermes' browser") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 280)
                .disabled(session.busy)
                Button("Try again") { Task { await session.open(model: model) } }.buttonStyle(SecondaryButtonStyle(tint: .white))
            }
            .padding(DS.S.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .live:
            GeometryReader { geo in
                let rect = imageRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let image = session.image {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    KeyInputView(active: Binding(get: { session.keyboardRequested && session.inControl },
                                                 set: { session.keyboardRequested = $0 }),
                                 onText: { session.type($0) }, onBackspace: { session.backspace() })
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(touchGesture(rect: rect), including: session.inControl ? .all : .none)
                .overlay(Rectangle().stroke(session.inControl ? DS.C.bad : .clear, lineWidth: 2))
                .onAppear { session.viewport = geo.size }
                .onChange(of: geo.size) { _, size in session.viewport = size }
            }
        }
    }

    /// Where the frame sits in the view (aspect fit; phone mode fills it exactly).
    private func imageRect(in size: CGSize) -> CGRect {
        let css = session.cssSize
        guard css.width > 0, css.height > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / css.width, size.height / css.height)
        let w = css.width * scale, h = css.height * scale
        return CGRect(x: (size.width - w) / 2, y: session.inControl ? 0 : (size.height - h) / 2, width: w, height: h)
    }

    /// One finger: touchStart / touchMove / touchEnd, so a tap clicks and a drag scrolls — like Safari.
    private func touchGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                session.touch(touchActive ? .move : .start, at: value.location, in: rect)
                touchActive = true
            }
            .onEnded { value in
                session.touch(.end, at: value.location, in: rect)
                touchActive = false
            }
    }

    @State private var touchActive = false

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DS.S.l) {
            Button { Task { await session.back() } } label: { Image(systemName: "chevron.backward") }
            Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
            Button { urlText = session.tab?.url ?? ""; editingURL = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11))
                    Text(host(session.tab?.url)).lineLimit(1)
                }
                .font(DS.F.small)
                .padding(.horizontal, DS.S.m)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.white.opacity(0.1), in: Capsule())
            }
            .disabled(!session.inControl)
            Button { session.keyboardRequested.toggle() } label: { Image(systemName: "keyboard") }
                .disabled(!session.inControl)
            Menu {
                Section("Pages") {
                    ForEach(session.tabs) { tab in
                        Button(tab.title.isEmpty ? tab.url : tab.title) { Task { await session.switchTo(tab) } }
                    }
                }
                Button { Task { await session.switchSite(mobile: !session.mobileSite) } } label: {
                    Label(session.mobileSite ? "Request desktop site" : "Request mobile site",
                          systemImage: session.mobileSite ? "desktopcomputer" : "iphone")
                }
                if session.someoneElseInControl {
                    Button(role: .destructive) { Task { await session.handBack(force: true) } } label: {
                        Label("Hand back (force)", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Image(systemName: "square.on.square")
            }
            .onTapGesture { Task { await session.refreshTabs() } }
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, DS.S.m)
        .padding(.vertical, DS.S.s + 2)
        .background(Color(hex: 0x16171C))
    }

    private func host(_ url: String?) -> String {
        guard let url, let host = URL(string: url)?.host else { return url ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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

/// The iPhone keyboard, feeding keystrokes straight to the page (no text field of our own:
/// every character, backspace and return reaches whatever field is focused in Hermes' browser).
struct KeyInputView: UIViewRepresentable {
    @Binding var active: Bool
    var onText: (String) -> Void
    var onBackspace: () -> Void

    func makeUIView(context: Context) -> KeyInputUIView {
        let view = KeyInputUIView()
        view.onText = onText
        view.onBackspace = onBackspace
        view.onResign = { active = false }
        return view
    }

    func updateUIView(_ view: KeyInputUIView, context: Context) {
        view.onText = onText
        view.onBackspace = onBackspace
        if active, !view.isFirstResponder { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        if !active, view.isFirstResponder { DispatchQueue.main.async { _ = view.resignFirstResponder() } }
    }
}

final class KeyInputUIView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onResign: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }

    // Typing logins: no autocorrect or auto-capitals getting in the way.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .go

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onResign?()
        return ok
    }
}

/// Hermes' screen: the browser as a phone page (default) or the whole desktop.
struct HermesScreenView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case browser = "Browser", desktop = "Desktop"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .browser

    var body: some View {
        Group {
            switch mode {
            case .browser: LiveBrowserScreen()
            case .desktop: ScreenScreen()
            }
        }
        .navigationTitle("Hermes' screen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(hex: 0x16171C), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)   // the page gets the room
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
    }
}
