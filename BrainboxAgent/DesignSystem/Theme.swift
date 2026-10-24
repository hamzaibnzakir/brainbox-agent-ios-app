import SwiftUI
import UIKit
import BrainboxCore

/// Brainbox visual identity: black, white and tuned greys; strong type, thin
/// dividers, restrained surfaces. Colour is reserved for meaning (status) and
/// is never the only signal — every status also has a label or symbol.
/// Dark is a true deep black; light is a clean paper white.
enum BB {
    // MARK: Colour tokens

    enum Palette {
        static let background = Color.adaptive(light: 0xFAFAFA, dark: 0x000000)
        static let backgroundRaised = Color.adaptive(light: 0xFFFFFF, dark: 0x0A0A0A)
        static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x111111)
        static let surfaceHigh = Color.adaptive(light: 0xF0F0F0, dark: 0x1A1A1A)
        static let surfaceSunken = Color.adaptive(light: 0xF4F4F4, dark: 0x070707)
        static let stroke = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
        static let strokeStrong = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.18)

        static let textPrimary = Color.adaptive(light: 0x0A0A0A, dark: 0xF5F5F5)
        static let textSecondary = Color.adaptive(light: 0x5C5C5C, dark: 0x9A9A9A)
        static let textTertiary = Color.adaptive(light: 0x8E8E8E, dark: 0x5E5E5E)

        /// The primary action / live-agent ink: black on light, white on dark.
        static let signal = Color.adaptive(light: 0x0A0A0A, dark: 0xF5F5F5)
        static let signalText = Color.adaptive(light: 0x0A0A0A, dark: 0xF5F5F5)
        static let onSignal = Color.adaptive(light: 0xFFFFFF, dark: 0x000000)
        static let signalGlow = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.14)

        /// "Aura" for live states: a quiet grey sweep, not a rainbow.
        static let auraOrange = Color.adaptive(light: 0x0A0A0A, dark: 0xFFFFFF)
        static let auraMagenta = Color.adaptive(light: 0x6E6E6E, dark: 0x8A8A8A)
        static let auraViolet = Color.adaptive(light: 0xBDBDBD, dark: 0x3A3A3A)
        static var auraGradient: LinearGradient {
            LinearGradient(colors: [auraOrange, auraMagenta, auraViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        static var auraAngular: AngularGradient {
            AngularGradient(colors: [auraOrange, auraViolet, auraMagenta, auraOrange], center: .center)
        }

        /// The one restrained accent: "the agent is working / needs you" blue.
        static let ion = Color.adaptive(light: 0x2F5BEA, dark: 0x7EA2FF)
        static let success = Color.adaptive(light: 0x15803D, dark: 0x4ADE80)
        static let warning = Color.adaptive(light: 0xB45309, dark: 0xFBBF24)
        static let danger = Color.adaptive(light: 0xC81E2E, dark: 0xFF6B76)

        static let userBubble = Color.adaptive(light: 0x0A0A0A, dark: 0x1F1F1F)
        static let onUserBubble = Color.adaptive(light: 0xFAFAFA, dark: 0xF5F5F5)

        static let codeBackground = Color.adaptive(light: 0xF4F4F4, dark: 0x0B0B0B)
        static let terminalBackground = Color(hex: 0x000000)
        static let terminalText = Color(hex: 0xE6E6E6)
    }

    enum Syntax {
        static func color(for kind: SyntaxTokenKind) -> Color {
            switch kind {
            case .keyword: return Color.adaptive(light: 0x8A3FFC, dark: 0xC4A7FF)
            case .string: return Color.adaptive(light: 0x2E7D32, dark: 0xB5E58A)
            case .number: return Color.adaptive(light: 0xB45309, dark: 0xF7B267)
            case .comment: return Color.adaptive(light: 0x8F959D, dark: 0x5F656E)
            case .key: return Color.adaptive(light: 0x2563EB, dark: 0x8CB4FF)
            case .punctuation: return Color.adaptive(light: 0x6B7280, dark: 0x7D848D)
            case .variable: return Color.adaptive(light: 0xC2410C, dark: 0xFF9E7A)
            case .heading: return Palette.textPrimary
            case .emphasis: return Palette.textPrimary
            case .inlineCode: return Color.adaptive(light: 0x2E7D32, dark: 0xB5E58A)
            case .builtin: return Color.adaptive(light: 0x0E7490, dark: 0x7EE0E8)
            case .plain: return Palette.textPrimary
            }
        }
    }

    // MARK: Spacing / radius

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        static let xxxl: CGFloat = 40
        static let gutter: CGFloat = 16
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 18
        static let xl: CGFloat = 26
        static let pill: CGFloat = 999
    }

    // MARK: Typography

    enum Font {
        static let display = SwiftUI.Font.system(size: 32, weight: .semibold, design: .default)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 16, weight: .regular)
        static let callout = SwiftUI.Font.system(size: 15, weight: .regular)
        static let subhead = SwiftUI.Font.system(size: 14, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 12, weight: .regular)
        /// Technical label: monospaced, small caps feel.
        static let label = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
        static let mono = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 12, weight: .regular, design: .monospaced)
        static let metric = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            let alpha = traits.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}

extension View {
    /// Monospaced uppercase "technical" label style.
    func bbLabelStyle(_ color: Color = BB.Palette.textTertiary) -> some View {
        self.font(BB.Font.label)
            .textCase(.uppercase)
            .tracking(1.1)
            .foregroundStyle(color)
    }
}
