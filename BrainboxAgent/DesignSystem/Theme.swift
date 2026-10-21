import SwiftUI
import UIKit
import BrainboxCore

/// Brainbox visual identity: graphite surfaces, one phosphor-lime signal
/// colour, monospaced technical labels. Dark-first, fully adaptive.
enum BB {
    // MARK: Colour tokens

    enum Palette {
        // Near-black OLED canvas (dark) / warm paper (light).
        static let background = Color.adaptive(light: 0xF5F4F0, dark: 0x050505)
        static let backgroundRaised = Color.adaptive(light: 0xFAF9F6, dark: 0x0A0A0B)
        static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x141414)
        static let surfaceHigh = Color.adaptive(light: 0xEDECE7, dark: 0x1C1C1E)
        static let surfaceSunken = Color.adaptive(light: 0xE7E6E0, dark: 0x0B0B0C)
        static let stroke = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.07)
        static let strokeStrong = Color.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.14)

        static let textPrimary = Color.adaptive(light: 0x0D0E10, dark: 0xEDEDED)
        static let textSecondary = Color.adaptive(light: 0x5A5D63, dark: 0x8A8A8A)
        static let textTertiary = Color.adaptive(light: 0x8F9298, dark: 0x5C5C60)

        /// The aura: one warm sunset accent, reserved for live AI states
        /// (thinking, streaming, running, connected) and the primary action.
        static let signal = Color(hex: 0xFF6A3D)
        static let signalText = Color.adaptive(light: 0xC2410C, dark: 0xFF8A63)
        static let onSignal = Color(hex: 0x0B0604)
        static let signalGlow = Color(hex: 0xFF6A3D).opacity(0.38)

        /// Aura gradient stops: orange → magenta → violet.
        static let auraOrange = Color(hex: 0xFF6A3D)
        static let auraMagenta = Color(hex: 0xFF3D8B)
        static let auraViolet = Color(hex: 0x8B5CF6)
        static var auraGradient: LinearGradient {
            LinearGradient(colors: [auraOrange, auraMagenta, auraViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        static var auraAngular: AngularGradient {
            AngularGradient(colors: [auraOrange, auraMagenta, auraViolet, auraOrange], center: .center)
        }

        static let ion = Color.adaptive(light: 0x4C5BDB, dark: 0x9AA4FF)
        static let success = Color.adaptive(light: 0x16A34A, dark: 0x4ADE80)
        static let warning = Color.adaptive(light: 0xB45309, dark: 0xFBBF24)
        static let danger = Color.adaptive(light: 0xD92D3F, dark: 0xFF5D6C)

        static let userBubble = Color.adaptive(light: 0x14151A, dark: 0x1F1F22)
        static let onUserBubble = Color.adaptive(light: 0xF3F3F0, dark: 0xEDEDED)

        static let codeBackground = Color.adaptive(light: 0xF0EFEA, dark: 0x0B0B0C)
        static let terminalBackground = Color(hex: 0x050505)
        static let terminalText = Color(hex: 0xD9DED3)
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
