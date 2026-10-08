import SwiftUI
import UIKit
import BrainboxCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ConnectionSettingsView() } label: {
                        SettingsRow(systemImage: "point.3.connected.trianglepath.dotted", title: "Connection", subtitle: model.connectionState.label, tint: BB.Palette.signalText) {
                            StatusDot(tone: model.connectionState.tone, size: 7)
                        }
                    }
                    NavigationLink { AgentSettingsView() } label: {
                        SettingsRow(systemImage: "sparkles", title: "Agent", subtitle: model.settings.providerKind.displayName, tint: BB.Palette.signalText) { EmptyView() }
                    }
                }
                .listRowBackground(BB.Palette.surface)

                Section {
                    NavigationLink { AppearanceSettingsView() } label: {
                        SettingsRow(systemImage: "circle.lefthalf.filled", title: "Appearance", subtitle: model.settings.appearance.label) { EmptyView() }
                    }
                    NavigationLink { SecuritySettingsView() } label: {
                        SettingsRow(systemImage: model.gate.biometrySymbol, title: "Security", subtitle: model.settings.biometricsEnabled ? "\(model.gate.biometryName) on" : "\(model.gate.biometryName) off") { EmptyView() }
                    }
                    NavigationLink { NotificationSettingsView() } label: {
                        SettingsRow(systemImage: "bell.badge", title: "Notifications") { EmptyView() }
                    }
                }
                .listRowBackground(BB.Palette.surface)

                Section {
                    NavigationLink { DeveloperSettingsView() } label: {
                        SettingsRow(systemImage: "hammer", title: "Developer", subtitle: "Providers, protocol, diagnostics") { EmptyView() }
                    }
                    NavigationLink { AboutView() } label: {
                        SettingsRow(systemImage: "info.circle", title: "About", subtitle: "Version \(Bundle.main.appVersion)") { EmptyView() }
                    }
                }
                .listRowBackground(BB.Palette.surface)
            }
            .listStyle(.insetGrouped)
            .bbScreen()
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Connection

struct ConnectionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var tokenText = ""
    @State private var tokenError: String?
    @State private var revealed: String?
    @State private var shake = 0
    @State private var message: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AgentOrb(mode: OrbMode(status: model.agentStatus, connection: model.connectionState), size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.connectionState.label).font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
                        Text("\(model.settings.providerKind.displayName) · \(model.agentDescriptor.name)").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    }
                    Spacer()
                    Button("Reconnect") { model.reconnect() }
                        .font(BB.Font.subhead)
                        .foregroundStyle(BB.Palette.signalText)
                        .buttonStyle(.pressableSubtle)
                }
                if let error = model.connectionError {
                    ErrorBanner(error: error)
                }
            } header: { Text("Status").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)

            Section {
                infoRow("Transport", "WebSocket (Brainbox Agent Protocol v\(BrainboxProtocol.version))")
                infoRow("Authentication", authLabel)
                infoRow("Capabilities", model.capabilities.isEmpty ? "—" : model.capabilities.map(\.rawValue).sorted().joined(separator: ", "))
            } header: { Text("Session").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)

            Section {
                TextField("wss://your-gateway.tailnet.ts.net/v1/agent", text: $urlText)
                    .font(BB.Font.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .bbShake(shake)
                    .accessibilityIdentifier("settings.url")
                if let urlError {
                    Text(urlError).font(BB.Font.caption).foregroundStyle(BB.Palette.danger)
                }
                Button("Save URL") { Task { await saveURL() } }
                    .foregroundStyle(BB.Palette.signalText)
                    .disabled(urlText == model.settings.backendURL)
            } header: {
                Text("Gateway URL").bbLabelStyle()
            } footer: {
                Text("Point this at the Brainbox gateway, ideally only reachable over Tailscale. Use wss:// — plain ws:// is accepted only for private/Tailscale addresses.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                if model.hasToken {
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(BB.Palette.signalText)
                        Text(revealed ?? "Saved in Keychain").font(BB.Font.mono).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                        Spacer()
                        Button(revealed == nil ? "Show" : "Hide") { Task { await toggleReveal() } }
                            .font(BB.Font.subhead)
                            .foregroundStyle(BB.Palette.signalText)
                    }
                    Button("Remove token", role: .destructive) { Task { await removeToken() } }
                }
                SecureField(model.hasToken ? "Replace access token" : "Access token", text: $tokenText)
                    .font(BB.Font.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let tokenError {
                    Text(tokenError).font(BB.Font.caption).foregroundStyle(BB.Palette.danger)
                }
                Button("Save token") { Task { await saveToken() } }
                    .foregroundStyle(BB.Palette.signalText)
                    .disabled(tokenText.isEmpty)
            } header: {
                Text("Access token").bbLabelStyle()
            } footer: {
                Text("Stored in the iOS Keychain on this device only (never iCloud, never UserDefaults). It's sent to the gateway inside the encrypted WebSocket handshake.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            if let message {
                Text(message).font(BB.Font.caption).foregroundStyle(BB.Palette.success).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Connection")
        .onAppear { urlText = model.settings.backendURL }
    }

    private var authLabel: String {
        switch model.connectionState {
        case .connected: return "Authenticated"
        case .failed(.authenticationFailed): return "Rejected"
        default: return model.hasToken ? "Token saved" : "No token"
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).bbLabelStyle()
            Text(value).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textPrimary)
        }
    }

    private func saveURL() async {
        switch BackendURLValidator.validate(urlText) {
        case .invalid(let reason):
            urlError = reason
            shake += 1
        case .valid(let url):
            guard await model.gate.authorize(.changeConnection) else { return }
            urlError = nil
            model.settings.backendURL = url.absoluteString
            message = "Gateway URL saved."
            if model.settings.providerKind == .remote { model.rebuildSuite() }
        }
    }

    private func saveToken() async {
        if let problem = TokenValidator.validate(tokenText) {
            tokenError = problem
            return
        }
        guard await model.gate.authorize(.changeConnection) else { return }
        do {
            try model.saveToken(tokenText)
            tokenText = ""
            tokenError = nil
            revealed = nil
            message = "Token saved to Keychain."
            if model.settings.providerKind == .remote { model.rebuildSuite() }
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func toggleReveal() async {
        if revealed != nil { revealed = nil; return }
        guard await model.gate.authorize(.revealToken), let token = model.readToken() else { return }
        revealed = TokenValidator.redacted(token)
    }

    private func removeToken() async {
        guard await model.gate.authorize(.changeConnection) else { return }
        try? model.deleteToken()
        revealed = nil
        message = "Token removed."
        if model.settings.providerKind == .remote { model.rebuildSuite() }
    }
}

// MARK: - Agent

struct AgentSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(ProviderKind.allCases) { kind in
                    Button {
                        Task { await select(kind) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: symbol(for: kind))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(kind.isAvailable ? BB.Palette.signalText : BB.Palette.textTertiary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(kind.displayName).font(BB.Font.callout).foregroundStyle(kind.isAvailable ? BB.Palette.textPrimary : BB.Palette.textTertiary)
                                    if kind == .hermes { Badge(text: "Pending", color: BB.Palette.ion) }
                                }
                                Text(description(for: kind)).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                            }
                            Spacer()
                            if model.settings.providerKind == kind {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(BB.Palette.signal)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableSubtle)
                    .disabled(!kind.isAvailable)
                    .accessibilityIdentifier("provider.\(kind.rawValue)")
                }
            } header: {
                Text("Backend").bbLabelStyle()
            } footer: {
                Text("Every backend goes through the same provider interface, so the app behaves the same whichever is active. Hermes will connect through the Brainbox gateway once its adapter is built and verified.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)
            .animation(Motion.snappy, value: model.settings.providerKind)

            Section {
                ForEach(ProviderCapability.allCases, id: \.self) { capability in
                    HStack {
                        Text(capability.rawValue).font(BB.Font.mono).foregroundStyle(BB.Palette.textPrimary)
                        Spacer()
                        Image(systemName: model.capabilities.contains(capability) ? "checkmark" : "minus")
                            .foregroundStyle(model.capabilities.contains(capability) ? BB.Palette.success : BB.Palette.textTertiary)
                    }
                }
            } header: { Text("Capabilities of \(model.agentDescriptor.name)").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Agent")
    }

    private func symbol(for kind: ProviderKind) -> String {
        switch kind {
        case .mock: return "testtube.2"
        case .remote: return "point.3.connected.trianglepath.dotted"
        case .hermes: return "hourglass"
        }
    }

    private func description(for kind: ProviderKind) -> String {
        switch kind {
        case .mock: return "Simulated agent, VPS, terminal, files and logs for development."
        case .remote: return "Any agent behind a Brainbox gateway (WebSocket)."
        case .hermes: return "Adapter not built yet — no Hermes APIs are assumed."
        }
    }

    private func select(_ kind: ProviderKind) async {
        guard kind != model.settings.providerKind, kind.isAvailable else { return }
        guard await model.gate.authorize(.changeAgentConfiguration) else { return }
        withAnimation(Motion.standard) { model.switchProvider(to: kind) }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        List {
            Section {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            } header: { Text("Theme").bbLabelStyle() }

            Section {
                Toggle("Haptics", isOn: $settings.hapticsEnabled).tint(BB.Palette.signal)
            } footer: {
                Text("Motion follows iOS Reduce Motion automatically: movement becomes simple fades.").font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                HStack(spacing: 20) {
                    ForEach([OrbMode.ready, .thinking, .streaming, .tool], id: \.self) { mode in
                        AgentOrb(mode: mode, size: 46)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: { Text("Agent states").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Appearance")
    }
}


// MARK: - Security

struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmErase = false

    var body: some View {
        @Bindable var settings = model.settings
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.biometricsEnabled },
                    set: { newValue in Task { await setBiometrics(newValue) } }
                )) {
                    Label("Require \(model.gate.biometryName)", systemImage: model.gate.biometrySymbol)
                }
                .tint(BB.Palette.signal)
                Picker("Lock after", selection: Binding(
                    get: { settings.sessionTimeout ?? -1 },
                    set: { settings.sessionTimeout = $0 < 0 ? nil : $0 }
                )) {
                    ForEach(SecurityPolicy.sessionTimeoutOptions, id: \.label) { option in
                        Text(option.label).tag(option.value ?? -1)
                    }
                }
                .disabled(!settings.biometricsEnabled)
                Toggle("Confirm destructive actions", isOn: $settings.confirmSensitiveActions).tint(BB.Palette.signal)
                Button("Lock now") { model.gate.lockNow() }
                    .disabled(!settings.biometricsEnabled)
            } header: {
                Text("Biometrics").bbLabelStyle()
            } footer: {
                Text("\(model.gate.biometryName) is required to open the terminal, save configuration files, delete files, control services and change connection or agent settings.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                SettingsRow(systemImage: "key.horizontal", title: "Keychain", subtitle: model.hasToken ? "Gateway token stored · this device only" : "No credentials stored") {
                    StatusDot(tone: model.hasToken ? .live : .idle, pulsing: false)
                }
                SettingsRow(systemImage: "internaldrive", title: "Local data", subtitle: "Conversations and cached server info are stored on-device with file protection.") { EmptyView() }
                Button("Erase local data", role: .destructive) { confirmErase = true }
            } header: { Text("Storage").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Security")
        .confirmationDialog("Erase all local data?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) {
                Task {
                    if await model.gate.authorize(.changeConnection) {
                        model.eraseLocalData()
                        model.toasts.show("Local data erased")
                    }
                }
            }
        } message: {
            Text("Deletes conversations, cached server data and the saved token from this device. Nothing on your server is touched.")
        }
    }

    private func setBiometrics(_ enabled: Bool) async {
        if enabled {
            model.settings.biometricsEnabled = true
        } else {
            // Turning protection off must itself be authenticated.
            let wasEnabled = model.settings.biometricsEnabled
            if wasEnabled, await model.gate.authorize(.changeConnection) {
                model.settings.biometricsEnabled = false
            }
        }
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        List {
            Section {
                Toggle("Task finished", isOn: Binding(get: { settings.notifyOnTaskComplete }, set: { value in
                    settings.notifyOnTaskComplete = value
                    if value { Task { _ = await Notifier.requestAuthorization() } }
                }))
                .tint(BB.Palette.signal)
                Toggle("Connection lost", isOn: Binding(get: { settings.notifyOnDisconnect }, set: { value in
                    settings.notifyOnDisconnect = value
                    if value { Task { _ = await Notifier.requestAuthorization() } }
                }))
                .tint(BB.Palette.signal)
            } footer: {
                Text("Local notifications only. Brainbox Agent has no push server; alerts fire while the app is running or briefly in the background.")
                    .font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Notifications")
    }
}

// MARK: - Developer

struct DeveloperSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(ProviderKind.allCases) { kind in
                    HStack {
                        Text(kind.displayName).foregroundStyle(kind.isAvailable ? BB.Palette.textPrimary : BB.Palette.textTertiary)
                        Spacer()
                        if model.settings.providerKind == kind { Image(systemName: "checkmark").foregroundStyle(BB.Palette.signal) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard kind.isAvailable else { return }
                        Task {
                            if await model.gate.authorize(.changeAgentConfiguration) { model.switchProvider(to: kind) }
                        }
                    }
                }
            } header: { Text("Provider").bbLabelStyle() } footer: {
                Text("Mock drives every screen without a server. Future Hermes stays disabled until the adapter exists.").font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)

            Section {
                row("Protocol", "Brainbox Agent Protocol v\(BrainboxProtocol.version)")
                row("Build", Bundle.main.appVersion)
                #if DEBUG
                row("Configuration", "Debug")
                #else
                row("Configuration", "Release")
                #endif
                row("Network", model.network.isOnline ? (model.network.isExpensive ? "Online (cellular/expensive)" : "Online") : "Offline")
            } header: { Text("Diagnostics").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)

            if model.isMock {
                Section {
                    ForEach(["check server status", "show the gateway config file", "run a long deploy", "trigger an error", "simulate disconnect"], id: \.self) { prompt in
                        Button(prompt) {
                            model.chat.newConversation()
                            model.selectedTab = .agent
                            model.chat.send(prompt)
                        }
                        .font(BB.Font.mono)
                        .foregroundStyle(BB.Palette.signalText)
                    }
                } header: { Text("Mock scenarios").bbLabelStyle() } footer: {
                    Text("Shortcuts that exercise streaming, tools, errors and connection loss.").font(BB.Font.caption)
                }
                .listRowBackground(BB.Palette.surface)
            }

            #if DEBUG
            Section {
                Button("Reset preferences", role: .destructive) {
                    model.settings.resetAll()
                    model.toasts.show("Preferences reset — relaunch to apply")
                }
            } header: { Text("Debug only").bbLabelStyle() } footer: {
                Text("Hidden in Release builds.").font(BB.Font.caption)
            }
            .listRowBackground(BB.Palette.surface)
            #endif
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Developer")
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).bbLabelStyle()
            Spacer()
            Text(value).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textPrimary).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - About

struct AboutView: View {
    private let repo = URL(string: "https://github.com/hamzaibnzakir/brainbox-agent-ios-app")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    AgentOrb(mode: .ready, size: 84)
                    Text("Brainbox Agent").font(BB.Font.title).foregroundStyle(BB.Palette.textPrimary)
                    Text("Your personal AI agent control center.").font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                    Text("Version \(Bundle.main.appVersion)").font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .bbEntrance()
            }
            .listRowBackground(Color.clear)

            Section {
                Link(destination: repo) { Label("Source & docs", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: repo.appendingPathComponent("blob/main/docs/AGENT_PROTOCOL.md")) { Label("Agent protocol", systemImage: "doc.text") }
                Link(destination: repo.appendingPathComponent("blob/main/docs/HERMES_INTEGRATION.md")) { Label("Hermes integration plan", systemImage: "hourglass") }
                Link(destination: repo.appendingPathComponent("blob/main/docs/SECURITY.md")) { Label("Security review", systemImage: "lock.shield") }
            }
            .foregroundStyle(BB.Palette.signalText)
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("About")
    }
}
