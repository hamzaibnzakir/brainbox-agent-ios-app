import BrainboxCore
import HermesKit
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var approvalMode = "smart"
    @State private var busyMode = "queue"
    @State private var showConfig = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                NavigationLink { ConnectView(isOnboarding: false) } label: {
                    RowLabel(title: model.profile?.name ?? "Server", subtitle: model.profile?.target.display, symbol: "server.rack", index: 0)
                }
            } header: { Text("Connection") }

            Section {
                NavigationLink { PetGallery() } label: {
                    HStack(spacing: DS.S.m) {
                        Companion(mood: .idle, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pet").font(DS.F.body)
                            Text(model.pet?.name ?? "Brainbox bot").font(DS.F.caption).foregroundStyle(DS.C.ink3)
                        }
                    }
                }
                Toggle("Show pet in chat", isOn: $model.preferences.showPet)
            } header: { Text("Companion") } footer: { Text("Hermes pets (petdex) react to what the agent is doing, like on Desktop.") }

            Section {
                Picker("Approvals", selection: $approvalMode) {
                    Text("Ask for risky commands").tag("smart")
                    Text("Ask for every command").tag("manual")
                    Text("Never ask (YOLO)").tag("off")
                }
                .onChange(of: approvalMode) { _, v in Task { await set("approvals.mode", v) } }
                Picker("While Hermes is busy", selection: $busyMode) {
                    Text("Queue my message").tag("queue")
                    Text("Interrupt and send").tag("interrupt")
                    Text("Steer the current turn").tag("steer")
                }
                .onChange(of: busyMode) { _, v in Task { await set("busy", v) } }
                NavigationLink { ModelsScreen() } label: { Text("Model and reasoning") }
                NavigationLink { SoulScreen() } label: { Text("Persona") }
            } header: { Text("Agent") } footer: { Text("These are Hermes' own settings on the server.") }

            Section {
                Picker("Theme", selection: $model.preferences.theme) {
                    Text("System").tag(Preferences.Theme.system)
                    Text("Light").tag(Preferences.Theme.light)
                    Text("Dark").tag(Preferences.Theme.dark)
                }
                VStack(alignment: .leading) {
                    Text("Chat text size").font(DS.F.small)
                    Slider(value: $model.preferences.textScale, in: 0.85...1.4, step: 0.05)
                }
                Toggle("Show reasoning", isOn: $model.preferences.showReasoning)
                Toggle("Expand failed tools", isOn: $model.preferences.showToolDetails)
                Toggle("Haptics", isOn: $model.preferences.haptics)
            } header: { Text("Appearance") }

            Section {
                Toggle("When a reply is ready", isOn: $model.preferences.notifyOnFinish)
                Toggle("When Hermes needs approval", isOn: $model.preferences.notifyOnApproval)
                Button("Allow notifications") { Notifier.shared.requestAuthorization() }
            } header: { Text("Notifications") } footer: {
                Text("Local notifications from the app itself (no push server). While the app is closed, iOS wakes it from time to time to check on running chats.")
            }

            Section {
                Toggle("Read replies aloud", isOn: $model.preferences.speakReplies)
            } header: { Text("Voice") } footer: { Text("Hold the mic to talk. Speech-to-text and voices use Hermes' audio settings on the server.") }

            Section {
                Toggle("Face ID for SSH key and terminal", isOn: $model.preferences.lockWithFaceID)
                Toggle("Reconnect automatically", isOn: $model.preferences.autoReconnect)
            } header: { Text("Security") }

            Section {
                Button("Edit config.yaml") { showConfig = true }
                NavigationLink { UpdatesScreen() } label: { Text("Updates & doctor") }
            } header: { Text("Advanced") }

            Section {
                LabeledContent("App", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                if let v = model.serverInfo?.version { LabeledContent("Hermes", value: v) }
                LabeledContent("Connection", value: "SSH → hermes serve (gateway)")
            } header: { Text("About") }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showConfig) { NavigationStack { ConfigEditor() } }
        .task { await load() }
    }

    private func load() async {
        if let v = try? await model.engine.call(nil, "config.get", ["key": "approvals.mode"]), let s = v["value"]?.stringValue, !s.isEmpty { approvalMode = s }
        if let v = try? await model.engine.call(nil, "config.get", ["key": "busy"]), let s = v["value"]?.stringValue, !s.isEmpty { busyMode = s }
    }

    private func set(_ key: String, _ value: String) async {
        do {
            _ = try await model.engine.call(model.currentChat, "config.set", ["key": .string(key), "value": .string(value)])
            model.toast = "Saved"
        } catch {
            model.toast = error.localizedDescription
        }
    }
}

/// Raw config.yaml, like Desktop's advanced editor.
struct ConfigEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var error: String?

    var body: some View {
        TextEditor(text: $text)
            .font(DS.F.monoSmall)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(DS.S.s)
            .overlay(alignment: .top) { if let error { ErrorBanner(message: error).padding(DS.S.m) } }
            .navigationTitle("config.yaml")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            guard await Biometrics.authenticate(reason: "Change Hermes' configuration") else { return }
                            if await perform(model, "PUT", "/api/config/raw", json: ["yaml_text": .string(text)], success: "Config saved") != nil {
                                original = text
                                dismiss()
                            }
                        }
                    }
                    .disabled(text == original)
                }
            }
            .task {
                do {
                    let raw = try await model.client().get("/api/config/raw")
                    text = raw["yaml"]?.stringValue ?? raw["content"]?.stringValue ?? raw["yaml_text"]?.stringValue ?? raw.stringValue ?? ""
                    original = text
                } catch { self.error = error.localizedDescription }
            }
    }
}

/// Hermes pets (petdex), same RPCs as Desktop's pet settings.
struct PetGallery: View {
    @Environment(AppModel.self) private var model
    @State private var gallery: JSONValue?
    @State private var error: String?
    @State private var working: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Companion(mood: .celebrate, size: 96)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                if model.pet != nil {
                    Button("Use the Brainbox bot instead") { Task { await call("pet.disable", [:]) } }
                }
            }
            if let error { Section { Text(error).foregroundStyle(DS.C.bad).font(DS.F.small) } }
            if let gallery {
                let pets = gallery["pets"]?.arrayValue ?? []
                Section("Pets") {
                    if pets.isEmpty { Text("No pets found. Your server needs internet access to reach petdex.").foregroundStyle(DS.C.ink3) }
                    ForEach(pets, id: \.self) { pet in
                        let slug = pet["slug"]?.stringValue ?? ""
                        Button {
                            Task { await call("pet.select", ["slug": .string(slug)]) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pet["displayName"]?.stringValue ?? pet["name"]?.stringValue ?? slug).font(DS.F.body).foregroundStyle(DS.C.ink)
                                    Text(pet["description"]?.stringValue ?? "").font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(2)
                                }
                                Spacer()
                                if working == slug { ProgressView() }
                                else if gallery["active"]?.stringValue == slug { Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.C.volt) }
                                else if pet["installed"]?.boolValue == true { Text("Installed").font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                            }
                        }
                    }
                }
            } else if error == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle("Pet")
        .task { await load() }
    }

    private func load() async {
        do {
            gallery = try await model.engine.call(nil, "pet.gallery", [:], timeout: 60)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func call(_ method: String, _ params: [String: JSONValue]) async {
        working = params["slug"]?.stringValue ?? method
        defer { working = nil }
        do {
            _ = try await model.engine.call(nil, method, params, timeout: 120)
            await model.loadPet()
            await load()
            Haptic.success()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
