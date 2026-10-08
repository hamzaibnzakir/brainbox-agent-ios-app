import Foundation

// MARK: - Diff

public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case unchanged, added, removed }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
}

public struct DiffSummary: Hashable, Sendable {
    public var added: Int
    public var removed: Int
    public var isEmpty: Bool { added == 0 && removed == 0 }
}

/// Line diff via longest-common-subsequence. Good for config files; very
/// large inputs fall back to a "replace everything" diff to stay fast.
public enum LineDiff {
    public static let maxCells = 4_000_000

    public static func diff(old: String, new: String) -> [DiffLine] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var lines: [DiffLine] = []

        if a.count * b.count > maxCells {
            for (i, line) in a.enumerated() { lines.append(DiffLine(id: lines.count, kind: .removed, text: line, oldNumber: i + 1, newNumber: nil)) }
            for (j, line) in b.enumerated() { lines.append(DiffLine(id: lines.count, kind: .added, text: line, oldNumber: nil, newNumber: j + 1)) }
            return lines
        }

        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] {
                lines.append(DiffLine(id: lines.count, kind: .unchanged, text: a[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1; j += 1
            } else if j < m && (i >= n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                lines.append(DiffLine(id: lines.count, kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            } else {
                lines.append(DiffLine(id: lines.count, kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            }
        }
        return lines
    }

    public static func summary(_ lines: [DiffLine]) -> DiffSummary {
        DiffSummary(added: lines.filter { $0.kind == .added }.count, removed: lines.filter { $0.kind == .removed }.count)
    }

    /// Only changed lines plus `context` unchanged lines around them.
    public static func hunks(_ lines: [DiffLine], context: Int = 3) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != .unchanged }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(k) }
        }
        return lines.indices.filter { keep.contains($0) }.map { lines[$0] }
    }
}

// MARK: - Validation

public struct ValidationIssue: Hashable, Sendable {
    public var line: Int?
    public var message: String
    public init(line: Int?, message: String) {
        self.line = line
        self.message = message
    }
}

/// Lightweight validators so obviously broken configs are flagged before
/// they are saved to the server. Not a full YAML parser.
public enum ConfigValidator {
    public static func validate(_ text: String, language: CodeLanguage) -> [ValidationIssue] {
        switch language {
        case .json: return validateJSON(text)
        case .jsonc: return validateJSON(stripJSONComments(text))
        case .yaml: return validateYAML(text)
        default: return []
        }
    }

    static func validateJSON(_ text: String) -> [ValidationIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cleaned = removeTrailingCommas(trimmed)
        guard let data = cleaned.data(using: .utf8) else { return [ValidationIssue(line: nil, message: "Not valid UTF-8.")] }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if cleaned != trimmed { return [ValidationIssue(line: nil, message: "Trailing commas are not valid JSON.")] }
            return []
        } catch {
            return [ValidationIssue(line: nil, message: "Invalid JSON: check brackets, quotes and commas.")]
        }
    }

    static func validateYAML(_ text: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            if leading.contains("\t") {
                issues.append(ValidationIssue(line: index + 1, message: "Tabs are not allowed for indentation in YAML."))
            }
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("#") || content.isEmpty { continue }
            let quotes = content.filter { $0 == "\"" }.count
            if quotes % 2 != 0 && !content.contains("#") {
                issues.append(ValidationIssue(line: index + 1, message: "Unclosed double quote."))
            }
        }
        return issues
    }

    /// Removes // and /* */ comments outside strings.
    public static func stripJSONComments(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\" && i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func removeTrailingCommas(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\" && i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}

// MARK: - Search & replace

public enum TextSearch {
    /// Ranges (as character offsets) of case-insensitive matches.
    public static func matches(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: [.caseInsensitive], range: searchRange) {
            result.append(found)
            if found.upperBound == text.endIndex { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return result
    }

    public static func replaceAll(_ query: String, with replacement: String, in text: String) -> (text: String, count: Int) {
        let count = matches(of: query, in: text).count
        guard count > 0 else { return (text, 0) }
        return (text.replacingOccurrences(of: query, with: replacement, options: [.caseInsensitive]), count)
    }
}

// MARK: - Formatting

public enum ByteFormatter {
    public static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: value >= 100 ? "%.0f" : "%.1f", value) + " " + units[unit]
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        string(Int64(bytesPerSecond)) + "/s"
    }
}

public enum DurationFormatter {
    public static func short(_ interval: TimeInterval) -> String {
        let seconds = Int(max(interval, 0))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
