import Foundation

public enum CodeLanguage: String, CaseIterable, Sendable, Hashable, Identifiable {
    case yaml, json, jsonc, markdown, python, shell, javascript, swift, plainText

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yaml: return "YAML"
        case .json: return "JSON"
        case .jsonc: return "JSONC"
        case .markdown: return "Markdown"
        case .python: return "Python"
        case .shell: return "Shell"
        case .javascript: return "JavaScript"
        case .swift: return "Swift"
        case .plainText: return "Plain text"
        }
    }

    public static func detect(fileName: String) -> CodeLanguage {
        let lower = fileName.lowercased()
        if lower == "dockerfile" || lower.hasPrefix(".env") || lower == ".bashrc" || lower == ".zshrc" { return .shell }
        guard let dot = lower.lastIndex(of: ".") else { return .plainText }
        switch String(lower[lower.index(after: dot)...]) {
        case "yml", "yaml": return .yaml
        case "json": return .json
        case "jsonc", "json5": return .jsonc
        case "md", "markdown": return .markdown
        case "py": return .python
        case "sh", "bash", "zsh", "env": return .shell
        case "js", "mjs", "cjs", "ts": return .javascript
        case "swift": return .swift
        default: return .plainText
        }
    }

    /// Maps a markdown fence info string (```yaml) to a language.
    public static func fromFence(_ info: String) -> CodeLanguage {
        switch info.lowercased().trimmingCharacters(in: .whitespaces) {
        case "yaml", "yml": return .yaml
        case "json": return .json
        case "jsonc", "json5": return .jsonc
        case "md", "markdown": return .markdown
        case "py", "python", "python3": return .python
        case "sh", "bash", "shell", "zsh", "console": return .shell
        case "js", "javascript", "ts", "typescript": return .javascript
        case "swift": return .swift
        default: return .plainText
        }
    }
}

public enum SyntaxTokenKind: String, Sendable, Hashable, CaseIterable {
    case plain, keyword, string, number, comment, key, punctuation, variable, heading, emphasis, inlineCode, builtin
}

public struct SyntaxToken: Hashable, Sendable {
    public var text: String
    public var kind: SyntaxTokenKind
    public init(_ text: String, _ kind: SyntaxTokenKind) {
        self.text = text
        self.kind = kind
    }
}

/// A small, dependency-free lexer good enough for config and script
/// files. It always returns tokens whose texts concatenate back to the
/// exact input, so it can drive both read-only views and the editor.
public enum SyntaxHighlighter {
    public static let maxHighlightedLength = 60_000

    public static func tokenize(_ text: String, language: CodeLanguage) -> [SyntaxToken] {
        guard language != .plainText, text.count <= maxHighlightedLength else { return [SyntaxToken(text, .plain)] }
        if language == .markdown { return merge(markdown(text)) }
        return merge(code(text, language: language))
    }

    // MARK: Code

    private struct Rules {
        var lineComments: [String] = []
        var blockComment: (String, String)?
        var quotes: Set<Character> = ["\"", "'"]
        var keywords: Set<String> = []
        var builtins: Set<String> = []
        var variables = false
    }

    private static func rules(for language: CodeLanguage) -> Rules {
        switch language {
        case .yaml:
            return Rules(lineComments: ["#"], keywords: ["true", "false", "null", "yes", "no", "on", "off", "~"])
        case .json:
            return Rules(quotes: ["\""], keywords: ["true", "false", "null"])
        case .jsonc:
            return Rules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: ["true", "false", "null"])
        case .python:
            return Rules(lineComments: ["#"], keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "and", "or", "not", "is", "None", "True", "False", "lambda", "yield", "async", "await", "global", "nonlocal"], builtins: ["print", "len", "range", "dict", "list", "str", "int", "float", "open", "round", "all", "any", "self"])
        case .shell:
            return Rules(lineComments: ["#"], keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "set", "exit"], builtins: ["echo", "cd", "sudo", "git", "npm", "systemctl", "curl", "cat", "grep", "ls"], variables: true)
        case .javascript:
            return Rules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "import", "from", "export", "default", "async", "await", "new", "class", "true", "false", "null", "undefined", "try", "catch"], builtins: ["console", "require", "module", "process"])
        case .swift:
            return Rules(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], keywords: ["let", "var", "func", "return", "if", "else", "guard", "struct", "class", "enum", "case", "switch", "import", "public", "private", "async", "await", "try", "throws", "true", "false", "nil", "self", "for", "in", "while", "protocol", "extension", "static"])
        case .markdown, .plainText:
            return Rules()
        }
    }

    private static func code(_ text: String, language: CodeLanguage) -> [SyntaxToken] {
        let r = rules(for: language)
        let chars = Array(text)
        var tokens: [SyntaxToken] = []
        var i = 0
        var lineStart = true

        func starts(with s: String, at index: Int) -> Bool {
            let sc = Array(s)
            guard index + sc.count <= chars.count else { return false }
            for k in 0..<sc.count where chars[index + k] != sc[k] { return false }
            return true
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\n" {
                tokens.append(SyntaxToken("\n", .plain))
                i += 1
                lineStart = true
                continue
            }

            // Block comments
            if let block = r.blockComment, starts(with: block.0, at: i) {
                let close = block.1
                var j = i + block.0.count
                while j < chars.count && !starts(with: close, at: j) { j += 1 }
                j = min(j + close.count, chars.count)
                tokens.append(SyntaxToken(String(chars[i..<j]), .comment))
                i = j
                lineStart = false
                continue
            }

            // Line comments (for shell/yaml/python a # must start a word)
            if let marker = r.lineComments.first(where: { starts(with: $0, at: i) }) {
                let isWordStart = i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" || chars[i - 1] == "\n"
                if marker != "#" || isWordStart {
                    var j = i
                    while j < chars.count && chars[j] != "\n" { j += 1 }
                    tokens.append(SyntaxToken(String(chars[i..<j]), .comment))
                    i = j
                    continue
                }
            }

            // YAML keys: `key:` at the start of a line (after indentation / "- ")
            if language == .yaml && lineStart {
                var j = i
                while j < chars.count && (chars[j] == " " || chars[j] == "\t") { j += 1 }
                if j + 1 < chars.count && chars[j] == "-" && chars[j + 1] == " " { j += 2 }
                var k = j
                while k < chars.count && (chars[k].isLetter || chars[k].isNumber || chars[k] == "_" || chars[k] == "-" || chars[k] == ".") { k += 1 }
                if k > j && k < chars.count && chars[k] == ":" {
                    if j > i { tokens.append(SyntaxToken(String(chars[i..<j]), .punctuation)) }
                    tokens.append(SyntaxToken(String(chars[j..<k]), .key))
                    tokens.append(SyntaxToken(":", .punctuation))
                    i = k + 1
                    lineStart = false
                    continue
                }
            }

            if c == " " || c == "\t" {
                var j = i
                while j < chars.count && (chars[j] == " " || chars[j] == "\t") { j += 1 }
                tokens.append(SyntaxToken(String(chars[i..<j]), .plain))
                i = j
                continue
            }
            lineStart = false

            // Strings
            if r.quotes.contains(c) {
                var j = i + 1
                while j < chars.count && chars[j] != c && chars[j] != "\n" {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                j = min(j + 1, chars.count)
                let literal = String(chars[i..<j])
                // JSON object keys: a string followed by ':'
                var k = j
                while k < chars.count && chars[k] == " " { k += 1 }
                let isKey = (language == .json || language == .jsonc) && k < chars.count && chars[k] == ":"
                tokens.append(SyntaxToken(literal, isKey ? .key : .string))
                i = j
                continue
            }

            // Shell variables
            if r.variables && c == "$" {
                var j = i + 1
                if j < chars.count && chars[j] == "{" {
                    while j < chars.count && chars[j] != "}" && chars[j] != "\n" { j += 1 }
                    j = min(j + 1, chars.count)
                } else {
                    while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "@" || chars[j] == "?") { j += 1 }
                }
                tokens.append(SyntaxToken(String(chars[i..<j]), .variable))
                i = j
                continue
            }

            // Numbers
            if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber && (i == 0 || !chars[i - 1].isLetter)) {
                var j = i + 1
                while j < chars.count && (chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "e" || chars[j] == "x") { j += 1 }
                let isStandalone = j >= chars.count || !(chars[j].isLetter)
                if isStandalone {
                    tokens.append(SyntaxToken(String(chars[i..<j]), .number))
                    i = j
                    continue
                }
            }

            // Words
            if c.isLetter || c == "_" || c == "~" {
                var j = i + 1
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                let kind: SyntaxTokenKind = r.keywords.contains(word) ? .keyword : (r.builtins.contains(word) ? .builtin : .plain)
                tokens.append(SyntaxToken(word, kind))
                i = j
                continue
            }

            let isPunctuation = "{}[]():,;=<>|&!+*/%-.".contains(c)
            tokens.append(SyntaxToken(String(c), isPunctuation ? .punctuation : .plain))
            i += 1
        }
        return tokens
    }

    // MARK: Markdown

    private static func markdown(_ text: String) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var inFence = false
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                tokens.append(SyntaxToken(line, .inlineCode))
                inFence.toggle()
            } else if inFence {
                tokens.append(SyntaxToken(line, .inlineCode))
            } else if trimmed.hasPrefix("#") {
                tokens.append(SyntaxToken(line, .heading))
            } else if trimmed.hasPrefix(">") {
                tokens.append(SyntaxToken(line, .comment))
            } else {
                tokens.append(contentsOf: markdownInline(line))
            }
            if index < lines.count - 1 { tokens.append(SyntaxToken("\n", .plain)) }
        }
        return tokens
    }

    private static func markdownInline(_ line: String) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let chars = Array(line)
        var i = 0
        var plain = ""
        func flush() {
            if !plain.isEmpty { tokens.append(SyntaxToken(plain, .plain)); plain = "" }
        }
        // List markers
        var lead = 0
        while lead < chars.count && chars[lead] == " " { lead += 1 }
        if lead + 1 < chars.count && "-*+".contains(chars[lead]) && chars[lead + 1] == " " {
            tokens.append(SyntaxToken(String(chars[0...lead]), .punctuation))
            i = lead + 1
        }
        while i < chars.count {
            if chars[i] == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                flush()
                tokens.append(SyntaxToken(String(chars[i...end]), .inlineCode))
                i = end + 1
                continue
            }
            if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count && !(chars[j] == "*" && chars[j + 1] == "*") { j += 1 }
                if j + 1 < chars.count {
                    flush()
                    tokens.append(SyntaxToken(String(chars[i...(j + 1)]), .emphasis))
                    i = j + 2
                    continue
                }
            }
            plain.append(chars[i])
            i += 1
        }
        flush()
        return tokens
    }

    /// Joins adjacent tokens of the same kind to keep attributed strings small.
    private static func merge(_ tokens: [SyntaxToken]) -> [SyntaxToken] {
        var result: [SyntaxToken] = []
        result.reserveCapacity(tokens.count)
        for token in tokens where !token.text.isEmpty {
            if let last = result.last, last.kind == token.kind {
                result[result.count - 1].text += token.text
            } else {
                result.append(token)
            }
        }
        return result
    }
}
