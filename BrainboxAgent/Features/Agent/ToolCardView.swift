import SwiftUI
import BrainboxCore

/// Running → spinning arc. Success → ring closes and a check draws in
/// with a small pop (success state recipe). Failure → firm, no overshoot.
struct ToolStatusIcon: View {
    let status: ToolStatus
    var size: CGFloat = 20
    @State private var spin = false
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch status {
            case .pending, .running:
                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(BB.Palette.signal, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
                    .transition(.opacity)
            case .succeeded:
                ZStack {
                    Circle().fill(BB.Palette.success.opacity(0.16))
                    CheckmarkShape()
                        .trim(from: 0, to: drawn)
                        .stroke(BB.Palette.success, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round))
                        .padding(size * 0.27)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity).animation(Motion.pop))
                .onAppear { withAnimation(.easeOut(duration: 0.22).delay(0.06)) { drawn = 1 } }
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(BB.Palette.danger)
                    .frame(width: size, height: size)
                    .background(Circle().fill(BB.Palette.danger.opacity(0.16)))
                    .transition(.opacity)
            case .cancelled:
                Image(systemName: "stop.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(BB.Palette.textTertiary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(BB.Palette.surfaceHigh))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.standard, value: status)
        .sensoryFeedback(trigger: status) { _, new in
            switch new {
            case .succeeded: return .success
            case .failed: return .error
            default: return nil
            }
        }
        .accessibilityLabel(status.rawValue)
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

struct ToolCardView: View {
    let call: ToolCall
    @State private var expanded: Bool?
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpanded: Bool { expanded ?? (call.status == .running || call.status == .failed) }

    private var output: String {
        let live = call.liveOutput
        if !live.isEmpty { return live }
        return call.result?.output ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.standard) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: call.kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BB.Palette.signalText)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(BB.Palette.surfaceHigh))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.kind.displayName).bbLabelStyle()
                        Text(call.title)
                            .font(BB.Font.subhead)
                            .foregroundStyle(BB.Palette.textPrimary)
                            .lineLimit(1)
                            .bbShimmer(call.status == .running)
                    }
                    Spacer(minLength: 6)
                    if let duration = call.duration {
                        Text(String(format: "%.1fs", duration))
                            .font(BB.Font.monoSmall)
                            .foregroundStyle(BB.Palette.textTertiary)
                            .transition(.opacity)
                    }
                    ToolStatusIcon(status: call.status)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BB.Palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableSubtle)
            .accessibilityLabel("\(call.kind.displayName): \(call.title), \(call.status.rawValue)")
            .accessibilityHint(isExpanded ? "Collapse output" : "Expand output")

            HStack(spacing: 6) {
                Text(call.kind == .terminal ? "$" : "›").foregroundStyle(BB.Palette.signalText)
                Text(call.input).foregroundStyle(BB.Palette.terminalText).lineLimit(isExpanded ? nil : 1)
                Spacer(minLength: 0)
            }
            .font(BB.Font.monoSmall)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(BB.Palette.terminalBackground)

            if isExpanded && !output.isEmpty {
                ScrollView(.vertical) {
                    Text(output)
                        .font(BB.Font.monoSmall)
                        .foregroundStyle(call.result?.isError == true ? BB.Palette.danger : BB.Palette.terminalText.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 180)
                .background(BB.Palette.terminalBackground)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if call.status.isFinished, let code = call.result?.exitCode {
                HStack {
                    Text(call.status == .succeeded ? "✓ Completed" : (call.status == .cancelled ? "■ Cancelled" : "✕ Failed"))
                    Spacer()
                    Text("exit \(code)")
                }
                .font(BB.Font.label)
                .foregroundStyle(call.status == .succeeded ? BB.Palette.success : (call.status == .cancelled ? BB.Palette.textTertiary : BB.Palette.danger))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(BB.Palette.terminalBackground)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous))
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous)
                .strokeBorder(call.status == .running ? BB.Palette.signal.opacity(glow ? 0.55 : 0.15) : BB.Palette.stroke, lineWidth: 1)
        )
        .shadow(color: call.status == .running ? BB.Palette.signalGlow.opacity(glow ? 0.6 : 0.1) : .clear, radius: 10)
        .animation(Motion.standard, value: call.status)
        .animation(Motion.standard, value: isExpanded)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}
