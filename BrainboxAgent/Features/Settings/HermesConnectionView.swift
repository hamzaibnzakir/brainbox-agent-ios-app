import SwiftUI
import BrainboxCore

/// Hermes backend settings. The recommended setup is the Brainbox proxy
/// (per-device token; the Hermes API key never leaves the VPS).
struct HermesConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var tokenText = ""
    @State private var tokenError: String?
    @State private var testing = false
    @State private var testError: AgentError?
    @State private var report: HermesCompatibilityReport?
    @State private var proxyInfo: BrainboxGatewayInfo?
    @State private var showConnected = false
    @State private var shake = 0
    @State private var revealed: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 28)).foregroundStyle(BB.Palette.auraGradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hermes Agent API").font(BB.Font.headline)
                            Text("Your Hermes on the VPS, via the Brainbox proxy").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                        }
                    }
                    if model.settings.providerKind == .hermes {
                        LiveIndicator(state: model.connectionState)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                TextField("https://your-vps.tailnet.ts.net:8444/hermes", text: $urlText)
                    .font(BB.Font.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .bbShake(shake)
                    .accessibilityIdentifier("hermes.url")
                if let urlError { Text(urlError).font(BB.Font.caption).foregroundStyle(BB.Palette.danger) }
                Button("Save URL") { Task { await saveURL() } }
                    .foregroundStyle(BB.Palette.signalText)
                    .disabled(urlText == model.settings.hermesURL)
            } header: { Text("Hermes URL").bbLabelStyle() } footer: {
                Text("Use the Brainbox proxy URL (ends in /hermes), published privately with `tailscale serve`. Plain http:// is accepted only for Tailscale/private addresses. Never expose the Hermes API Server itself to the internet.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                if model.hasHermesToken {
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(BB.Palette.signalText)
                        Text(revealed ?? "Saved in Keychain").font(BB.Font.mono).lineLimit(1)
                        Spacer()
                        Button(revealed == nil ? "Show" : "Hide") { Task { await toggleReveal() } }
                            .font(BB.Font.subhead).foregroundStyle(BB.Palette.signalText)
                    }
                    Button("Remove token", role: .destructive) { Task { await removeToken() } }
                }
                SecureField(model.hasHermesToken ? "Replace device token" : "Device token", text: $tokenText)
                    .font(BB.Font.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("hermes.token")
                if let tokenError { Text(tokenError).font(BB.Font.caption).foregroundStyle(BB.Palette.danger) }
                Button("Save token") { Task { await saveToken() } }
                    .foregroundStyle(BB.Palette.signalText)
                    .disabled(tokenText.isEmpty)
            } header: { Text("Device token").bbLabelStyle() } footer: {
                Text("Create one on the VPS with `brainbox-gateway new-device --name \"My iPhone\"`. It's stored only in this iPhone's Keychain (never iCloud) and can be revoked on the server at any time. Don't paste the Hermes API_SERVER_KEY here unless you're on a private development setup.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        if testing { ProgressView().tint(BB.Palette.signal) } else { Image(systemName: "antenna.radiowaves.left.and.right") }
                        Text(testing ? "Testing…" : "Test connection")
                    }
                }
                .foregroundStyle(BB.Palette.signalText)
                .disabled(testing || model.settings.validatedHermesURL == nil || !model.hasHermesToken)
                .accessibilityIdentifier("hermes.test")
                if let testError { ErrorBanner(error: testError, dismiss: { self.testError = nil }) }
                if let report {
                    ForEach(HermesCompatibilityReport.Feature.allCases, id: \.self) { feature in
                        HStack {
                            Text(feature.title).font(BB.Font.callout)
                            Spacer()
                            Image(systemName: report.supports(feature) ? "checkmark" : "minus")
                                .foregroundStyle(report.supports(feature) ? BB.Palette.success : BB.Palette.textTertiary)
                        }
                    }
                    ForEach(report.problems, id: \.self) { Text($0).font(BB.Font.caption).foregroundStyle(BB.Palette.warning) }
                }
                if model.settings.providerKind != .hermes {
                    Button("Use Hermes as the backend") { Task { await useHermes() } }
                        .foregroundStyle(BB.Palette.signalText)
                        .disabled(model.settings.validatedHermesURL == nil || !model.hasHermesToken)
                        .accessibilityIdentifier("hermes.use")
                }
            } header: { Text("Check").bbLabelStyle() } footer: {
                Text("Reads /v1/capabilities and compares it with what the app needs. Unsupported features are switched off in the app instead of failing later.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Hermes")
        .onAppear { urlText = model.settings.hermesURL }
        .sheet(isPresented: $showConnected) {
            ConnectedPulseSheet(
                title: "Hermes connected",
                detail: proxyInfo.map { "Through the Brainbox proxy as “\($0.deviceName ?? "this device")”." } ?? "Connected directly to the Hermes API Server.",
                rows: HermesCompatibilityReport.Feature.allCases.prefix(8).map { ($0.title, report?.supports($0) ?? false) },
                buttonTitle: model.settings.providerKind == .hermes ? "Done" : "Use Hermes now",
                onDone: {
                    showConnected = false
                    if model.settings.providerKind != .hermes { Task { await useHermes() } }
                })
                .presentationDetents([.large])
                .presentationBackground(BB.Palette.backgroundRaised)
        }
    }

    private func saveURL() async {
        switch HermesURLValidator.validate(urlText) {
        case .invalid(let reason):
            urlError = reason
            shake += 1
        case .valid(let url):
            guard await model.gate.authorize(.changeConnection) else { return }
            urlError = nil
            model.settings.hermesURL = url.absoluteString
            report = nil
            if model.settings.providerKind == .hermes { model.rebuildSuite() }
        }
    }

    private func saveToken() async {
        if let problem = TokenValidator.validate(tokenText) {
            tokenError = problem
            return
        }
        guard await model.gate.authorize(.changeConnection) else { return }
        do {
            try model.saveHermesToken(tokenText)
            tokenText = ""
            tokenError = nil
            revealed = nil
            if model.settings.providerKind == .hermes { model.rebuildSuite() }
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func toggleReveal() async {
        if revealed != nil { revealed = nil; return }
        guard await model.gate.authorize(.revealToken), let token = model.readHermesToken() else { return }
        revealed = TokenValidator.redacted(token)
    }

    private func removeToken() async {
        guard await model.gate.authorize(.changeConnection) else { return }
        try? model.deleteHermesToken()
        revealed = nil
        if model.settings.providerKind == .hermes { model.rebuildSuite() }
    }

    /// A standalone test with a fresh client, independent of the active backend.
    private func test() async {
        guard let url = model.settings.validatedHermesURL else { return }
        testing = true
        testError = nil
        defer { testing = false }
        let credentials = model.credentials
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: url), transport: URLSessionHTTPTransport(),
                                     tokenProvider: { (try? credentials.read(.hermesToken)) ?? nil })
        do {
            let caps = try await client.capabilities()
            let evaluated = HermesCompatibilityReport.evaluate(caps)
            proxyInfo = try? await client.gatewayInfo()
            withAnimation(Motion.smooth) { report = evaluated }
            if evaluated.isCompatible {
                showConnected = true
            } else {
                testError = .providerUnavailable(detail: "Connected, but this Hermes server is missing required features.")
            }
        } catch {
            withAnimation(Motion.smooth) { testError = error.asAgentError }
        }
    }

    private func useHermes() async {
        guard await model.gate.authorize(.changeAgentConfiguration) else { return }
        withAnimation(Motion.smooth) { model.switchProvider(to: .hermes) }
    }
}
