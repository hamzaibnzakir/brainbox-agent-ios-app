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
    @State private var tailscale = true
    @State private var hermesPort = "8766"
    @State private var token = ""
    @State private var copiedScript = false
    @FocusState private var focused: Field?

    enum Field { case name, host, port, user, hermesPort, token }

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

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil && !user.isEmpty
            && (!tailscale || (Int(hermesPort) != nil && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.S.l) {
                if isOnboarding { hero }
                modePicker
                if tailscale { setupCard }
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
            Text(tailscale
                 ? "Brainbox talks to Hermes on your server over your private Tailscale network — nothing is opened to the internet, and it stays connected as you move between Wi-Fi and cellular."
                 : "Brainbox talks to Hermes on your server over SSH, the same way Hermes Desktop does. Nothing is opened to the internet besides SSH.")
                .font(DS.F.small).foregroundStyle(DS.C.ink2)
        }
        .padding(.top, DS.S.l)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            Picker("Connection", selection: $tailscale) {
                Text("Tailscale").tag(true)
                Text("SSH").tag(false)
            }
            .pickerStyle(.segmented)
            Text(tailscale ? "Recommended: fastest reconnects, survives network changes. Needs the Tailscale app on this phone and the server."
                           : "Works without Tailscale: Brainbox opens an SSH tunnel to the server for everything.")
                .font(DS.F.caption).foregroundStyle(DS.C.ink3)
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            stepHeader(1, "Set up the server (once)")
            Text("On the server: install Tailscale and sign in, then run the Brainbox setup script as root. It runs Hermes as a service on 127.0.0.1 only and lets Tailscale reach it — and prints the address, port and token to paste below.")
                .font(DS.F.small).foregroundStyle(DS.C.ink2)
            Text("curl -fsSL https://tailscale.com/install.sh | sh && tailscale up")
                .font(DS.F.monoSmall).foregroundStyle(DS.C.ink)
                .padding(DS.S.m).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.C.raised, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                .textSelection(.enabled)
            HStack(spacing: DS.S.s) {
                Button {
                    UIPasteboard.general.string = "curl -fsSL https://tailscale.com/install.sh | sh && tailscale up"
                    Haptic.tap()
                } label: { Label("Copy install", systemImage: "doc.on.doc") }
                .buttonStyle(SecondaryButtonStyle(tint: DS.C.ink2))
                Button {
                    UIPasteboard.general.string = TailscaleSetup.script
                    copiedScript = true
                    Haptic.success()
                } label: { Label(copiedScript ? "Copied" : "Copy setup script", systemImage: copiedScript ? "checkmark" : "terminal") }
                .buttonStyle(SecondaryButtonStyle())
            }
            Text("Paste the script into the server's terminal (or save it as setup.sh and run  bash setup.sh). Install the Tailscale app on this phone too and sign in with the same account.")
                .font(DS.F.caption).foregroundStyle(DS.C.ink3)
        }
        .card()
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            stepHeader(tailscale ? 2 : 1, "Your server")
            field("Name", text: $name, field: .name, keyboard: .default, placeholder: "My VPS")
            field(tailscale ? "Tailscale address" : "Host or IP", text: $host, field: .host, keyboard: .URL,
                  placeholder: tailscale ? "100.101.102.103 or my-vps.tail1234.ts.net" : "203.0.113.10")
            if tailscale {
                HStack(alignment: .bottom, spacing: DS.S.s + 4) {
                    VStack(alignment: .leading, spacing: DS.S.xs + 2) {
                        Text("Access token").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                        SecureField("From the setup script", text: $token)
                            .font(DS.F.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .token)
                            .padding(.horizontal, DS.S.m).frame(minHeight: 48)
                            .background(DS.C.raised, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous)
                                .stroke(focused == .token ? DS.C.volt : DS.C.line, lineWidth: focused == .token ? 1.5 : 1))
                    }
                    Button {
                        if let pasted = UIPasteboard.general.string { token = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                        Haptic.tap()
                    } label: { Image(systemName: "doc.on.clipboard").frame(width: 48, height: 48) }
                    .buttonStyle(SecondaryButtonStyle(tint: DS.C.ink2))
                    .accessibilityLabel("Paste token")
                }
                field("Hermes port", text: $hermesPort, field: .hermesPort, keyboard: .numberPad, placeholder: "8766")
            }
            HStack(spacing: DS.S.s + 4) {
                field("User", text: $user, field: .user, keyboard: .asciiCapable, placeholder: "root")
                field(tailscale ? "SSH port" : "Port", text: $port, field: .port, keyboard: .numberPad, placeholder: "22").frame(width: 96)
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
            stepHeader(tailscale ? 3 : 2, tailscale ? "Let this phone in (terminal & files)" : "Let this phone in")
            Text(tailscale
                 ? "Chat works with just the token. For the terminal, file transfers and Hermes' browser, run this once on the server too — it adds this phone's public key; the private key never leaves the phone."
                 : "Run this once on the server (as \(user.isEmpty ? "root" : user)). It adds this phone's public key; the private key never leaves the phone.")
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
                infoRow("Backend", model.profile?.tailscale == true ? "Brainbox service over Tailscale"
                                   : info.reusedBackend ? "Reused the one already running" : "Started a new one")
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
                                                      username: user.trimmingCharacters(in: .whitespaces)),
                                    tailscale: tailscale, hermesPort: Int(hermesPort) ?? 8766)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenChanged = tailscale && cleanToken != (AppStore.shared.hermesToken ?? "")
        if tailscale { AppStore.shared.hermesToken = cleanToken }
        if model.isConnected, profile == model.profile, !tokenChanged {
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
        tailscale = p.tailscale
        hermesPort = String(p.hermesPort)
        token = AppStore.shared.hermesToken ?? ""
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
