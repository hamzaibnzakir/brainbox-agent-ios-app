import BrainboxCore
import SwiftUI

/// Renders Hermes' Markdown. Text (paragraphs, headings, lists, quotes) goes into native
/// selectable text views, so you can long-press a word, drag the handles over part of a reply and
/// Copy / Look Up / Share — like Messages. Tables and code get their own views.
struct MarkdownText: View {
    var text: String
    var streaming = false
    @Environment(\.chatTextScale) private var scale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let segments = Self.segments(MarkdownParser.parse(text))
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let blocks):
                    SelectableText(attributed: RichText.build(blocks, scale: scale))
                case .code(let language, let code):
                    CodeBlock(language: language, code: code)
                case .table(let header, let alignments, let rows):
                    TableBlock(header: header, alignments: alignments, rows: rows)
                case .rule:
                    Rectangle().fill(DS.C.line).frame(height: 1)
                }
            }
        }
        .id(scheme) // re-render the UIKit text when light/dark changes
    }

    enum Segment { case text([MarkdownBlock]), code(String, String), table([String], [TableAlignment], [[String]]), rule }

    /// Consecutive text blocks share one selectable view, so a selection can span paragraphs.
    static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var out: [Segment] = []
        var run: [MarkdownBlock] = []
        func flush() { if !run.isEmpty { out.append(.text(run)); run.removeAll() } }
        for block in blocks {
            switch block {
            case .code(let language, let code, _): flush(); out.append(.code(language, code))
            case .table(let header, let alignments, let rows): flush(); out.append(.table(header, alignments, rows))
            case .rule: flush(); out.append(.rule)
            default: run.append(block)
            }
        }
        flush()
        return out
    }

    /// Inline Markdown (bold, italics, `code`, links) as a SwiftUI Text — for short labels.
    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// Builds the attributed string for a run of text blocks (UIKit fonts and colours).
enum RichText {
    static func color(_ c: Color) -> UIColor { UIColor(c) }

    static func build(_ blocks: [MarkdownBlock], scale: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = 17 * scale
        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: body * 0.6)])) }
            switch block {
            case .heading(let level, let text):
                let size = (level <= 1 ? 22 : level == 2 ? 19 : 17) * scale
                out.append(inline(text, size: size, weight: .semibold, color: color(DS.C.ink), paragraph: paragraph(spacingBefore: 4)))
            case .paragraph(let text):
                out.append(inline(text, size: body, weight: .regular, color: color(DS.C.ink), paragraph: paragraph()))
            case .bulletList(let items):
                for (j, item) in items.enumerated() {
                    if j > 0 { out.append(NSAttributedString(string: "\n")) }
                    let (marker, text) = taskMarker(item)
                    let markerColor = marker == "☑" ? color(DS.C.good) : color(DS.C.ink3)
                    out.append(NSAttributedString(string: (marker ?? "•") + "\t",
                                                  attributes: [.font: UIFont.systemFont(ofSize: body), .foregroundColor: markerColor, .paragraphStyle: listParagraph(body)]))
                    out.append(inline(text, size: body, weight: .regular, color: color(marker == "☑" ? DS.C.ink3 : DS.C.ink), paragraph: listParagraph(body),
                                      strike: marker == "☑"))
                }
            case .orderedList(let start, let items):
                for (j, item) in items.enumerated() {
                    if j > 0 { out.append(NSAttributedString(string: "\n")) }
                    out.append(NSAttributedString(string: "\(start + j).\t",
                                                  attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: body * 0.9, weight: .regular),
                                                               .foregroundColor: color(DS.C.ink3), .paragraphStyle: listParagraph(body)]))
                    out.append(inline(item, size: body, weight: .regular, color: color(DS.C.ink), paragraph: listParagraph(body)))
                }
            case .quote(let text):
                let p = paragraph(); p.firstLineHeadIndent = 14; p.headIndent = 14
                out.append(NSAttributedString(string: "▍", attributes: [.font: UIFont.systemFont(ofSize: body), .foregroundColor: color(DS.C.volt).withAlphaComponent(0.6)]))
                out.append(inline(text, size: body, weight: .regular, color: color(DS.C.ink2), paragraph: p))
            default:
                break
            }
        }
        return out
    }

    /// `[ ] task` / `[x] done` list items.
    static func taskMarker(_ item: String) -> (String?, String) {
        if item.hasPrefix("[ ] ") { return ("☐", String(item.dropFirst(4))) }
        if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { return ("☑", String(item.dropFirst(4))) }
        return (nil, item)
    }

    static func paragraph(spacingBefore: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacingBefore = spacingBefore
        return p
    }

    static func listParagraph(_ size: CGFloat) -> NSMutableParagraphStyle {
        let p = paragraph()
        let indent = size * 1.4
        p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        p.defaultTabInterval = indent
        p.headIndent = indent
        p.paragraphSpacing = 4
        return p
    }

    /// Inline Markdown → attributed text with UIKit fonts (bold, italics, `code`, ~~strike~~, links).
    static func inline(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor,
                       paragraph: NSParagraphStyle, strike: Bool = false) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = UIFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if intent.contains(.code) {
                font = UIFont.monospacedSystemFont(ofSize: size * 0.88, weight: .regular)
                attrs[.backgroundColor] = RichText.color(DS.C.raised)
            }
            if intent.contains(.emphasized), let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: d, size: font.pointSize)
            }
            if intent.contains(.strikethrough) || strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = RichText.color(DS.C.volt)
            }
            attrs[.font] = font
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

/// A non-editable, selectable UITextView sized to its content: word selection, the iOS edit menu
/// (Copy / Look Up / Translate / Share), tappable links, phone numbers and dates.
struct SelectableText: UIViewRepresentable {
    var attributed: NSAttributedString
    /// Size to the text's own width (chat bubbles) instead of filling the row.
    var hugsWidth = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = [.link, .phoneNumber]
        view.linkTextAttributes = [.foregroundColor: RichText.color(DS.C.volt), .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.attributedText != attributed { view.attributedText = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 32
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        guard hugsWidth else { return CGSize(width: width, height: ceil(fit.height)) }
        let natural = attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: min(width, ceil(natural.width) + 1), height: ceil(fit.height))
    }
}

/// A Markdown table: header row, hairline grid, zebra rows; scrolls sideways when it's wider than
/// the screen; long-press to copy it as text (tab-separated, pastes into Sheets/Excel).
struct TableBlock: View {
    var header: [String]
    var alignments: [TableAlignment]
    var rows: [[String]]
    @Environment(\.chatTextScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { i in
                        cell(header[i], column: i, bold: true)
                            .background(DS.C.raised)
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    Divider().overlay(DS.C.line).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { i in
                            cell(rows[r][i], column: i, bold: false)
                                .background(r % 2 == 1 ? DS.C.raised.opacity(0.45) : Color.clear)
                        }
                    }
                }
            }
            .background(DS.C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.C.line, lineWidth: 1))
        }
        .contextMenu {
            Button { UIPasteboard.general.string = asTSV; Haptic.tap() } label: { Label("Copy table", systemImage: "tablecells") }
            Button { UIPasteboard.general.string = asMarkdown; Haptic.tap() } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
        }
    }

    private func cell(_ text: String, column: Int, bold: Bool) -> some View {
        let align = column < alignments.count ? alignments[column] : .leading
        return MarkdownText.inline(text)
            .font(.system(size: 15 * scale, weight: bold ? .semibold : .regular))
            .foregroundStyle(bold ? DS.C.ink : DS.C.ink2)
            .multilineTextAlignment(align == .center ? .center : align == .trailing ? .trailing : .leading)
            .frame(minWidth: 64, maxWidth: 260, alignment: align == .center ? .center : align == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 9)
    }

    var asTSV: String { ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") }
    var asMarkdown: String {
        let line = { (cells: [String]) in "| " + cells.joined(separator: " | ") + " |" }
        return ([line(header), line(header.map { _ in "---" })] + rows.map(line)).joined(separator: "\n")
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
