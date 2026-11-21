import Foundation

/// Block-level markdown used by chat messages. Inline formatting
/// (bold, italics, `code`, links) is left in the block text and rendered
/// by the UI via `AttributedString(markdown:)`.
///
/// The parser is streaming-tolerant: an unterminated ``` fence produces a
/// code block marked `isOpen`, so code renders correctly while it streams.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, code: String, isOpen: Bool)
    case bulletList([String])
    case orderedList(start: Int, items: [String])
    case quote(String)
    case rule
    /// A GitHub-style pipe table. Every row has exactly `header.count` cells.
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
}

public enum TableAlignment: String, Hashable, Sendable { case leading, center, trailing }

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var orderedStart = 1
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bulletList(bullets)); bullets.removeAll() }
            if !ordered.isEmpty { blocks.append(.orderedList(start: orderedStart, items: ordered)); ordered.removeAll() }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote.removeAll() }
        }
        func flushAll() { flushParagraph(); flushLists() }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        closed = true
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, code: codeLines.joined(separator: "\n"), isOpen: !closed))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushAll()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let item = bulletItem(trimmed) {
                flushParagraph()
                if !ordered.isEmpty || !quote.isEmpty { flushLists() }
                bullets.append(item)
                index += 1
                continue
            }

            if let item = orderedItem(trimmed) {
                flushParagraph()
                if !bullets.isEmpty || !quote.isEmpty { flushLists() }
                if ordered.isEmpty { orderedStart = item.number }
                ordered.append(item.text)
                index += 1
                continue
            }

            // Pipe table: a header row followed by a delimiter row (| --- | :---: |).
            if trimmed.contains("|"), index + 1 < lines.count,
               let alignments = tableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                let header = tableCells(trimmed)
                if header.count >= 1, alignments.count >= 1 {
                    flushAll()
                    let width = max(header.count, alignments.count)
                    func pad(_ cells: [String]) -> [String] {
                        let cut = Array(cells.prefix(width))
                        return cut + Array(repeating: "", count: width - cut.count)
                    }
                    var rows: [[String]] = []
                    index += 2
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|") else { break }
                        rows.append(pad(tableCells(row)))
                        index += 1
                    }
                    let aligned = Array(alignments.prefix(width)) + Array(repeating: TableAlignment.leading, count: max(0, width - alignments.count))
                    blocks.append(.table(header: pad(header), alignments: aligned, rows: rows))
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                if !bullets.isEmpty || !ordered.isEmpty { flushLists() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            // Continuation of a list item (indented line)
            if line.hasPrefix("  ") && (!bullets.isEmpty || !ordered.isEmpty) {
                if !bullets.isEmpty { bullets[bullets.count - 1] += " " + trimmed }
                else { ordered[ordered.count - 1] += " " + trimmed }
                index += 1
                continue
            }

            flushLists()
            paragraph.append(trimmed)
            index += 1
        }
        flushAll()
        return blocks
    }

    /// Cells of a `| a | b |` row (outer pipes optional, `\|` stays a literal pipe).
    static func tableCells(_ line: String) -> [String] {
        var row = line
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for c in row {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "`" { inCode.toggle() }
            if c == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(c)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// `| --- | :---: | ---: |` → alignments; nil when the line isn't a delimiter row.
    static func tableDelimiter(_ line: String) -> [TableAlignment]? {
        guard line.contains("-") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty, line.contains("|") || cells.count == 1 else { return nil }
        var out: [TableAlignment] = []
        for cell in cells {
            let c = cell.replacingOccurrences(of: " ", with: "")
            guard c.count >= 1, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            out.append(left && right ? .center : right ? .trailing : .leading)
        }
        return out
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for c in line { if c == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        var digits = ""
        var rest = Substring(line)
        while let c = rest.first, c.isNumber { digits.append(c); rest = rest.dropFirst() }
        guard !digits.isEmpty, digits.count <= 4, let number = Int(digits) else { return nil }
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    /// Extracts every fenced code block — used by "copy code" actions.
    public static func codeBlocks(in text: String) -> [String] {
        parse(text).compactMap {
            if case .code(_, let code, _) = $0 { return code }
            return nil
        }
    }
}
