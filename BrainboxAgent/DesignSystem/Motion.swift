import SwiftUI

/// Brainbox motion identity — "precise, alive, never bouncy for its own sake".
///
/// * Signature curve: a critically-damped-ish spring (response 0.42, damping 0.86)
///   used for ~80% of layout motion.
/// * Duration palette: snappy (~0.28s) · standard (~0.42s) · gentle (~0.6s).
/// * Entrance pattern: rise 14pt + fade + de-blur, staggered 35ms, capped at 360ms.
/// * Exits are faster than entrances and ease-in.
/// * Ambient layer: the agent orb breathes; status dots pulse. Never more than
///   one hero motion at a time.
/// * Reduce Motion: spatial movement is removed, opacity crossfades remain.
///
/// The stagger/timeline helpers give the anime.js feel (staggered,
/// choreographed sequences) natively, without a web view.
enum Motion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let standard = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let gentle = Animation.spring(response: 0.6, dampingFraction: 0.9)
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.62)
    static let exit = Animation.easeIn(duration: 0.18)
    static let fade = Animation.easeOut(duration: 0.22)
    static let breathe = Animation.easeInOut(duration: 3.2).repeatForever(autoreverses: true)

    static let staggerStep: Double = 0.035
    static let staggerBudget: Double = 0.36

    /// Delay for the n-th element of a staggered group (capped budget).
    static func stagger(_ index: Int, step: Double = staggerStep) -> Double {
        min(Double(max(index, 0)) * step, staggerBudget)
    }

    /// Picks the reduced-motion alternative when needed.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

// MARK: - Entrance (staggered rise)

private struct EntranceModifier: ViewModifier {
    let index: Int
    let distance: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : distance)
            .scaleEffect(visible || reduceMotion ? 1 : 0.985, anchor: .top)
            .blur(radius: visible || reduceMotion ? 0 : 6)
            .onAppear {
                guard !visible else { return }
                withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion).delay(Motion.stagger(index))) {
                    visible = true
                }
            }
    }
}

extension View {
    /// Staggered "rise into place" entrance. Index drives the delay.
    func bbEntrance(index: Int = 0, distance: CGFloat = 14) -> some View {
        modifier(EntranceModifier(index: index, distance: distance))
    }
}

// MARK: - Transitions

private struct RiseEffect: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(Double(progress))
            .offset(y: (1 - progress) * 12)
            .scaleEffect(0.98 + 0.02 * progress)
            .blur(radius: (1 - progress) * 4)
    }
}

extension AnyTransition {
    /// Insert: rise + de-blur. Remove: quick fade + slight shrink.
    static var bbRise: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RiseEffect(progress: 0), identity: RiseEffect(progress: 1)),
            removal: .opacity.combined(with: .scale(scale: 0.97)).animation(Motion.exit)
        )
    }

    /// For banners sliding from the top edge.
    static var bbDropIn: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity.animation(Motion.exit)
        )
    }
}

// MARK: - Press feedback

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptics = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(configuration.isPressed ? .easeOut(duration: 0.08) : Motion.snappy, value: configuration.isPressed)
            .sensoryFeedback(trigger: configuration.isPressed) { _, pressed in
                haptics && pressed ? .impact(weight: .light, intensity: 0.55) : nil
            }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static var pressableSubtle: PressableStyle { PressableStyle(scale: 0.98, haptics: false) }
}

// MARK: - Error shake

struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 8
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Decaying sine so the shake settles firmly (no overshoot feel).
        let decay = max(0, 1 - animatableData / shakes)
        let x = travel * sin(animatableData * .pi * 2) * decay
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

extension View {
    /// Increment `trigger` to shake once.
    func bbShake(_ trigger: Int) -> some View {
        modifier(ShakeEffect(animatableData: CGFloat(trigger) * 3))
            .animation(.easeInOut(duration: 0.36), value: trigger)
    }
}

private struct ShakeOnAppear: ViewModifier {
    @State private var trigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .bbShake(trigger)
            .onAppear {
                guard !reduceMotion else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    trigger += 1
                }
            }
    }
}

extension View {
    /// One firm shake when the view first appears (errors).
    func bbShakeOnAppear() -> some View { modifier(ShakeOnAppear()) }
}

// MARK: - Shimmer

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.28), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        phase = -1
                        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                    }
                }
            }
    }
}

extension View {
    func bbShimmer(_ active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

// MARK: - Skeleton

struct SkeletonBlock: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(BB.Palette.surfaceHigh)
            .frame(width: width, height: height)
            .bbShimmer()
    }
}

// MARK: - Streaming caret

struct StreamingCaret: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(BB.Palette.signal)
            .frame(width: 8, height: 16)
            .opacity(on ? 1 : 0.15)
            .shadow(color: BB.Palette.signalGlow, radius: on ? 6 : 0)
            .onAppear {
                guard !reduceMotion else { on = true; return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Timeline choreography

/// Drives a multi-beat sequence (anime.js-style timeline) by stepping a
/// `phase` value with per-beat delays.
@MainActor
final class Choreography: ObservableObject {
    @Published private(set) var phase = 0
    private var task: Task<Void, Never>?

    func play(beats: [Double], animation: Animation = Motion.standard) {
        task?.cancel()
        phase = 0
        task = Task { [weak self] in
            for delay in beats {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(animation) { self?.phase += 1 }
            }
        }
    }
}
