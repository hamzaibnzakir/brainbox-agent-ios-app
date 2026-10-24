import SwiftUI
import BrainboxCore

/// Server tab in Hermes mode: a compact, real overview of the VPS plus entry
/// points to the Brainbox workspace files, the direct terminal and diagnostics.
struct HermesServerHub: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabIsActive) private var isActive
    @Binding var path: [ServerDestination]

    private var workspace: HermesWorkspace { model.hermes }

    var body: some View {
        VStack(alignment: .leading, spacing: BB.Space.l) {
            BBCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Overview").bbLabelStyle()
                        Spacer()
                        if let updated = workspace.overviewUpdated {
                            Text("Updated \(updated.formatted(date: .omitted, time: .shortened))").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                        }
                    }
                    if let overview = workspace.overview {
                        HStack(spacing: 8) {
                            StatusDot(tone: overview.hermes.reachable ? .live : .danger, pulsing: false, size: 7)
                            Text(overview.hermes.reachable ? "Hermes is responding" + (overview.hermes.latencyMs.map { " · \(Int($0)) ms" } ?? "") : "Hermes isn't responding")
                                .font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                        }
                        ServerFactsView(host: overview.host)
                    } else {
                        Text(workspace.overviewError ?? "Loading…").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    }
                }
            }
            .accessibilityIdentifier("server.overview")

            VStack(spacing: 10) {
                row(.files, "Files", "Inbox and outbox in the Brainbox workspace", "folder", available: workspace.features?.files == true)
                row(.terminal, "Terminal", "A real shell on your VPS (private over Tailscale)", "terminal", available: workspace.gatewayInfo != nil)
                row(.diagnostics, "Diagnostics", "Recent requests, proxy and connection details", "stethoscope", available: true)
            }
            if workspace.gatewayInfo == nil && model.connectionState.isConnected {
                Text("Files, terminal and server details come from the Brainbox proxy. This connection goes straight to Hermes, so they're unavailable.")
                    .font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
            }
        }
        .task(id: "\(isActive)-\(model.connectionState.isConnected)") {
            guard isActive else { return }
            while !Task.isCancelled {
                await workspace.refreshOverview()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func row(_ destination: ServerDestination, _ title: String, _ detail: String, _ symbol: String, available: Bool) -> some View {
        Button { path.append(destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(BB.Palette.textPrimary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(BB.Font.callout.weight(.medium)).foregroundStyle(BB.Palette.textPrimary)
                    Text(available ? detail : "Not available on this connection").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(BB.Palette.textTertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("server.\(destination.rawValue)")
    }
}

enum ServerDestination: String, Hashable {
    case files, terminal, diagnostics
}

/// Diagnostics: real request log (paths, status, timing — never tokens or bodies).
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var log: [RequestLogEntry] = []
    @State private var parity: HermesParityReport?
    @State private var parityError: String?

    var body: some View {
        List {
            Section {
                fact("Backend", model.settings.providerKind.displayName)
                fact("Connection", model.connectionState.label)
                if let info = model.hermes.gatewayInfo {
                    fact("Brainbox proxy", "v\(info.version ?? "?")")
                    fact("This device", info.deviceName ?? "—")
                    if let features = info.features {
                        fact("Proxy features", [features.runRelay ? "resumable streaming" : nil, features.files ? "files" : nil,
                                                features.terminal ? "terminal" : nil, features.commands ? "commands" : nil,
                                                features.commandExec ? "Hermes command handlers" : nil,
                                                features.chatManagement ? "chat delete/archive" : nil]
                            .compactMap { $0 }.joined(separator: ", "))
                        if !features.runRelay {
                            Text("This proxy can't resume a dropped stream: after a disconnect, replies arrive only when they finish. Update the proxy to fix it.")
                                .font(BB.Font.caption).foregroundStyle(BB.Palette.warning)
                        }
                    }
                } else {
                    fact("Brainbox proxy", "not in use")
                }
                if let report = model.hermes.report {
                    fact("Hermes compatible", report.isCompatible ? "yes" : "no")
                }
                fact("App version", Bundle.main.appVersion)
            } header: { Text("Connection").bbLabelStyle() }
            .listRowBackground(BB.Palette.surface)

            if model.hermes.gatewayInfo?.features?.parity == true {
                Section {
                    if let parity {
                        fact("Model", parity.model.isEmpty ? "—" : parity.model)
                        fact("Telegram persona prompt", parity.personaPromptChars > 0
                             ? (parity.gatewayPromptApplied ? "applied to app runs too" : "Telegram only") : "none set")
                        if parity.remainingDifferences.isEmpty {
                            Label("No remaining differences found.", systemImage: "checkmark.circle").font(BB.Font.callout)
                        } else {
                            ForEach(parity.remainingDifferences, id: \.self) { line in
                                Label(line, systemImage: "arrow.left.arrow.right").font(BB.Font.callout)
                            }
                        }
                    } else if let parityError {
                        Text(parityError).foregroundStyle(BB.Palette.textSecondary)
                    } else {
                        ProgressView()
                    }
                } header: { Text("Telegram vs app").bbLabelStyle() } footer: {
                    Text("Read from your Hermes config by Hermes' own code. Prompt text never leaves the server.")
                }
                .listRowBackground(BB.Palette.surface)
            }

            Section {
                if log.isEmpty {
                    Text("No requests yet.").foregroundStyle(BB.Palette.textSecondary)
                }
                ForEach(log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.method).font(BB.Font.monoSmall.weight(.semibold))
                            Text(entry.path).font(BB.Font.monoSmall).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(entry.status.map(String.init) ?? (entry.error ?? "—"))
                                .font(BB.Font.monoSmall)
                                .foregroundStyle(entry.isFailure ? BB.Palette.danger : BB.Palette.textSecondary)
                        }
                        Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.durationMs) ms\(entry.streamed ? " · stream" : "")")
                            .font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: { Text("Recent requests").bbLabelStyle() } footer: {
                Text("Paths, status and timing only — tokens, queries and message bodies are never recorded.")
            }
            .listRowBackground(BB.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Diagnostics")
        .refreshable { log = model.requestLog.log }
        .task {
            log = model.requestLog.log
            guard model.hermes.gatewayInfo?.features?.parity == true, let client = model.hermes.client else { return }
            do { parity = try await client.parityReport() } catch { parityError = error.asAgentError.message }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { model.requestLog.clear(); log = [] }
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(BB.Palette.textSecondary).multilineTextAlignment(.trailing)
        }
        .font(BB.Font.callout)
    }
}
