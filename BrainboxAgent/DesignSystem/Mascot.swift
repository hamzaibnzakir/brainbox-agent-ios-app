import SwiftUI
import BrainboxCore

/// Original geometric teammate mascots. Every teammate has its own shape and
/// hue; idle micro-animations (blink, glance, tilt, squish) run on
/// randomised, desynchronised schedules seeded by the teammate id, so a
/// group of mascots never moves in lockstep. Moods come from real state
/// (`MascotMood.derive`), never from timers.
struct MascotView: View {
    var style: MascotStyle
    var mood: MascotMood = .idle
    var size: CGFloat = 56
    /// Seed for the idle schedule (use the teammate id).
    var seed: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    /// Small hop when this mascot becomes the selected one.
    var hopTrigger: Int = 0

    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced
    @State private var hop: CGFloat = 0

    var body: some View {
        let reduce = system || forced
        let animate = Motion.ambientEnabled && !reduce && mood != .offline
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !animate)) { timeline in
            let t = animate ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, canvasSize in
                MascotRenderer(style: style, mood: mood, seed: seed, time: t, animate: animate)
                    .draw(in: &context, size: canvasSize)
            }
        }
        .frame(width: size, height: size)
        .offset(y: -hop * size * 0.18)
        .onChange(of: hopTrigger) { _, _ in
            guard !reduce else { return }
            withAnimation(Motion.bouncy) { hop = 1 }
            withAnimation(Motion.bouncy.delay(0.16)) { hop = 0 }
        }
        .animation(Motion.smooth, value: mood)
        .accessibilityElement()
        .accessibilityLabel("\(style.shape.title) mascot, \(mood.label)")
    }
}

/// Pure drawing so the Motion Lab and widgets share it.
struct MascotRenderer {
    var style: MascotStyle
    var mood: MascotMood
    var seed: UUID
    var time: TimeInterval
    var animate: Bool

    private var base: Color {
        switch mood {
        case .failed, .offline: return Color(hue: style.hue, saturation: 0.15, brightness: 0.55)
        default: return Color(hue: style.hue, saturation: 0.72, brightness: 0.98)
        }
    }

    private var shade: Color { Color(hue: style.hue, saturation: 0.8, brightness: mood == .failed ? 0.35 : 0.62) }

    /// Deterministic pseudo-random in 0…1 for (seed, slot).
    private func rand(_ slot: Int) -> Double {
        // FNV-1a over the seed bytes (Hasher is randomly seeded per launch).
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) }
        var x: UInt64 = 1469598103934665603
        for b in bytes { x = (x ^ UInt64(b)) &* 1099511628211 }
        x = (x ^ UInt64(slot &* 2654435761)) &* 1099511628211
        return Double(x % 10_000) / 10_000
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let unit = min(w, h)
        // Idle schedule ---------------------------------------------------
        let blinkPeriod = 3.2 + rand(1) * 2.6
        let blinkPhase = (time + rand(2) * blinkPeriod).truncatingRemainder(dividingBy: blinkPeriod)
        let blink: Double = animate && blinkPhase < 0.14 ? sin(blinkPhase / 0.14 * .pi) : 0
        let glancePeriod = 5.5 + rand(3) * 4
        let glancePhase = (time + rand(4) * glancePeriod).truncatingRemainder(dividingBy: glancePeriod) / glancePeriod
        var glance: Double = 0
        if animate && glancePhase > 0.55 && glancePhase < 0.85 {
            glance = sin((glancePhase - 0.55) / 0.3 * .pi) * (rand(5) > 0.5 ? 1 : -1)
        }
        let breath = animate ? sin(time * (1.6 + rand(6) * 0.6) + rand(7) * 6) : 0
        var squish = 1 + 0.025 * breath
        var tilt = animate ? sin(time * 0.7 + rand(8) * 6) * 3 : 0
        var bob: Double = 0
        var lookUp: Double = 0

        switch mood {
        case .thinking:
            bob = animate ? sin(time * 2.2) * 0.03 : 0
            lookUp = 0.8
        case .working:
            squish = 1 + 0.04 * (animate ? sin(time * 6) : 0)
            tilt = animate ? sin(time * 3) * 2 : 0
        case .waitingApproval:
            bob = animate ? abs(sin(time * 3.2)) * -0.05 : 0
            glance = 0
        case .happy:
            squish = 1 + 0.08 * (animate ? max(0, sin(time * 8)) : 0)
        case .failed:
            tilt = -8
            bob = 0.04
        case .offline:
            tilt = 0
        case .idle:
            break
        }

        // Glow for live AI states.
        if mood == .thinking || mood == .working || mood == .waitingApproval {
            let glowColor: Color = mood == .waitingApproval ? BB.Palette.warning : BB.Palette.signal
            let pulse = animate ? (0.5 + 0.5 * sin(time * 2.4)) : 0.6
            let glowRect = CGRect(x: w * 0.06, y: h * 0.06, width: w * 0.88, height: h * 0.88)
            context.fill(Ellipse().path(in: glowRect), with: .radialGradient(
                Gradient(colors: [glowColor.opacity(0.32 * pulse), .clear]),
                center: CGPoint(x: w / 2, y: h / 2), startRadius: unit * 0.2, endRadius: unit * 0.5))
        }

        // Body ---------------------------------------------------------------
        var body = context
        body.translateBy(x: w / 2, y: h / 2 + CGFloat(bob) * unit)
        body.rotate(by: .degrees(tilt))
        body.scaleBy(x: CGFloat(1 / squish), y: CGFloat(squish))
        let r = unit * 0.36
        let path = shapePath(radius: r)
        body.fill(path, with: .linearGradient(Gradient(colors: [base, shade]),
                                              startPoint: CGPoint(x: -r, y: -r), endPoint: CGPoint(x: r, y: r)))
        body.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: max(1, unit * 0.012))

        // Working: rotating aura ring.
        if mood == .working {
            let angle = animate ? time * 2.4 : 0
            var ring = body
            ring.rotate(by: .radians(angle))
            let ringRect = CGRect(x: -r * 1.28, y: -r * 1.28, width: r * 2.56, height: r * 2.56)
            ring.stroke(Path(ellipseIn: ringRect).trimmedPath(from: 0, to: 0.62),
                        with: .linearGradient(Gradient(colors: [BB.Palette.auraOrange, BB.Palette.auraMagenta, .clear]),
                                              startPoint: CGPoint(x: -r, y: 0), endPoint: CGPoint(x: r, y: 0)),
                        style: StrokeStyle(lineWidth: max(1.5, unit * 0.035), lineCap: .round))
        }

        // Face -------------------------------------------------------------------
        let eyeY = -r * 0.12 - CGFloat(lookUp) * r * 0.16
        let eyeDX = r * 0.36
        let pupilShift = CGFloat(glance) * r * 0.12
        let eyeW = r * 0.24
        var eyeH = r * 0.3 * CGFloat(1 - blink * 0.92)
        if mood == .happy { eyeH = r * 0.08 }
        if mood == .working { eyeH = r * 0.18 }
        for side in [-1.0, 1.0] {
            let cx = CGFloat(side) * eyeDX + pupilShift
            let eyeRect = CGRect(x: cx - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: max(eyeH, 1))
            if mood == .happy {
                // ^ ^ happy eyes
                var arc = Path()
                arc.move(to: CGPoint(x: cx - eyeW / 2, y: eyeY + eyeW * 0.15))
                arc.addQuadCurve(to: CGPoint(x: cx + eyeW / 2, y: eyeY + eyeW * 0.15), control: CGPoint(x: cx, y: eyeY - eyeW * 0.55))
                body.stroke(arc, with: .color(Color(white: 0.06)), style: StrokeStyle(lineWidth: max(1.5, unit * 0.04), lineCap: .round))
            } else if mood == .failed {
                var x = Path()
                x.move(to: CGPoint(x: cx - eyeW * 0.4, y: eyeY - eyeW * 0.4)); x.addLine(to: CGPoint(x: cx + eyeW * 0.4, y: eyeY + eyeW * 0.4))
                x.move(to: CGPoint(x: cx + eyeW * 0.4, y: eyeY - eyeW * 0.4)); x.addLine(to: CGPoint(x: cx - eyeW * 0.4, y: eyeY + eyeW * 0.4))
                body.stroke(x, with: .color(Color(white: 0.08)), style: StrokeStyle(lineWidth: max(1.5, unit * 0.035), lineCap: .round))
            } else {
                body.fill(Path(roundedRect: eyeRect, cornerRadius: min(eyeW, eyeH) / 2), with: .color(Color(white: 0.06)))
                // Catch-light.
                if eyeH > r * 0.12 {
                    let light = CGRect(x: eyeRect.midX + eyeW * 0.08, y: eyeRect.minY + eyeH * 0.18, width: eyeW * 0.28, height: eyeW * 0.28)
                    body.fill(Path(ellipseIn: light), with: .color(.white.opacity(0.85)))
                }
            }
        }
        // Mouth: tiny line, curved by mood.
        var mouth = Path()
        let my = r * 0.32
        let curve: CGFloat
        switch mood {
        case .happy: curve = r * 0.16
        case .failed, .offline: curve = -r * 0.1
        case .waitingApproval: curve = 0
        default: curve = r * 0.06
        }
        mouth.move(to: CGPoint(x: -r * 0.16, y: my))
        mouth.addQuadCurve(to: CGPoint(x: r * 0.16, y: my), control: CGPoint(x: 0, y: my + curve))
        body.stroke(mouth, with: .color(Color(white: 0.08).opacity(0.85)), style: StrokeStyle(lineWidth: max(1.2, unit * 0.028), lineCap: .round))

        // Waiting for approval: a small amber "!" badge.
        if mood == .waitingApproval {
            let badge = CGRect(x: r * 0.62, y: -r * 1.05, width: r * 0.5, height: r * 0.5)
            body.fill(Path(ellipseIn: badge), with: .color(BB.Palette.warning))
            body.draw(Text("!").font(.system(size: r * 0.36, weight: .black)).foregroundColor(.black), at: CGPoint(x: badge.midX, y: badge.midY))
        }
    }

    private func shapePath(radius r: CGFloat) -> Path {
        switch style.shape {
        case .orb:
            return Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        case .squircle:
            return Path(roundedRect: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), cornerRadius: r * 0.55, style: .continuous)
        case .pill:
            return Path(roundedRect: CGRect(x: -r * 1.12, y: -r * 0.82, width: r * 2.24, height: r * 1.64), cornerRadius: r * 0.82, style: .continuous)
        case .triangle:
            return polygon(sides: 3, radius: r * 1.18, rotation: -.pi / 2, rounding: r * 0.18).offsetBy(dx: 0, dy: r * 0.16)
        case .hexagon:
            return polygon(sides: 6, radius: r * 1.06, rotation: 0, rounding: r * 0.14)
        case .diamond:
            return polygon(sides: 4, radius: r * 1.18, rotation: -.pi / 2, rounding: r * 0.16)
        }
    }

    private func polygon(sides: Int, radius: CGFloat, rotation: Double, rounding: CGFloat) -> Path {
        let points = (0..<sides).map { i -> CGPoint in
            let a = rotation + Double(i) / Double(sides) * 2 * .pi
            return CGPoint(x: radius * CGFloat(cos(a)), y: radius * CGFloat(sin(a)))
        }
        var path = Path()
        for i in 0..<sides {
            let p0 = points[(i + sides - 1) % sides], p1 = points[i], p2 = points[(i + 1) % sides]
            let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y), v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
            let l1 = max(hypot(v1.x, v1.y), 0.001), l2 = max(hypot(v2.x, v2.y), 0.001)
            let a = CGPoint(x: p1.x + v1.x / l1 * rounding, y: p1.y + v1.y / l1 * rounding)
            let b = CGPoint(x: p1.x + v2.x / l2 * rounding, y: p1.y + v2.y / l2 * rounding)
            if i == 0 { path.move(to: a) } else { path.addLine(to: a) }
            path.addQuadCurve(to: b, control: p1)
        }
        path.closeSubpath()
        return path
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
    var color: Color { Color(hue: hue, saturation: 0.72, brightness: 0.98) }
}
