import SwiftUI
import BrainboxCore

/// The Brainbox "core": the app's hero element. Its motion encodes agent
/// state so status is visible at a glance, without reading text.
///
/// * ready     — slow breathing (ambient layer)
/// * thinking  — a comet arc orbits the core
/// * streaming — three satellites orbit, core brightens
/// * tool      — dashed ring rotates like a gear
/// * offline   — desaturated and still
/// * error     — warm danger tint, still
enum OrbMode: Equatable {
    case ready, thinking, streaming, tool, offline, error

    init(status: AgentStatus, connection: ConnectionState) {
        switch connection {
        case .failed: self = .error; return
        case .disconnected, .reconnecting: self = .offline; return
        case .connecting: self = .thinking; return
        case .connected: break
        }
        switch status {
        case .ready: self = .ready
        case .thinking: self = .thinking
        case .streaming: self = .streaming
        case .runningTool: self = .tool
        case .offline: self = .offline
        case .unavailable: self = .error
        }
    }
}

struct AgentOrb: View {
    var mode: OrbMode
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !Motion.ambient(reduceMotion: reduceMotion) || mode == .offline || mode == .error)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize, time: Motion.ambient(reduceMotion: reduceMotion) ? t : 0)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.gentle, value: mode)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch mode {
        case .ready: return "Agent ready"
        case .thinking: return "Agent thinking"
        case .streaming: return "Agent responding"
        case .tool: return "Agent running a tool"
        case .offline: return "Agent offline"
        case .error: return "Agent error"
        }
    }

    private var tint: (core: Color, edge: Color, glow: Color) {
        switch mode {
        case .offline: return (Color(hex: 0x6B7078), Color(hex: 0x3A3F46), Color.clear)
        case .error: return (Color(hex: 0xFF8A7A), Color(hex: 0xB8323F), Color(hex: 0xFF5D6C).opacity(0.35))
        default: return (BB.Palette.signal, Color(hex: 0x6F7DFF), BB.Palette.signalGlow)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time seconds: TimeInterval) {
        // Keep every term in CGFloat so the math type-checks unambiguously.
        let t = CGFloat(seconds.truncatingRemainder(dividingBy: 10_000))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let busy = mode == .thinking || mode == .streaming || mode == .tool

        // Ambient breathing (sine, 3.2s period). Busy states breathe faster.
        let period: CGFloat = busy ? 1.4 : 3.2
        let breath: CGFloat = (sin(t * 2 * .pi / period) + 1) / 2
        let coreRadius = radius * (0.56 + 0.04 * breath)

        // Glow (secondary layer)
        if mode != .offline {
            var glow = context
            glow.addFilter(.blur(radius: radius * 0.28))
            let glowRadius = coreRadius * (1.25 + 0.12 * breath + (busy ? 0.1 : 0))
            glow.fill(Path(ellipseIn: CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)), with: .color(tint.glow))
        }

        // Core: radial gradient whose highlight drifts on a slow orbit,
        // which reads as a liquid, living surface.
        let dx: CGFloat = cos(t * 0.7) * coreRadius * 0.28
        let dy: CGFloat = sin(t * 0.9) * coreRadius * 0.28 - coreRadius * 0.15
        let drift = CGPoint(x: center.x + dx, y: center.y + dy)
        let core = Path(ellipseIn: CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2))
        context.fill(core, with: .radialGradient(
            Gradient(colors: [Color.white.opacity(mode == .offline ? 0.25 : 0.9), tint.core, tint.edge]),
            center: drift,
            startRadius: 0,
            endRadius: coreRadius * 1.5
        ))
        context.stroke(core, with: .color(Color.white.opacity(0.12)), lineWidth: 0.75)

        let ringRadius = radius * 0.86
        let ringRect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)

        switch mode {
        case .thinking:
            // Comet arc: a gradient-faded arc orbiting at constant speed.
            let start = Double(t * 3.2)
            for i in 0..<14 {
                let a0 = start - Double(i) * 0.09
                var p = Path()
                p.addArc(center: center, radius: ringRadius, startAngle: .radians(a0 - 0.09), endAngle: .radians(a0), clockwise: false)
                context.stroke(p, with: .color(tint.core.opacity(1 - Double(i) / 14)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        case .streaming:
            for i in 0..<3 {
                let angle: CGFloat = t * 2.4 + CGFloat(i) * (2 * .pi / 3)
                let p = CGPoint(x: center.x + cos(angle) * ringRadius, y: center.y + sin(angle) * ringRadius)
                let r: CGFloat = radius * (0.075 + 0.02 * sin(t * 4 + CGFloat(i)))
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(tint.core))
            }
        case .tool:
            var ring = context
            ring.translateBy(x: center.x, y: center.y)
            ring.rotate(by: .radians(Double(t) * 1.1))
            ring.translateBy(x: -center.x, y: -center.y)
            ring.stroke(Path(ellipseIn: ringRect), with: .color(tint.core.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3, 5]))
        case .ready:
            context.stroke(Path(ellipseIn: ringRect), with: .color(tint.core.opacity(Double(0.10 + 0.12 * breath))), lineWidth: 1)
        case .offline, .error:
            context.stroke(Path(ellipseIn: ringRect), with: .color(Color.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 24) {
            AgentOrb(mode: .ready, size: 80)
            AgentOrb(mode: .thinking, size: 80)
            AgentOrb(mode: .streaming, size: 80)
        }
        HStack(spacing: 24) {
            AgentOrb(mode: .tool, size: 80)
            AgentOrb(mode: .offline, size: 80)
            AgentOrb(mode: .error, size: 80)
        }
    }
    .padding()
    .background(BB.Palette.background)
}
