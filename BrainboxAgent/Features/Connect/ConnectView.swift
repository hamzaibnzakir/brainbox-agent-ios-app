import HermesKit
import SwiftUI

/// Pair the phone with the server: where to SSH, and the one key to authorize.
struct ConnectView: View {
    var isOnboarding: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = "My VPS"
    @State private var host = ""
    @State private var port = "22"
    @State private var user = "root"
    @State private var copiedKey = false
    @State private var copiedCommand = false
    @State private var working = false
    @State private var confirmRegenerate = false
    @FocusState private var focused: Field?

    enum Field { case name, host, port, user }

    private var keyLine: String { model.identity.authorizedKeysLine(comment: "brainbox-\(UIDevice.current.name.replacingOccurrences(of: " ", with: "-").lowercased())") }

    private var installCommand: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(keyLine)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    private var desktopBinding: Binding<Bool> {
        Binding(get: { model.preferences.desktopBackend }, set: { on in
            model.preferences.desktopBackend = on
            // A running backend keeps its mode; restart it so the change applies.
            if model.isConnected { Task { await model.engine.stopBackend(); await model.connect() } }
        })
    }

    private var canConnect: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil && !user.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.S.l) {
                if isOnboarding { hero }
                serverCard
                keyCard
                statusCard
            }
            .padding(DS.S.m)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .safeAreaInset(edge: .bottom) { connectBar }
        .navigationTitle(isOnboarding ? "" : "Connection")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .confirmationDialog("Make a new key?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("New key", role: .destructive) { model.regenerateKey() }
        } message: {
            Text("The old key stops working. You'll need to add the new one to the server.")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            MascotView(style: .brainbox, mood: working ? .thinking : .idle, size: 72)
            Text("Connect to Hermes").font(DS.F.title).foregroundStyle(DS.C.ink)
            Text("Brainbox talks to Hermes on your server over SSH, the same way Hermes Desktop does. Nothing is opened to the internet besides SSH.")
                .font(DS.F.small).foregroundStyle(DS.C.ink2)
        }
        .padding(.top, DS.S.l)
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            stepHeader(1, "Your server")
            field("Name", text: $name, field: .name, keyboard: .default, placeholder: "My VPS")
            field("Host or IP", text: $host, field: .host, keyboard: .URL, placeholder: "203.0.113.10")
            HStack(spacing: DS.S.s + 4) {
                field("User", text: $user, field: .user, keyboard: .asciiCapable, placeholder: "root")
                field("Port", text: $port, field: .port, keyboard: .numberPad, placeholder: "22").frame(width: 96)
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: DS.S.s) {
                    Toggle("Desktop-compatible backend", isOn: desktopBinding).font(DS.F.small)
                    Text("Only if Brainbox says your Hermes asks for a dashboard login (dashboard.public_url is set). It starts Hermes the way Desktop does, which also runs Desktop's cron ticker for profiles no gateway serves.")
                        .font(DS.F.caption).foregroundStyle(DS.C.ink3)
                }
                .padding(.top, DS.S.s)
            }
            .font(DS.F.small)
            .tint(DS.C.ink2)
        }
        .card()
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            stepHeader(2, "Let this phone in")
            Text("Run this once on the server (as \(user.isEmpty ? "root" : user)). It adds this phone's public key; the private key never leaves the phone.")
                .font(DS.F.small).foregroundStyle(DS.C.ink2)
            Text(installCommand)
                .font(DS.F.monoSmall).foregroundStyle(DS.C.ink)
                .padding(DS.S.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.C.raised, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                .textSelection(.enabled)
            HStack(spacing: DS.S.s) {
                Button {
                    UIPasteboard.general.string = installCommand
                    copiedCommand = true
                    Haptic.success()
                } label: { Label(copiedCommand ? "Copied" : "Copy command", systemImage: copiedCommand ? "checkmark" : "terminal") }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    UIPasteboard.general.string = keyLine
                    copiedKey = true
                    Haptic.tap()
                } label: { Label(copiedKey ? "Copied" : "Key only", systemImage: copiedKey ? "checkmark" : "key") }
                .buttonStyle(SecondaryButtonStyle(tint: DS.C.ink2))
                Spacer()
                Menu {
                    ShareLink(item: keyLine) { Label("Share public key", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { confirmRegenerate = true } label: { Label("Make a new key", systemImage: "arrow.triangle.2.circlepath") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundStyle(DS.C.ink2).frame(width: 44, height: 44)
                }
            }
            Text("Key fingerprint \(model.identity.fingerprint)").font(DS.F.caption).foregroundStyle(DS.C.ink3)
        }
        .card()
    }

    @ViewBuilder
    private var statusCard: some View {
        switch model.connection {
        case .connected(let info):
            VStack(alignment: .leading, spacing: DS.S.s + 4) {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.C.good)
                    Text("Connected").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
                    Spacer()
                    if let v = info.version { Pill(text: "Hermes \(v)", color: DS.C.volt) }
                }
                infoRow("Server", info.target.display)
                infoRow("Server key", info.hostFingerprint)
                infoRow("Hermes", info.hermesPath)
                infoRow("Backend", info.reusedBackend ? "Reused the one already running" : "Started a new one")
                HStack(spacing: DS.S.s) {
                    Button("Disconnect") { Task { await model.disconnect() } }.buttonStyle(SecondaryButtonStyle(tint: DS.C.ink2))
                    Button("Restart backend") { Task { await model.engine.stopBackend(); await model.connect() } }
                        .buttonStyle(SecondaryButtonStyle(tint: DS.C.warn))
                }
            }
            .card()
        case .failed(let message):
            VStack(alignment: .leading, spacing: DS.S.s + 4) {
                ErrorBanner(message: message)
                if message.contains("identity changed") {
                    Button("I reinstalled the server — trust its new key") { model.forgetHostKey() }
                        .buttonStyle(SecondaryButtonStyle(tint: DS.C.bad))
                }
            }
        case .connecting(let step), .reconnecting(_, let step):
            HStack(spacing: DS.S.s + 4) {
                ProgressView()
                Text(step).font(DS.F.small).foregroundStyle(DS.C.ink2)
            }
            .card()
        case .idle:
            EmptyView()
        }
    }

    private var connectBar: some View {
        VStack(spacing: 0) {
            Button {
                connect()
            } label: {
                HStack(spacing: DS.S.s) {
                    if working { ProgressView().tint(.white) }
                    Text(model.isConnected ? (isOnboarding ? "Start chatting" : "Save and reconnect") : "Connect")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canConnect || working)
            .padding(.horizontal, DS.S.m)
            .padding(.vertical, DS.S.s + 4)
        }
        .background(.ultraThinMaterial)
    }

    private func connect() {
        focused = nil
        let profile = ServerProfile(name: name.isEmpty ? host : name,
                                    target: SSHTarget(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 22,
                                                      username: user.trimmingCharacters(in: .whitespaces)))
        if model.isConnected, profile == model.profile {
            if !isOnboarding { dismiss() }
            return
        }
        working = true
        Task {
            if model.isConnected { await model.disconnect() }
            model.save(profile: profile)
            await model.connect()
            working = false
            if model.isConnected {
                Haptic.success()
                Notifier.shared.requestAuthorization()
                if !isOnboarding { dismiss() }
            } else {
                Haptic.error()
            }
        }
    }

    private func load() {
        guard let p = model.profile else { return }
        name = p.name
        host = p.target.host
        port = String(p.target.port)
        user = p.target.username
    }

    private func stepHeader(_ n: Int, _ title: String) -> some View {
        HStack(spacing: DS.S.s + 4) {
            Text("\(n)").font(DS.F.captionStrong).foregroundStyle(.white).frame(width: 24, height: 24).background(DS.C.volt, in: Circle())
            Text(title).font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
        }
    }

    private func field(_ label: String, text: Binding<String>, field: Field, keyboard: UIKeyboardType, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: DS.S.xs + 2) {
            Text(label).font(DS.F.caption).foregroundStyle(DS.C.ink3)
            TextField(placeholder, text: text)
                .font(DS.F.body)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: field)
                .padding(.horizontal, DS.S.m)
                .frame(minHeight: 48)
                .background(DS.C.raised, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous)
                    .stroke(focused == field ? DS.C.volt : DS.C.line, lineWidth: focused == field ? 1.5 : 1))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(DS.F.caption).foregroundStyle(DS.C.ink3).frame(width: 84, alignment: .leading)
            Text(value).font(DS.F.monoSmall).foregroundStyle(DS.C.ink2).lineLimit(2).textSelection(.enabled)
        }
    }
}
