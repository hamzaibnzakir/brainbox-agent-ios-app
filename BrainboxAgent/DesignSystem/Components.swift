import SwiftUI
import UIKit
import UniformTypeIdentifiers
import BrainboxCore

// MARK: - Card

struct BBCard<Content: View>: View {
    var padding: CGFloat = BB.Space.l
    var radius: CGFloat = BB.Radius.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(BB.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(BB.Palette.stroke, lineWidth: 1)
            )
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).bbLabelStyle()
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(BB.Font.subhead)
                    .foregroundStyle(BB.Palette.signalText)
                    .buttonStyle(.pressableSubtle)
            }
        }
        .padding(.horizontal, BB.Space.xs)
    }
}

// MARK: - Status

enum StatusTone {
    case live, busy, warning, danger, idle

    var color: Color {
        switch self {
        case .live: return BB.Palette.success
        case .busy: return BB.Palette.signal
        case .warning: return BB.Palette.warning
        case .danger: return BB.Palette.danger
        case .idle: return BB.Palette.textTertiary
        }
    }
}

extension ConnectionState {
    var tone: StatusTone {
        switch self {
        case .connected: return .live
        case .connecting: return .busy
        case .reconnecting: return .warning
        case .failed: return .danger
        case .disconnected: return .idle
        }
    }
}

extension AgentStatus {
    var tone: StatusTone {
        switch self {
        case .ready: return .live
        case .thinking, .streaming, .runningTool: return .busy
        case .offline: return .idle
        case .unavailable: return .danger
        }
    }
}

struct StatusDot: View {
    var tone: StatusTone
    var pulsing: Bool = true
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing && Motion.ambient(reduceMotion: reduceMotion) && tone != .idle {
                Circle()
                    .stroke(tone.color.opacity(0.6), lineWidth: 1)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.8)
            }
            Circle().fill(tone.color)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard pulsing, Motion.ambient(reduceMotion: reduceMotion) else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
        .animation(Motion.standard, value: tone.color)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    var tone: StatusTone
    var text: String

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: tone, size: 7)
            Text(text)
                .font(BB.Font.label)
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(BB.Palette.textSecondary)
                .contentTransition(.interpolate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(BB.Palette.surfaceHigh))
        .overlay(Capsule().strokeBorder(BB.Palette.stroke))
        .animation(Motion.standard, value: text)
        .accessibilityElement(children: .combine)
    }
}

/// A small mono badge, e.g. "MOCK" or "PENDING".
struct Badge: View {
    var text: String
    var color: Color = BB.Palette.warning

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(color.opacity(0.3)))
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(BB.Palette.onSignal)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(BB.Font.headline)
            }
            .foregroundStyle(BB.Palette.onSignal)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.signal))
            .shadow(color: BB.Palette.signalGlow, radius: 14, y: 4)
        }
        .buttonStyle(.pressable)
        .disabled(isLoading)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(BB.Font.subhead)
            }
            .foregroundStyle(role == .destructive ? BB.Palette.danger : BB.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surfaceHigh))
            .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
        }
        .buttonStyle(.pressable)
    }
}

struct IconButton: View {
    let systemImage: String
    var label: String
    var tint: Color = BB.Palette.textPrimary
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(BB.Palette.surfaceHigh))
                .overlay(Circle().strokeBorder(BB.Palette.stroke))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

struct Chip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(BB.Font.subhead)
            }
            .foregroundStyle(isSelected ? BB.Palette.onSignal : BB.Palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(isSelected ? BB.Palette.signal : BB.Palette.surfaceHigh))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : BB.Palette.stroke))
        }
        .buttonStyle(.pressable)
        .animation(Motion.snappy, value: isSelected)
    }
}

// MARK: - Feedback

struct ErrorBanner: View {
    let error: AgentError
    var retry: (() -> Void)? = nil
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: error == .offline ? "wifi.slash" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(error == .offline ? BB.Palette.warning : BB.Palette.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                Text(error.message).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let retry {
                Button("Retry", action: retry)
                    .font(BB.Font.subhead)
                    .foregroundStyle(BB.Palette.signalText)
                    .buttonStyle(.pressableSubtle)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(BB.Palette.textTertiary)
                }
                .buttonStyle(.pressableSubtle)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surfaceHigh))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder((error == .offline ? BB.Palette.warning : BB.Palette.danger).opacity(0.35)))
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(BB.Palette.textTertiary)
                .symbolEffect(.pulse, options: .repeating.speed(0.4), isActive: Motion.ambientEnabled)
            Text(title).font(BB.Font.headline).foregroundStyle(BB.Palette.textPrimary)
            Text(message).font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary).multilineTextAlignment(.center)
        }
        .padding(BB.Space.xxl)
        .frame(maxWidth: .infinity)
        .bbEntrance()
    }
}

/// Transient confirmation ("Copied", "Saved").
struct ToastView: View {
    let text: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(BB.Palette.signal)
            Text(text).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(BB.Palette.strokeStrong))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

@MainActor
@Observable
final class ToastCenter {
    var message: String?
    private var task: Task<Void, Never>?

    func show(_ text: String) {
        task?.cancel()
        withAnimation(Motion.pop) { message = text }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.exit) { self?.message = nil }
        }
    }
}

// MARK: - Metrics

struct MetricRing: View {
    var value: Double
    var label: String
    var detail: String
    var tint: Color = BB.Palette.signal
    @State private var shown: Double = 0

    private var color: Color {
        if value >= 0.92 { return BB.Palette.danger }
        if value >= 0.78 { return BB.Palette.warning }
        return tint
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(BB.Palette.surfaceHigh, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.35), radius: 6)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(BB.Palette.textPrimary)
                    .contentTransition(.numericText(value: value))
                    .monospacedDigit()
            }
            .frame(width: 74, height: 74)
            VStack(spacing: 2) {
                Text(label).bbLabelStyle(BB.Palette.textSecondary)
                Text(detail).font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(Motion.gentle.delay(0.1)) { shown = value } }
        .onChange(of: value) { _, newValue in withAnimation(Motion.standard) { shown = newValue } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int(value * 100)) percent, \(detail)")
    }
}

struct Sparkline: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let maxValue = values.max(), maxValue > 0 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: CGFloat(index) * step, y: rect.maxY - CGFloat(value / maxValue) * rect.height * 0.9)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: - Settings row

struct SettingsRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = BB.Palette.textPrimary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BB.Palette.surfaceHigh))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BB.Font.callout).foregroundStyle(BB.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Screen chrome

struct ScreenBackground: View {
    var body: some View {
        ZStack {
            BB.Palette.background
            // Subtle top glow: the ambient "power on" light of the brand.
            RadialGradient(colors: [BB.Palette.signal.opacity(0.07), .clear], center: .top, startRadius: 0, endRadius: 420)
                .offset(y: -120)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func bbScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(ScreenBackground())
            .toolbarBackground(BB.Palette.background.opacity(0.9), for: .navigationBar)
    }
}

// MARK: - Clipboard

/// Copies text without syncing it to other devices (no Universal Clipboard)
/// and lets it expire, since copied output can contain server details.
enum Clipboard {
    static let lifetime: TimeInterval = 600

    static func copy(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)]
        )
    }
}
