import SwiftUI
import UIKit
import BrainboxCore

/// Bridges SwiftUI toolbar actions (undo, redo, find) to the UITextView.
@MainActor
@Observable
final class EditorController {
    var canUndo = false
    var canRedo = false
    var matchCount = 0
    var currentMatch = 0
    @ObservationIgnored weak var textView: CodeTextView?

    func undo() { textView?.undoManager?.undo(); refresh() }
    func redo() { textView?.undoManager?.redo(); refresh() }

    func refresh() {
        canUndo = textView?.undoManager?.canUndo ?? false
        canRedo = textView?.undoManager?.canRedo ?? false
    }

    /// Selects the next match after the cursor (wrapping around).
    func findNext(_ query: String) {
        guard let textView, !query.isEmpty else { matchCount = 0; currentMatch = 0; return }
        let text = textView.text ?? ""
        let ranges = TextSearch.matches(of: query, in: text).map { NSRange($0, in: text) }
        matchCount = ranges.count
        guard !ranges.isEmpty else { currentMatch = 0; return }
        let cursor = textView.selectedRange.location + textView.selectedRange.length
        let index = ranges.firstIndex { $0.location >= cursor } ?? 0
        currentMatch = index + 1
        textView.selectedRange = ranges[index]
        textView.scrollRangeToVisible(ranges[index])
        textView.flashSelection()
    }

    /// Replaces every match through UITextView so the change is undoable.
    @discardableResult
    func replaceAll(_ query: String, with replacement: String) -> Int {
        guard let textView, !query.isEmpty else { return 0 }
        let text = textView.text ?? ""
        let ranges = TextSearch.matches(of: query, in: text).map { NSRange($0, in: text) }
        guard !ranges.isEmpty else { return 0 }
        textView.undoManager?.beginUndoGrouping()
        for range in ranges.reversed() {
            if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
               let end = textView.position(from: start, offset: range.length),
               let textRange = textView.textRange(from: start, to: end) {
                textView.replace(textRange, withText: replacement)
            }
        }
        textView.undoManager?.endUndoGrouping()
        matchCount = 0
        refresh()
        return ranges.count
    }
}

/// TextKit 1 text view with a line-number gutter.
final class CodeTextView: UITextView {
    static let gutterWidth: CGFloat = 44
    var gutterBackground = UIColor.clear
    var gutterTextColor = UIColor.secondaryLabel

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        contentMode = .redraw
        textContainerInset = UIEdgeInsets(top: 12, left: Self.gutterWidth + 6, bottom: 120, right: 12)
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardDismissMode = .interactive
        alwaysBounceVertical = true
        backgroundColor = .clear
    }

    func flashSelection() {
        UIView.animate(withDuration: 0.12, animations: { self.alpha = 0.85 }) { _ in
            UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        }
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(gutterBackground.cgColor)
        context.fill(CGRect(x: 0, y: bounds.minY, width: Self.gutterWidth, height: bounds.height))

        let text = (self.text ?? "") as NSString
        let font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: gutterTextColor]
        let visible = CGRect(x: 0, y: bounds.minY - textContainerInset.top, width: bounds.width, height: bounds.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let firstChar = layoutManager.characterIndexForGlyph(at: glyphRange.location)

        // Line number of the first visible character.
        var line = 1
        if firstChar > 0 {
            let prefix = text.substring(to: min(firstChar, text.length))
            line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphs, _ in
            let charRange = self.layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            let startsParagraph = charRange.location == 0 || text.character(at: charRange.location - 1) == 10
            if startsParagraph {
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attributes)
                let y = fragmentRect.minY + self.textContainerInset.top + (fragmentRect.height - size.height) / 2
                label.draw(at: CGPoint(x: Self.gutterWidth - size.width - 8, y: y), withAttributes: attributes)
                line += 1
            }
        }
        // Trailing empty line after a final newline.
        if text.length == 0 || text.hasSuffix("\n") {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                let total = text.length == 0 ? 1 : text.components(separatedBy: "\n").count
                let label = "\(total)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: Self.gutterWidth - size.width - 8, y: extra.minY + textContainerInset.top), withAttributes: attributes)
            }
        }
    }
}

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var isEditable: Bool
    var controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CodeTextView {
        let view = CodeTextView()
        view.delegate = context.coordinator
        view.isEditable = isEditable
        view.text = text
        controller.textView = view
        context.coordinator.applyTheme(to: view)
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: CodeTextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEditable
        controller.textView = view
        if view.text != text && !context.coordinator.isEditing {
            view.text = text
            context.coordinator.highlight(view)
            view.setNeedsDisplay()
        }
        context.coordinator.applyTheme(to: view)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        var isEditing = false
        private var pending: DispatchWorkItem?
        private var lastStyle: UIUserInterfaceStyle?
        let font = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

        init(_ parent: CodeEditor) { self.parent = parent }

        func applyTheme(to view: CodeTextView) {
            let style = view.traitCollection.userInterfaceStyle
            guard style != lastStyle else { return }
            lastStyle = style
            view.gutterBackground = UIColor(BB.Palette.surfaceSunken).resolvedColor(with: view.traitCollection)
            view.gutterTextColor = UIColor(BB.Palette.textTertiary).resolvedColor(with: view.traitCollection)
            view.tintColor = UIColor(BB.Palette.signalText)
            view.typingAttributes = [.font: font, .foregroundColor: UIColor(BB.Palette.textPrimary).resolvedColor(with: view.traitCollection)]
            highlight(view)
            view.setNeedsDisplay()
        }

        func highlight(_ view: CodeTextView) {
            Highlight.apply(to: view.textStorage, language: parent.language, font: font, traits: view.traitCollection)
            view.typingAttributes = [.font: font, .foregroundColor: UIColor(BB.Palette.textPrimary).resolvedColor(with: view.traitCollection)]
        }

        func textViewDidBeginEditing(_ textView: UITextView) { isEditing = true }
        func textViewDidEndEditing(_ textView: UITextView) { isEditing = false }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? CodeTextView else { return }
            parent.text = view.text
            parent.controller.refresh()
            view.setNeedsDisplay()
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                MainActor.assumeIsolated {
                    let selection = view.selectedRange
                    self.highlight(view)
                    view.selectedRange = selection
                }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scrollView.setNeedsDisplay()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Keep indentation on newline — small thing, big quality-of-life win.
            guard text == "\n" else { return true }
            let ns = (textView.text ?? "") as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: lineRange)
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            var extra = ""
            if parent.language == .python || parent.language == .yaml, line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") {
                extra = parent.language == .python ? "    " : "  "
            }
            textView.insertText("\n" + indent + extra)
            return false
        }
    }
}
