import SwiftUI
import BrainboxCore

// MARK: - Tokens (Section 4A of the build spec)

/// Named motion tokens. Screens ask for a token, never a raw duration, so
/// Reduce Motion can swap every token for a short crossfade in one place.
enum MotionToken: String, CaseIterable {
    case snappy, smooth, bouncy, drag, micro
}

extension Motion {
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.90)
    static let bouncy = Animation.spring(response: 0.50, dampingFraction: 0.68)
    static let drag = Animation.interactiveSpring(response: 0.30, dampingFraction: 0.85)
    static let micro = Animation.easeOut(duration: 0.15)
    /// Reduced-motion replacement for every token.
    static let reducedCrossfade = Animation.easeInOut(duration: 0.2)
    /// Stagger cap: the 9th item onwards appears together with the 8th.
    static let maxStaggeredItems = 8

    static func animation(_ token: MotionToken, reduceMotion: Bool) -> Animation {
        if reduceMotion { return reducedCrossfade }
        switch token {
        case .snappy: return snappy
        case .smooth: return smooth
        case .bouncy: return bouncy
        case .drag: return drag
        case .micro: return micro
        }
    }

    static func cappedStagger(_ index: Int) -> Double {
        Double(min(max(index, 0), maxStaggeredItems - 1)) * staggerStep
    }
}

private struct ForceReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Motion Lab's "simulate Reduce Motion" switch. New components honour
    /// it in addition to the system setting.
    var bbForceReduceMotion: Bool {
        get { self[ForceReduceMotionKey.self] }
        set { self[ForceReduceMotionKey.self] = newValue }
    }
}

/// Reads system Reduce Motion + the Motion Lab override.
struct ReducedMotionReader<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced
    @ViewBuilder var content: (Bool) -> Content
    var body: some View { content(system || forced) }
}

// MARK: - Connected pulse

/// Two or three concentric glow rings expanding from a centred icon:
/// scale 1 → 1.6, opacity 0.5 → 0, ~1.8 s loop.
struct PulseRings: View {
    var color: Color = BB.Palette.signal
    var rings = 3
    var period: Double = 1.8
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced

    var body: some View {
        let reduce = system || forced
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduce || !Motion.ambientEnabled)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<rings, id: \.self) { i in
                    let phase = reduce ? 0.35 : ((t / period) + Double(i) / Double(rings)).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity(0.9), lineWidth: 1.5)
                        .background(Circle().fill(color.opacity(0.08)))
                        .scaleEffect(1 + 0.6 * phase)
                        .opacity(0.5 * (1 - phase))
                        .blur(radius: 0.5 + 2 * phase)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Success sheet shown only after a real successful connection test.
struct ConnectedPulseSheet: View {
    let title: String
    let detail: String
    let rows: [(String, Bool)]
    var buttonTitle = "Done"
    var onDone: () -> Void
    @State private var beat = 0
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced

    var body: some View {
        let reduce = system || forced
        VStack(spacing: 18) {
            ZStack {
                PulseRings().frame(width: 150, height: 150)
                Circle()
                    .fill(BB.Palette.auraGradient)
                    .frame(width: 64, height: 64)
                    .shadow(color: BB.Palette.signalGlow, radius: 18)
                    .overlay(
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(BB.Palette.onSignal)
                    )
                    .scaleEffect(beat >= 1 ? 1 : 0.6)
                    .opacity(beat >= 1 ? 1 : 0)
            }
            .frame(height: 160)
            VStack(spacing: 6) {
                Text(title).font(BB.Font.title).foregroundStyle(BB.Palette.textPrimary)
                Text(detail).font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary).multilineTextAlignment(.center)
            }
            .opacity(beat >= 2 ? 1 : 0)
            .offset(y: beat >= 2 || reduce ? 0 : 10)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 10) {
                        Image(systemName: row.1 ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(row.1 ? BB.Palette.success : BB.Palette.textTertiary)
                        Text(row.0).font(BB.Font.callout).foregroundStyle(row.1 ? BB.Palette.textPrimary : BB.Palette.textTertiary)
                        Spacer()
                    }
                    .opacity(beat >= 3 ? 1 : 0)
                    .offset(y: beat >= 3 || reduce ? 0 : 8)
                    .animation(Motion.animation(.smooth, reduceMotion: reduce).delay(Motion.cappedStagger(index)), value: beat)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: BB.Radius.l, style: .continuous).fill(BB.Palette.surface))
            Button(action: onDone) {
                Text(buttonTitle)
                    .font(BB.Font.headline)
                    .foregroundStyle(BB.Palette.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surfaceHigh))
            }
            .buttonStyle(.pressable)
            .opacity(beat >= 4 ? 1 : 0)
            .accessibilityIdentifier("connected.done")
        }
        .padding(22)
        .sensoryFeedback(.success, trigger: beat >= 1)
        .task {
            let beats: [Double] = reduce ? [0, 0, 0, 0] : [0.05, 0.35, 0.2, 0.25]
            for delay in beats {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                withAnimation(Motion.animation(beat == 0 ? .bouncy : .smooth, reduceMotion: reduce)) { beat += 1 }
            }
        }
    }
}

// MARK: - Rotating aura border (running tools)

struct AuraBorder: ViewModifier {
    var active: Bool
    var cornerRadius: CGFloat = BB.Radius.m
    var period: Double = 2.6
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced

    func body(content: Content) -> some View {
        let reduce = system || forced
        content.overlay {
            if active {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduce || !Motion.ambientEnabled)) { timeline in
                    let angle = reduce ? 0 : (timeline.date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1) * 360
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            AngularGradient(colors: [BB.Palette.auraOrange, BB.Palette.auraMagenta, BB.Palette.auraViolet.opacity(0.2), BB.Palette.auraOrange],
                                            center: .center, angle: .degrees(angle)),
                            lineWidth: 1.5)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

extension View {
    func bbAuraBorder(_ active: Bool, cornerRadius: CGFloat = BB.Radius.m) -> some View {
        modifier(AuraBorder(active: active, cornerRadius: cornerRadius))
    }
}

// MARK: - Hold to confirm

/// Dangerous approvals: a progress ring fills over `duration`; releasing
/// early cancels. Completion fires a success haptic and `action`.
struct HoldToConfirmButton: View {
    let title: String
    var systemImage = "checkmark.shield"
    var tint: Color = BB.Palette.warning
    var duration: Double = 1.2
    var action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var confirmed = 0
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)
            Text(holding ? "Keep holding…" : title)
                .font(BB.Font.headline)
                .foregroundStyle(BB.Palette.textPrimary)
                .contentTransition(.interpolate)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(tint.opacity(holding ? 0.18 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(tint.opacity(0.5)))
        .scaleEffect(holding ? 0.98 : 1)
        .animation(Motion.snappy, value: holding)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in begin() }
                .onEnded { _ in cancel() }
        )
        .sensoryFeedback(.success, trigger: confirmed)
        .sensoryFeedback(.impact(weight: .light), trigger: holding) { _, new in new }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityHint("Double-tap and hold to confirm")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() } // VoiceOver: explicit activation, no hold needed
    }

    private func begin() {
        guard !holding else { return }
        holding = true
        withAnimation(.linear(duration: duration)) { progress = 1 }
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, holding else { return }
            holding = false
            confirmed += 1
            action()
            withAnimation(Motion.smooth) { progress = 0 }
        }
    }

    private func cancel() {
        guard holding else { return }
        holding = false
        holdTask?.cancel()
        withAnimation(Motion.snappy) { progress = 0 }
    }
}

// MARK: - Typewriter

/// Reveals text character by character with a blinking underscore cursor.
struct TypewriterText: View {
    let text: String
    var characterDelay: Double = 0.028
    var font: Font = BB.Font.callout
    var color: Color = BB.Palette.textSecondary
    @State private var visible = 0
    @State private var cursorOn = true
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced

    var body: some View {
        let reduce = system || forced
        HStack(spacing: 0) {
            Text(String(text.prefix(reduce ? text.count : visible)))
            Text("_").opacity(cursorOn ? 1 : 0)
        }
        .font(font.monospaced())
        .foregroundStyle(color)
        .accessibilityElement()
        .accessibilityLabel(text)
        .task(id: text) {
            visible = 0
            guard !reduce else { visible = text.count; return }
            for i in 1...max(text.count, 1) {
                try? await Task.sleep(nanoseconds: UInt64(characterDelay * 1_000_000_000))
                if Task.isCancelled { return }
                visible = i
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                cursorOn.toggle()
            }
        }
    }
}

// MARK: - Depth orbit

/// Items travel an ellipse; foreground items scale up, sharpen and reach
/// full opacity, receding ones shrink, fade and blur (depth of field).
struct DepthOrbit<Item: Identifiable, ItemView: View>: View {
    let items: [Item]
    var radiusX: CGFloat = 110
    var radiusY: CGFloat = 30
    var period: Double = 14
    @ViewBuilder var content: (Item) -> ItemView
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced

    var body: some View {
        let reduce = system || forced
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduce || !Motion.ambientEnabled)) { timeline in
            let t = reduce ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let angle = (t / period) * 2 * .pi + Double(index) / Double(max(items.count, 1)) * 2 * .pi
                    let depth = (sin(angle) + 1) / 2 // 0 back … 1 front
                    content(item)
                        .scaleEffect(0.62 + 0.38 * depth)
                        .opacity(0.35 + 0.65 * depth)
                        .blur(radius: (1 - depth) * 2.5)
                        .offset(x: CGFloat(cos(angle)) * radiusX, y: CGFloat(sin(angle)) * radiusY)
                        .zIndex(depth)
                }
            }
            .frame(width: radiusX * 2 + 60, height: radiusY * 2 + 70)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Live dot / offline banner helpers

/// Breathing dot for "connected"; shimmer while reconnecting.
struct LiveIndicator: View {
    var state: ConnectionState
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: state.tone, pulsing: state.isConnected, size: 7)
            Text(state.label)
                .font(BB.Font.label)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(BB.Palette.textSecondary)
                .bbShimmer(isReconnecting)
                .contentTransition(.interpolate)
        }
        .animation(Motion.smooth, value: state.label)
    }

    private var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        if case .connecting = state { return true }
        return false
    }
}
