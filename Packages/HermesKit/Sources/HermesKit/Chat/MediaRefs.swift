import Foundation

/// A file or link the agent handed over in a reply: `MEDIA:/path`, a Markdown image
/// `![alt](path-or-url)`, or a bare absolute path to a media/document file.
public struct MediaRef: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case image, video, audio, document }
    /// Absolute path on the server, or an http(s) URL.
    public var location: String
    public var kind: Kind
    public var id: String { location }

    public var isRemoteURL: Bool { location.hasPrefix("http://") || location.hasPrefix("https://") }
    public var filename: String {
        let trimmed = location.split(separator: "?").first.map(String.init) ?? location
        return (trimmed as NSString).lastPathComponent
    }

    public init(location: String, kind: Kind) {
        self.location = location
        self.kind = kind
    }

    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"]
    static let videoExt: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static let audioExt: Set<String> = ["mp3", "m4a", "wav", "ogg", "opus", "aac", "flac"]
    static let documentExt: Set<String> = ["pdf", "zip", "csv", "xlsx", "xls", "docx", "doc", "pptx", "txt", "md", "json", "html", "svg", "tar", "gz"]

    public static func kind(for location: String) -> Kind? {
        let path = location.split(separator: "?").first.map(String.init) ?? location
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExt.contains(ext) { return .image }
        if videoExt.contains(ext) { return .video }
        if audioExt.contains(ext) { return .audio }
        if documentExt.contains(ext) { return .document }
        return nil
    }

    /// Splits a reply into the text to show and the files to render.
    /// `MEDIA:` lines are removed from the text; image Markdown becomes a rendered image;
    /// bare paths stay in the text (they're readable) and also get a preview.
    public static func extract(from text: String) -> (text: String, refs: [MediaRef]) {
        var refs: [MediaRef] = []
        var seen = Set<String>()
        func add(_ raw: String, fallback: Kind = .document) {
            var loc = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t`'\"<>()[],;"))
            while let last = loc.last, ".:!?".contains(last) { loc.removeLast() }
            guard loc.hasPrefix("/") || loc.hasPrefix("~/") || loc.hasPrefix("http://") || loc.hasPrefix("https://") else { return }
            guard !seen.contains(loc) else { return }
            let kind = Self.kind(for: loc) ?? (loc.hasPrefix("/") || loc.hasPrefix("~/") ? fallback : nil)
            guard let kind else { return }
            seen.insert(loc)
            refs.append(MediaRef(location: loc, kind: kind))
        }

        var kept: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); kept.append(line); continue }
            if inFence { kept.append(line); continue }
            if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") { continue }  // e.g. [[audio_as_voice]]
            if let range = line.range(of: "MEDIA:") {
                let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let path = rest.split(separator: " ").first.map(String.init) ?? rest
                add(path)
                let before = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { kept.append(String(before)) }
                continue
            }
            var output = line
            // ![alt](target) -> rendered image; keep the alt text.
            while let open = output.range(of: "!["), let close = output.range(of: "](", range: open.upperBound..<output.endIndex),
                  let end = output.range(of: ")", range: close.upperBound..<output.endIndex) {
                let target = String(output[close.upperBound..<end.lowerBound])
                let alt = String(output[open.upperBound..<close.lowerBound])
                add(target, fallback: .image)
                output.replaceSubrange(open.lowerBound..<end.upperBound, with: alt)
            }
            // Bare absolute paths with a known extension (outside inline code is fine too).
            for token in output.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let t = String(token)
                var clean = t.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"<>()[],;"))
                while let last = clean.last, ".:!?".contains(last) { clean.removeLast() }
                if (clean.hasPrefix("/") || clean.hasPrefix("~/")) && clean.count > 2, Self.kind(for: clean) != nil {
                    add(clean)
                }
            }
            kept.append(output)
        }
        let cleaned = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, refs)
    }
}
