import BrainboxCore
import SwiftUI

/// Renders Hermes' Markdown: headings, lists, quotes, rules, inline styles, and
/// code blocks with syntax colour and a copy button.
struct MarkdownText: View {
    var text: String
    var streaming = false
    @Environment(\.chatTextScale) private var scale

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(.system(size: (level <= 1 ? 22 : level == 2 ? 19 : 17) * scale, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.C.ink)
                .padding(.top, 4)
        case .paragraph(let text):
            Self.inline(text).font(.system(size: 17 * scale)).foregroundStyle(DS.C.ink).lineSpacing(3)
        case .code(let language, let code, _):
            CodeBlock(language: language, code: code)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(DS.C.ink3).frame(width: 5, height: 5).offset(y: -2)
                        Self.inline(item).font(.system(size: 17 * scale)).foregroundStyle(DS.C.ink)
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + index).").font(.system(size: 15 * scale).monospacedDigit()).foregroundStyle(DS.C.ink3)
                        Self.inline(item).font(.system(size: 17 * scale)).foregroundStyle(DS.C.ink)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(DS.C.volt.opacity(0.5)).frame(width: 3)
                Self.inline(text).font(.system(size: 17 * scale)).foregroundStyle(DS.C.ink2)
            }
        case .rule:
            Rectangle().fill(DS.C.line).frame(height: 1)
        }
    }

    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

struct CodeBlock: View {
    var language: String
    var code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(DS.F.captionStrong).foregroundStyle(DS.C.ink3)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Haptic.tap()
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(DS.F.captionStrong).foregroundStyle(DS.C.ink2)
                }
            }
            .padding(.horizontal, DS.S.m)
            .padding(.vertical, DS.S.s)
            Divider().overlay(DS.C.line)
            ScrollView(.horizontal, showsIndicators: false) {
                highlighted.font(DS.F.monoSmall).padding(DS.S.m).fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(DS.C.raised, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.line, lineWidth: 1))
    }

    private var highlighted: Text {
        let lang = CodeLanguage.fromFence(language)
        guard code.count < SyntaxHighlighter.maxHighlightedLength else { return Text(code).foregroundColor(DS.C.ink) }
        return SyntaxHighlighter.tokenize(code, language: lang).reduce(Text("")) { result, token in
            result + Text(token.text).foregroundColor(Self.color(token.kind))
        }
    }

    static func color(_ kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .keyword: return Color.dynamic(light: 0xA626A4, dark: 0xC678DD)
        case .string: return Color.dynamic(light: 0x50A14F, dark: 0x98C379)
        case .number: return Color.dynamic(light: 0x986801, dark: 0xD19A66)
        case .comment: return DS.C.ink3
        case .key, .variable: return Color.dynamic(light: 0xE45649, dark: 0xE06C75)
        case .builtin: return Color.dynamic(light: 0x4078F2, dark: 0x61AFEF)
        case .punctuation: return DS.C.ink2
        case .heading, .emphasis, .inlineCode, .plain: return DS.C.ink
        }
    }
}

private struct ChatTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var chatTextScale: CGFloat {
        get { self[ChatTextScaleKey.self] }
        set { self[ChatTextScaleKey.self] = newValue }
    }
}
