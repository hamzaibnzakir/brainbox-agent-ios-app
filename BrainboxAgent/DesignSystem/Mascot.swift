import SwiftUI
import BrainboxCore

/// The Brainbox bot, used for the assistant and every preset (presets vary the
/// antenna and head shape). Idle micro-motion runs on schedules seeded by the
/// preset id so a group never moves in lockstep. Moods come only from real
/// state (`MascotMood.derive`), never from timers, and nothing moves under
/// Reduce Motion.
struct MascotView: View {
    static let defaultSeed = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    var style: MascotStyle
    var mood: MascotMood = .idle
    var size: CGFloat = 56
    /// Seed for the idle schedule (use the teammate id).
    var seed: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    /// Small hop when this mascot becomes the selected one.
    var hopTrigger: Int = 0

    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced
    @Environment(\.colorScheme) private var scheme
    @State private var hop: CGFloat = 0
    @State private var moodSince = Date()

    /// Busy states animate at 30 fps; idle only needs 15 (blinks, drift).
    private var frameInterval: Double { mood == .working || mood == .thinking ? 1.0 / 30.0 : 1.0 / 15.0 }

    var body: some View {
        let reduce = system || forced
        let animate = Motion.ambientEnabled && !reduce && mood != .offline
        TimelineView(.animation(minimumInterval: frameInterval, paused: !animate)) { timeline in
            let t = animate ? timeline.date.timeIntervalSinceReferenceDate : 0
            let sinceMood = animate ? timeline.date.timeIntervalSince(moodSince) : 10
            Canvas { context, canvasSize in
                BotRenderer(style: style, mood: mood, seed: seed, time: t, sinceMood: sinceMood, animate: animate, dark: scheme == .dark)
                    .draw(in: &context, size: canvasSize)
            }
        }
        .frame(width: size, height: size)
        .offset(y: -hop * size * 0.16)
        .onChange(of: mood) { _, _ in moodSince = Date() }
        .onChange(of: hopTrigger) { _, _ in
            guard !reduce else { return }
            withAnimation(Motion.bouncy) { hop = 1 }
            withAnimation(Motion.bouncy.delay(0.16)) { hop = 0 }
        }
        .accessibilityElement()
        .accessibilityLabel("Brainbox bot, \(mood.label)")
    }
}

/// The Brainbox bot: an original rounded head with a dark visor and two
/// expressive eyes. Monochrome; a single small "status node" on the antenna
/// takes a status colour, and every state also changes the eyes' shape, so
/// colour is never the only cue. Pure drawing (shared with the Motion Lab).
struct BotRenderer {
    var style: MascotStyle
    var mood: MascotMood
    var seed: UUID
    var time: TimeInterval
    /// Seconds since the mood last changed (one-shot motions settle after it).
    var sinceMood: TimeInterval
    var animate: Bool
    var dark: Bool

    private func rand(_ slot: Int) -> Double {
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        var x: UInt64 = 1469598103934665603
        for b in bytes { x = (x ^ UInt64(b)) &* 1099511628211 }
        x = (x ^ UInt64(slot &* 2654435761)) &* 1099511628211
        return Double(x % 10_000) / 10_000
    }

    private var headColor: Color { dark ? Color(white: 0.93) : Color(white: 0.09) }
    private var visorColor: Color { dark ? Color(white: 0.04) : Color(white: 0.0) }
    private var eyeColor: Color { mood == .offline ? Color(white: 0.35) : Color(white: 0.97) }
    private var nodeColor: Color {
        switch mood {
        case .waitingApproval: return BB.Palette.ion
        case .failed: return BB.Palette.danger
        case .happy: return BB.Palette.success
        case .working, .thinking: return dark ? .white : Color(white: 0.1)
        case .offline, .interrupted, .idle: return Color(white: 0.5)
        }
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let unit = min(w, h)
        let settle = min(sinceMood / 0.6, 1)       // 0 → 1 over the first 0.6 s of a mood

        // Motion -----------------------------------------------------------------
        let blinkPeriod = 3.8 + rand(1) * 2.4
        let blinkPhase = (time + rand(2) * blinkPeriod).truncatingRemainder(dividingBy: blinkPeriod)
        var blink: Double = animate && blinkPhase < 0.16 ? sin(blinkPhase / 0.16 * .pi) : 0
        let drift = animate ? sin(time * 0.45 + rand(3) * 6) : 0
        var lookX: Double = drift * 0.25
        var lookY: Double = 0
        var bob: Double = animate ? sin(time * 1.2 + rand(4) * 6) * 0.012 : 0
        var tilt: Double = 0

        switch mood {
        case .thinking:
            lookX = 0.55 + (animate ? sin(time * 0.8) * 0.15 : 0)
            lookY = -0.5
            blink *= 0.5
        case .working:
            // Purposeful scan: eyes sweep together across the visor.
            lookX = animate ? sin(time * 2.6) * 0.75 : 0
            bob = animate ? sin(time * 5.2) * 0.008 : 0
            blink = 0
        case .waitingApproval:
            lookX = 0; lookY = 0; blink = 0
            bob = animate ? sin(time * 1.4) * 0.018 : 0
        case .happy:
            // One small hop, then still.
            bob = sinceMood < 0.5 ? -sin(sinceMood / 0.5 * .pi) * 0.06 : 0
            lookX = 0
        case .interrupted:
            // A short nod that settles.
            bob = sinceMood < 0.6 ? sin(sinceMood / 0.6 * .pi) * 0.03 : 0.012
            lookY = 0.35 * settle
            lookX = 0
        case .failed:
            tilt = -6 * settle
            lookX = 0
        case .offline:
            lookX = 0; bob = 0; blink = 0
        case .idle:
            break
        }

        var g = context
        g.translateBy(x: w / 2, y: h / 2 + CGFloat(bob) * unit)
        g.rotate(by: .degrees(tilt))

        let headW = unit * 0.78, headH = unit * 0.64
        let headRect = CGRect(x: -headW / 2, y: -headH / 2 + unit * 0.06, width: headW, height: headH)
        let corner = headH * (style.shape == .orb ? 0.5 : style.shape == .squircle ? 0.38 : 0.3)

        // Antenna + status node (shape varies per preset).
        let stemTop = CGPoint(x: 0, y: headRect.minY - unit * 0.13)
        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: headRect.minY))
        stem.addLine(to: stemTop)
        g.stroke(stem, with: .color(headColor), style: StrokeStyle(lineWidth: max(1.5, unit * 0.035), lineCap: .round))
        let nodeR = unit * 0.055
        var nodeScale: CGFloat = 1
        if animate && (mood == .working || mood == .thinking) {
            nodeScale = 1 + 0.18 * CGFloat(0.5 + 0.5 * sin(time * (mood == .working ? 6 : 2.5)))
        }
        let nodeRect = CGRect(x: -nodeR * nodeScale, y: stemTop.y - nodeR * nodeScale, width: nodeR * 2 * nodeScale, height: nodeR * 2 * nodeScale)
        switch style.shape {
        case .triangle, .diamond:
            var diamond = Path()
            diamond.move(to: CGPoint(x: nodeRect.midX, y: nodeRect.minY))
            diamond.addLine(to: CGPoint(x: nodeRect.maxX, y: nodeRect.midY))
            diamond.addLine(to: CGPoint(x: nodeRect.midX, y: nodeRect.maxY))
            diamond.addLine(to: CGPoint(x: nodeRect.minX, y: nodeRect.midY))
            diamond.closeSubpath()
            g.fill(diamond, with: .color(nodeColor))
        default:
            g.fill(Path(ellipseIn: nodeRect), with: .color(nodeColor))
        }
        // Calm attention ripple while waiting for approval.
        if mood == .waitingApproval && animate {
            let phase = (time * 0.6).truncatingRemainder(dividingBy: 1)
            let rr = nodeR * (1.4 + 2.2 * phase)
            g.stroke(Path(ellipseIn: CGRect(x: -rr, y: stemTop.y - rr, width: rr * 2, height: rr * 2)),
                     with: .color(BB.Palette.ion.opacity(0.6 * (1 - phase))), lineWidth: max(1, unit * 0.012))
        }

        // Head and side "ears".
        let earW = unit * 0.06, earH = headH * 0.34
        for side in [-1.0, 1.0] {
            let ear = CGRect(x: CGFloat(side) * (headW / 2 + earW * 0.35) - earW / 2, y: headRect.midY - earH / 2, width: earW, height: earH)
            g.fill(Path(roundedRect: ear, cornerRadius: earW / 2), with: .color(headColor.opacity(0.85)))
        }
        g.fill(Path(roundedRect: headRect, cornerRadius: corner, style: .continuous), with: .color(headColor))

        // Visor.
        let visor = headRect.insetBy(dx: headW * 0.1, dy: headH * 0.17)
        g.fill(Path(roundedRect: visor, cornerRadius: visor.height * 0.42, style: .continuous), with: .color(visorColor))

        // Eyes ---------------------------------------------------------------------
        let eyeGap = visor.width * 0.22
        let eyeW = visor.width * 0.13
        var eyeH = visor.height * 0.52 * CGFloat(1 - blink * 0.9)
        if mood == .thinking { eyeH *= 0.75 }
        if mood == .waitingApproval { eyeH = visor.height * 0.58 }
        if mood == .offline { eyeH = eyeW * 0.5 }
        let cx0 = visor.midX + CGFloat(lookX) * visor.width * 0.16
        let cy = visor.midY + CGFloat(lookY) * visor.height * 0.18
        let stroke = StrokeStyle(lineWidth: max(1.5, unit * 0.035), lineCap: .round, lineJoin: .round)
        for side in [-1.0, 1.0] {
            let cx = cx0 + CGFloat(side) * eyeGap
            switch mood {
            case .happy:
                var arc = Path()
                arc.move(to: CGPoint(x: cx - eyeW * 0.7, y: cy + eyeW * 0.25))
                arc.addQuadCurve(to: CGPoint(x: cx + eyeW * 0.7, y: cy + eyeW * 0.25), control: CGPoint(x: cx, y: cy - eyeW * 0.9))
                g.stroke(arc, with: .color(eyeColor), style: stroke)
            case .failed:
                var chevron = Path()   // > <
                let d = CGFloat(-side) * eyeW * 0.55
                chevron.move(to: CGPoint(x: cx - d, y: cy - eyeW * 0.6))
                chevron.addLine(to: CGPoint(x: cx + d, y: cy))
                chevron.addLine(to: CGPoint(x: cx - d, y: cy + eyeW * 0.6))
                g.stroke(chevron, with: .color(eyeColor), style: stroke)
            case .interrupted:
                var lid = Path()
                lid.move(to: CGPoint(x: cx - eyeW * 0.7, y: cy))
                lid.addLine(to: CGPoint(x: cx + eyeW * 0.7, y: cy))
                g.stroke(lid, with: .color(eyeColor.opacity(0.9)), style: stroke)
            default:
                let rect = CGRect(x: cx - eyeW / 2, y: cy - eyeH / 2, width: eyeW, height: max(eyeH, 1.5))
                g.fill(Path(roundedRect: rect, cornerRadius: min(eyeW, eyeH) / 2), with: .color(eyeColor))
            }
        }
        // Working: a thin scan line under the eyes.
        if mood == .working && animate {
            let p = 0.5 + 0.5 * sin(time * 2.6)
            let lineW = visor.width * 0.22
            let x = visor.minX + visor.width * 0.15 + CGFloat(p) * (visor.width * 0.7 - lineW)
            let line = CGRect(x: x, y: visor.maxY - visor.height * 0.2, width: lineW, height: max(1, unit * 0.014))
            g.fill(Path(roundedRect: line, cornerRadius: line.height / 2), with: .color(eyeColor.opacity(0.55)))
        }
    }
}

/// Mascots arranged around a title: each drifts on its own slow orbit and
/// idles on its own schedule.
struct MascotConstellation: View {
    struct Member: Identifiable {
        var id: UUID
        var style: MascotStyle
        var mood: MascotMood
    }

    var members: [Member]
    var radius: CGFloat = 120
    var mascotSize: CGFloat = 54
    var onTap: ((UUID) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced

    /// Position of member `index` of `count` at time `t` (pure, cheap to type-check).
    static func offset(index: Int, count: Int, time t: Double, radius: CGFloat) -> CGSize {
        let i = Double(index)
        let n = Double(max(count, 1))
        let base: Double = i / n * 2.0 * Double.pi - Double.pi / 2.0
        let drift: Double = sin(t * 0.25 + i) * 0.08
        let angle: Double = base + drift
        let wobble: Double = sin(t * 0.6 + i * 1.7) * 6.0
        let r = Double(radius)
        let x: Double = cos(angle) * r
        let y: Double = sin(angle) * r * 0.62 + wobble
        return CGSize(width: x, height: y)
    }

    var body: some View {
        let reduce: Bool = system || forced
        let paused: Bool = reduce || !Motion.ambientEnabled
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            constellation(time: reduce ? 0 : timeline.date.timeIntervalSinceReferenceDate)
        }
    }

    private func constellation(time: Double) -> some View {
        let indexed: [(offset: Int, element: Member)] = Array(members.enumerated())
        return ZStack {
            ForEach(indexed, id: \.element.id) { pair in
                memberView(pair.element, offset: Self.offset(index: pair.offset, count: members.count, time: time, radius: radius))
            }
        }
    }

    private func memberView(_ member: Member, offset: CGSize) -> some View {
        MascotView(style: member.style, mood: member.mood, size: mascotSize, seed: member.id)
            .offset(offset)
            .onTapGesture { onTap?(member.id) }
            .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}

extension MascotStyle {
    /// Monochrome identity: presets are told apart by shape and name, not hue.
    var color: Color { BB.Palette.textPrimary }
}

extension MascotStyle {
    /// The main Brainbox assistant.
    static let brainbox = MascotStyle(shape: .squircle, hue: 0)
}
