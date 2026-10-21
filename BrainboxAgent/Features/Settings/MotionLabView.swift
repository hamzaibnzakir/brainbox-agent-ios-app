import SwiftUI
import BrainboxCore

/// Every signature motion moment on demand, for on-device review (no Mac,
/// no Simulator). Uses clearly-labelled sample data only.
struct MotionLabView: View {
    @State private var simulateReduce = false
    @State private var mood: MascotMood = .idle
    @State private var shape: MascotShape = .orb
    @State private var hop = 0
    @State private var replayLaunch = 0
    @State private var showConnected = false
    @State private var toolStatus: ToolStatus = .running
    @State private var shakeCount = 0
    @State private var confirmCount = 0
    @State private var streamed = ""
    @State private var streaming = false

    private struct OrbitItem: Identifiable {
        let id: String
        let symbol: String
        let color: Color
    }

    private let orbitItems = [
        OrbitItem(id: "ios", symbol: "iphone", color: BB.Palette.signal),
        OrbitItem(id: "telegram", symbol: "paperplane.fill", color: Color(hex: 0x2AABEE)),
        OrbitItem(id: "vps", symbol: "server.rack", color: BB.Palette.auraViolet),
        OrbitItem(id: "cron", symbol: "calendar.badge.clock", color: BB.Palette.auraMagenta)
    ]

    var body: some View {
        List {
            Section {
                Toggle("Simulate Reduce Motion", isOn: $simulateReduce).tint(BB.Palette.signal)
                Text("Sample data only — nothing here talks to your server.").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
            }
            .listRowBackground(BB.Palette.surface)

            lab("Launch") {
                VStack(spacing: 10) {
                    LaunchSequence(full: true, onFinished: {}).id(replayLaunch).frame(height: 180)
                    Button("Replay") { replayLaunch += 1 }.foregroundStyle(BB.Palette.signalText)
                }
            }

            lab("Mascots") {
                VStack(spacing: 14) {
                    MascotView(style: MascotStyle(shape: shape, hue: 0.04), mood: mood, size: 110, hopTrigger: hop)
                    Picker("Shape", selection: $shape) { ForEach(MascotShape.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    Picker("Mood", selection: $mood) { ForEach(MascotMood.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Button("Hop (teammate selected)") { hop += 1 }.foregroundStyle(BB.Palette.signalText)
                    MascotConstellation(members: Teammate.starterTeam.map { MascotConstellation.Member(id: $0.id, style: $0.mascot, mood: .idle) }, radius: 100, mascotSize: 40)
                        .frame(height: 170)
                }
            }

            lab("Streaming text") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(streamed.isEmpty ? " " : streamed).font(BB.Font.body).animation(Motion.micro, value: streamed)
                        if streaming { StreamingCaret() }
                    }
                    Button(streaming ? "Streaming…" : "Play") { Task { await playStream() } }
                        .disabled(streaming).foregroundStyle(BB.Palette.signalText)
                }
            }

            lab("Tool activity") {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ToolStatusIcon(status: toolStatus, size: 28)
                        Text("terminal · df -h").font(BB.Font.mono)
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surfaceSunken))
                    .bbAuraBorder(toolStatus == .running)
                    .bbShake(shakeCount)
                    HStack {
                        Button("Run") { withAnimation(Motion.smooth) { toolStatus = .running } }
                        Button("Succeed") { withAnimation(Motion.smooth) { toolStatus = .succeeded } }
                        Button("Fail") { withAnimation(Motion.smooth) { toolStatus = .failed }; shakeCount += 1 }
                    }
                    .buttonStyle(.bordered)
                }
            }

            lab("Approval — hold to confirm") {
                VStack(spacing: 10) {
                    HoldToConfirmButton(title: "Allow once") { confirmCount += 1 }
                    Text("Confirmed \(confirmCount)×").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
                }
            }

            lab("Connected pulse") {
                VStack(spacing: 10) {
                    PulseRings().frame(width: 120, height: 120)
                    Button("Show success sheet") { showConnected = true }.foregroundStyle(BB.Palette.signalText)
                }
            }

            lab("Sources orbit") {
                DepthOrbit(items: orbitItems) { item in
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(item.color))
                }
                .frame(maxWidth: .infinity)
            }

            lab("Live status") {
                VStack(alignment: .leading, spacing: 10) {
                    LiveIndicator(state: .connected)
                    LiveIndicator(state: .reconnecting(attempt: 2, retryIn: 4))
                    LiveIndicator(state: .failed(.serverUnavailable))
                }
            }
        }
        .listStyle(.insetGrouped)
        .bbScreen()
        .navigationTitle("Motion Lab")
        .environment(\.bbForceReduceMotion, simulateReduce)
        .sheet(isPresented: $showConnected) {
            ConnectedPulseSheet(title: "Hermes connected", detail: "Sample — Motion Lab", rows: [("Agent runs", true), ("Live run events", true), ("Approvals", true), ("Steer a running agent", false)], onDone: { showConnected = false })
                .environment(\.bbForceReduceMotion, simulateReduce)
                .presentationBackground(BB.Palette.backgroundRaised)
        }
    }

    private func lab<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            content().frame(maxWidth: .infinity).padding(.vertical, 6)
        } header: { Text(title).bbLabelStyle() }
        .listRowBackground(BB.Palette.surface)
    }

    private func playStream() async {
        streaming = true
        streamed = ""
        let words = "Disk usage is healthy: 41% used on /, 12% on /var. No action needed.".split(separator: " ")
        for word in words {
            try? await Task.sleep(nanoseconds: 70_000_000)
            streamed += (streamed.isEmpty ? "" : " ") + word
        }
        streaming = false
    }
}

// MARK: - Launch

/// Logo fades up from black, then an original tagline types out with a
/// blinking cursor (< 1.2 s). Tap anywhere to skip.
struct LaunchSequence: View {
    var full: Bool
    var onFinished: () -> Void
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced

    var body: some View {
        let reduce = system || forced
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(BB.Palette.auraGradient).frame(width: 64, height: 64).blur(radius: 18).opacity(phase >= 1 ? 0.7 : 0)
                MascotView(style: MascotStyle(shape: .orb, hue: 0.04), mood: .happy, size: 64, seed: Teammate.mainAssistantID)
                    .opacity(phase >= 1 ? 1 : 0)
                    .scaleEffect(phase >= 1 || reduce ? 1 : 0.8)
            }
            Text("Brainbox").font(.system(size: 30, weight: .semibold)).foregroundStyle(BB.Palette.textPrimary)
                .opacity(phase >= 1 ? 1 : 0)
            if full && phase >= 2 {
                TypewriterText(text: "your AI team, on your server", characterDelay: 0.022)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(Motion.animation(.smooth, reduceMotion: reduce)) { phase = 1 }
            try? await Task.sleep(nanoseconds: reduce ? 150_000_000 : 300_000_000)
            phase = 2
            try? await Task.sleep(nanoseconds: full && !reduce ? 850_000_000 : 250_000_000)
            onFinished()
        }
    }
}

/// Full-screen launch overlay used by RootView.
struct LaunchOverlay: View {
    var full: Bool
    var onDone: () -> Void
    @State private var visible = true

    var body: some View {
        ZStack {
            BB.Palette.background.ignoresSafeArea()
            LaunchSequence(full: full) { finish() }
        }
        .opacity(visible ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Skip intro")
    }

    private func finish() {
        guard visible else { return }
        withAnimation(.easeOut(duration: 0.3)) { visible = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            onDone()
        }
    }
}
