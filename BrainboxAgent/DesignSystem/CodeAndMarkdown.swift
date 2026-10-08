import SwiftUI
import UIKit
import BrainboxCore

enum Highlight {
    /// Syntax-highlighted AttributedString for SwiftUI `Text`.
    static func attributed(_ code: String, language: CodeLanguage, font: Font = BB.Font.mono) -> AttributedString {
        var result = AttributedString()
        for token in SyntaxHighlighter.tokenize(code, language: language) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = BB.Syntax.color(for: token.kind)
            piece.font = font
            if token.kind == .heading || token.kind == .emphasis { piece.font = font.bold() }
            if token.kind == .comment { piece.font = font.italic() }
            result.append(piece)
        }
        return result
    }

    /// UIKit version used by the editor's text storage.
    static func apply(to storage: NSTextStorage, language: CodeLanguage, font: UIFont, traits: UITraitCollection) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: UIColor(BB.Syntax.color(for: .plain)).resolvedColor(with: traits)], range: full)
        var location = 0
        for token in SyntaxHighlighter.tokenize(text, language: language) {
            let length = (token.text as NSString).length
            if token.kind != .plain && location + length <= full.length {
                let color = UIColor(BB.Syntax.color(for: token.kind)).resolvedColor(with: traits)
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: location, length: length))
                if token.kind == .comment {
                    storage.addAttribute(.font, value: font.withTraits(.traitItalic), range: NSRange(location: location, length: length))
                } else if token.kind == .heading || token.kind == .emphasis {
                    storage.addAttribute(.font, value: font.withTraits(.traitBold), range: NSRange(location: location, length: length))
                }
            }
            location += length
        }
        storage.endEditing()
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let code: String
    let language: String
    var isStreaming = false
    var onCopy: ((String) -> Void)? = nil
    @State private var copied = false

    private var codeLanguage: CodeLanguage { CodeLanguage.fromFence(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).bbLabelStyle()
                if isStreaming {
                    ProgressView().controlSize(.mini).tint(BB.Palette.signal)
                }
                Spacer()
                Button {
                    Clipboard.copy(code)
                    onCopy?(code)
                    withAnimation(Motion.pop) { copied = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        withAnimation(Motion.fade) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(BB.Font.caption.weight(.medium))
                        .foregroundStyle(copied ? BB.Palette.signalText : BB.Palette.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.pressableSubtle)
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(BB.Palette.surfaceHigh.opacity(0.6))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(Highlight.attributed(code, language: codeLanguage))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.codeBackground))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
        .clipShape(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous))
    }
}

// MARK: - Markdown

struct MarkdownView: View {
    let text: String
    var isStreaming = false
    var onCopy: ((String) -> Void)? = nil

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isLast: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isLast: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? BB.Font.title : (level == 2 ? BB.Font.headline.weight(.bold) : BB.Font.headline))
                .foregroundStyle(BB.Palette.textPrimary)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(BB.Font.body)
                .foregroundStyle(BB.Palette.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code, let isOpen):
            CodeBlockView(code: code, language: language, isStreaming: isOpen && isStreaming && isLast, onCopy: onCopy)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(BB.Palette.signal).frame(width: 5, height: 5).offset(y: -2)
                        Text(Self.inline(item)).font(BB.Font.body).foregroundStyle(BB.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(start + offset).").font(BB.Font.mono).foregroundStyle(BB.Palette.signalText)
                        Text(Self.inline(item)).font(BB.Font.body).foregroundStyle(BB.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(BB.Palette.signal.opacity(0.6)).frame(width: 3)
                Text(Self.inline(text)).font(BB.Font.callout.italic()).foregroundStyle(BB.Palette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(BB.Palette.stroke).frame(height: 1).padding(.vertical, 4)
        }
    }

    /// Inline markdown (bold, italics, code, links) with brand styling.
    static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = BB.Font.mono
                attributed[run.range].foregroundColor = BB.Palette.signalText
                attributed[run.range].backgroundColor = BB.Palette.surfaceHigh
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = BB.Palette.ion
                attributed[run.range].underlineStyle = Text.LineStyle.single
            }
        }
        return attributed
    }
}
