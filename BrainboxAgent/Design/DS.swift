import SwiftUI
import UIKit

// Brainbox design system.
//
// Rules (from the mobile-app-ui-design skill):
// * one type family (SF Pro, rounded for display), 4 sizes, 2 weights;
// * 60 / 30 / 10 colour: warm neutral base, ink, one accent ("volt");
// * every space is on the 8-point grid;
// * soft shadows tinted to the surface, never pure black;
// * primary actions sit in the thumb zone.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum DS {
    enum C {
        // 60 — neutral base
        static let canvas = Color.dynamic(light: 0xF4F3EF, dark: 0x0C0D10)
        static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x16171C)
        static let raised = Color.dynamic(light: 0xFBFAF7, dark: 0x1D1E24)
        static let line = Color.dynamic(light: 0xE6E3DC, dark: 0x2A2B33)
        // 30 — ink
        static let ink = Color.dynamic(light: 0x111216, dark: 0xF3F3F5)
        static let ink2 = Color.dynamic(light: 0x111216, dark: 0xF3F3F5).opacity(0.72)
        static let ink3 = Color.dynamic(light: 0x111216, dark: 0xF3F3F5).opacity(0.5)
        // 10 — accent
        static let volt = Color.dynamic(light: 0x5B4DF5, dark: 0x8C82FF)
        static let voltSoft = Color.dynamic(light: 0x5B4DF5, dark: 0x8C82FF).opacity(0.1)
        // meaning
        static let good = Color.dynamic(light: 0x16A34A, dark: 0x4ADE80)
        static let warn = Color.dynamic(light: 0xD97706, dark: 0xFBBF24)
        static let bad = Color.dynamic(light: 0xDC2626, dark: 0xF87171)
        static let userBubble = Color.dynamic(light: 0x111216, dark: 0xF3F3F5)
        static let userText = Color.dynamic(light: 0xFFFFFF, dark: 0x111216)
        static let shadow = Color.dynamic(light: 0x3B3420, dark: 0x000000)

        /// Category tints for the hub (soft backgrounds).
        static let tints: [Color] = [
            .dynamic(light: 0xEDE9FF, dark: 0x25223F), .dynamic(light: 0xE3F4EA, dark: 0x1B2E24),
            .dynamic(light: 0xFFF1DB, dark: 0x332A1A), .dynamic(light: 0xE4F0FF, dark: 0x1B2638),
            .dynamic(light: 0xFFE6E8, dark: 0x351E22), .dynamic(light: 0xEFEFEA, dark: 0x24252B),
        ]
        static let tintInks: [Color] = [
            .dynamic(light: 0x4C3FE0, dark: 0xB3ABFF), .dynamic(light: 0x15803D, dark: 0x6EE7A0),
            .dynamic(light: 0xB45309, dark: 0xFCD38A), .dynamic(light: 0x1D4ED8, dark: 0x93BBFF),
            .dynamic(light: 0xBE123C, dark: 0xFDA4AF), .dynamic(light: 0x3F3F46, dark: 0xD4D4D8),
        ]
    }

    /// The four sizes. Weight is regular or semibold only.
    enum F {
        static let title = Font.system(size: 28, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 17, weight: .regular)
        static let bodyStrong = Font.system(size: 17, weight: .semibold)
        static let small = Font.system(size: 15, weight: .regular)
        static let smallStrong = Font.system(size: 15, weight: .semibold)
        static let caption = Font.system(size: 12, weight: .regular)
        static let captionStrong = Font.system(size: 12, weight: .semibold)
        static let mono = Font.system(size: 15, weight: .regular, design: .monospaced)
        static let monoSmall = Font.system(size: 12, weight: .regular, design: .monospaced)
        static let number = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// 8-point grid.
    enum S {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum R {
        static let card: CGFloat = 24
        static let control: CGFloat = 16
        static let pill: CGFloat = 999
    }
}

// MARK: - Haptics

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Surfaces

struct CardStyle: ViewModifier {
    var padding: CGFloat = DS.S.l
    var tint: Color = DS.C.surface
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(tint, in: RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).stroke(DS.C.line.opacity(0.6), lineWidth: 0.5))
            .shadow(color: DS.C.shadow.opacity(0.06), radius: 16, x: 0, y: 8)
    }
}

extension View {
    func card(padding: CGFloat = DS.S.l, tint: Color = DS.C.surface) -> some View {
        modifier(CardStyle(padding: padding, tint: tint))
    }

    func screenBackground() -> some View {
        background(DS.C.canvas.ignoresSafeArea())
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = DS.C.volt
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.F.bodyStrong)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: DS.R.control, style: .continuous)
                    .fill(tint.opacity(enabled ? 1 : 0.4))
                    .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1).blendMode(.overlay))
            )
            .shadow(color: tint.opacity(enabled ? 0.28 : 0), radius: 16, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = DS.C.volt
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.F.smallStrong)
            .foregroundStyle(tint)
            .padding(.horizontal, DS.S.m)
            .frame(minHeight: 44)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.F.small)
            .foregroundStyle(selected ? DS.C.userText : DS.C.ink)
            .padding(.horizontal, DS.S.m)
            .frame(minHeight: 36)
            .background(selected ? DS.C.ink : DS.C.surface, in: Capsule())
            .overlay(Capsule().stroke(DS.C.line, lineWidth: selected ? 0 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Pieces

struct IconTile: View {
    var symbol: String
    var index: Int
    var size: CGFloat = 48
    var body: some View {
        let i = abs(index) % DS.C.tints.count
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(DS.C.tintInks[i])
            .frame(width: size, height: size)
            .background(DS.C.tints[i], in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.4), lineWidth: 4).scaleEffect(on ? 1.8 : 1).opacity(on ? 0 : 1))
            .onAppear { if pulsing { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } } }
    }
}

struct SectionTitle: View {
    var text: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(text).font(DS.F.captionStrong).foregroundStyle(DS.C.ink3).textCase(.uppercase).kerning(0.6)
            Spacer()
            if let trailing { Text(trailing).font(DS.F.caption).foregroundStyle(DS.C.ink3) }
        }
        .padding(.horizontal, DS.S.xs)
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var action: (label: String, run: () -> Void)?
    var body: some View {
        VStack(spacing: DS.S.m) {
            IconTile(symbol: symbol, index: 0, size: 64)
            Text(title).font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
            Text(message).font(DS.F.small).foregroundStyle(DS.C.ink2).multilineTextAlignment(.center)
            if let action {
                Button(action.label, action: action.run).buttonStyle(SecondaryButtonStyle())
            }
        }
        .frame(maxWidth: 320)
        .padding(DS.S.xl)
        .frame(maxWidth: .infinity)
    }
}

struct Pill: View {
    var text: String
    var color: Color = DS.C.ink2
    var symbol: String?
    var body: some View {
        HStack(spacing: DS.S.xs) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(DS.F.captionStrong).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, DS.S.s)
        .frame(height: 24)
        .background(color.opacity(0.1), in: Capsule())
    }
}

/// A row in a settings-style list.
struct RowLabel: View {
    var title: String
    var subtitle: String?
    var symbol: String
    var index: Int
    var body: some View {
        HStack(spacing: DS.S.m) {
            IconTile(symbol: symbol, index: index, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.F.body).foregroundStyle(DS.C.ink)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(DS.F.caption).foregroundStyle(DS.C.ink3).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Error banner with retry.
struct ErrorBanner: View {
    var message: String
    var retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: DS.S.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.C.bad)
            Text(message).font(DS.F.small).foregroundStyle(DS.C.ink).frame(maxWidth: .infinity, alignment: .leading)
            if let retry { Button("Retry", action: retry).font(DS.F.smallStrong).foregroundStyle(DS.C.volt) }
        }
        .padding(DS.S.m)
        .background(DS.C.bad.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
    }
}

// MARK: - Mascot support (the Brainbox bot drawing in Mascot.swift)

enum BB {
    enum Palette {
        static let ion = DS.C.volt
        static let danger = DS.C.bad
        static let success = DS.C.good
        static let textPrimary = DS.C.ink
    }
}

enum Motion {
    static var ambientEnabled = true
    static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.68)
}

private struct ForceReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var bbForceReduceMotion: Bool {
        get { self[ForceReduceMotionKey.self] }
        set { self[ForceReduceMotionKey.self] = newValue }
    }
}

// MARK: - Formatting

enum Fmt {
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    static func duration(_ s: Double) -> String {
        s < 1 ? String(format: "%.0f ms", s * 1000) : s < 60 ? String(format: "%.1f s", s) : String(format: "%d min %d s", Int(s) / 60, Int(s) % 60)
    }
}
