import SwiftUI
import UIKit
import BrainboxCore

struct FileEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: FileEntry

    @State private var original: FileContent?
    @State private var text = ""
    @State private var error: AgentError?
    @State private var loading = true
    @State private var saving = false
    @State private var showDiff = false
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var replaceText = ""
    @State private var preview = false
    @State private var confirmDiscard = false
    @State private var issues: [ValidationIssue] = []
    @State private var controller = EditorController()
    @State private var savedPulse = 0

    private var isDirty: Bool { original.map { $0.text != text } ?? false }
    private var language: CodeLanguage { entry.language }
    private var isSensitive: Bool {
        [.yaml, .json, .jsonc, .shell].contains(language) || entry.path.hasPrefix("/etc") || entry.name.hasPrefix(".env")
    }

    var body: some View {
        VStack(spacing: 0) {
            if showFind { findBar.transition(.move(edge: .top).combined(with: .opacity)) }
            if let error {
                ErrorBanner(error: error, retry: conflictRetry(for: error), dismiss: { self.error = nil })
                    .padding(.horizontal, BB.Space.gutter)
                    .padding(.vertical, 8)
                    .transition(.bbRise)
            }
            ZStack {
                if loading {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<8, id: \.self) { i in SkeletonBlock(height: 12, width: CGFloat([220, 160, 260, 120, 200, 90, 240, 180][i])) }
                        Spacer()
                    }
                    .padding(BB.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if preview && language == .markdown {
                    ScrollView { MarkdownView(text: text).padding(BB.Space.l) }
                        .transition(.opacity)
                } else {
                    CodeEditor(text: $text, language: language, isEditable: !entry.isReadOnly, controller: controller)
                        .transition(.opacity)
                }
            }
            .animation(Motion.standard, value: preview)
            statusBar
        }
        .animation(Motion.standard, value: showFind)
        .animation(Motion.standard, value: error)
        .background(BB.Palette.background.ignoresSafeArea())
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar { toolbar }
        .task { await load() }
        .task(id: text) {
            // Debounced validation (JSON/YAML).
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { issues = ConfigValidator.validate(text, language: language) }
        }
        .sheet(isPresented: $showDiff) {
            if let original {
                DiffSheet(path: entry.path, old: original.text, new: text, issues: issues, isSensitive: isSensitive, biometry: model.gate.biometryName) {
                    showDiff = false
                    Task { await save() }
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(BB.Palette.backgroundRaised)
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isDirty {
            ToolbarItem(placement: .topBarLeading) {
                Button { confirmDiscard = true } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !entry.isReadOnly {
                Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!controller.canUndo).accessibilityLabel("Undo")
                Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!controller.canRedo).accessibilityLabel("Redo")
            }
            Menu {
                Button { showFind.toggle() } label: { Label(showFind ? "Hide find" : "Find & replace", systemImage: "magnifyingglass") }
                if language == .markdown {
                    Button { preview.toggle() } label: { Label(preview ? "Edit" : "Preview", systemImage: preview ? "pencil" : "eye") }
                }
                Button {
                    UIPasteboard.general.string = text
                    model.toasts.show("Copied")
                } label: { Label("Copy all", systemImage: "doc.on.doc") }
                Button { Task { await load() } } label: { Label("Reload from server", systemImage: "arrow.clockwise") }
            } label: { Image(systemName: "ellipsis.circle") }
            if !entry.isReadOnly {
                Button {
                    showDiff = true
                } label: {
                    if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                }
                .disabled(!isDirty || saving)
                .accessibilityIdentifier("editor.save")
            }
        }
    }

    private var findBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(BB.Palette.textTertiary)
                TextField("Find", text: $findQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { controller.findNext(findQuery) }
                if controller.matchCount > 0 {
                    Text("\(controller.currentMatch)/\(controller.matchCount)").font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textSecondary)
                }
                Button { controller.findNext(findQuery) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Next match")
            }
            if !entry.isReadOnly {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(BB.Palette.textTertiary)
                    TextField("Replace with", text: $replaceText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("All") {
                        let count = controller.replaceAll(findQuery, with: replaceText)
                        model.toasts.show(count == 0 ? "No matches" : "Replaced \(count)")
                    }
                    .font(BB.Font.subhead)
                    .disabled(findQuery.isEmpty)
                }
            }
        }
        .font(BB.Font.mono)
        .padding(12)
        .background(BB.Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(BB.Palette.stroke).frame(height: 1) }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(language.displayName).bbLabelStyle()
            if entry.isReadOnly { Badge(text: "Read-only", color: BB.Palette.textTertiary) }
            if let issue = issues.first {
                Label(issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.warning)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if [.json, .jsonc, .yaml].contains(language) && !loading {
                Label("Valid", systemImage: "checkmark.seal").font(BB.Font.caption).foregroundStyle(BB.Palette.success)
                    .transition(.opacity)
            }
            Spacer()
            if isDirty {
                HStack(spacing: 5) {
                    Circle().fill(BB.Palette.warning).frame(width: 6, height: 6)
                    Text("Unsaved").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                }
                .transition(.scale.combined(with: .opacity))
            } else if savedPulse > 0 {
                Label("Saved", systemImage: "checkmark").font(BB.Font.caption).foregroundStyle(BB.Palette.success)
                    .transition(.scale.combined(with: .opacity))
            }
            Text("\(text.components(separatedBy: "\n").count) lines").font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary)
        }
        .padding(.horizontal, BB.Space.l)
        .padding(.vertical, 8)
        .background(BB.Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(BB.Palette.stroke).frame(height: 1) }
        .animation(Motion.snappy, value: isDirty)
        .animation(Motion.fade, value: issues)
    }

    private func conflictRetry(for error: AgentError) -> (() -> Void)? {
        guard case .fileConflict = error else { return nil }
        return { Task { await load() } }
    }

    // MARK: Data

    private func load() async {
        guard let files = model.suite.files else { return }
        loading = true
        defer { loading = false }
        do {
            let content = try await files.read(entry.path)
            original = content
            text = content.text
            error = nil
        } catch {
            self.error = error.asAgentError
        }
    }

    private func save() async {
        guard let files = model.suite.files, let original else { return }
        if isSensitive {
            guard await model.gate.authorize(.editConfiguration) else {
                if let message = model.gate.lastErrorMessage { error = .permissionDenied(detail: message) }
                return
            }
        }
        saving = true
        defer { saving = false }
        do {
            let saved = try await files.write(entry.path, text: text, expectedVersion: original.version)
            self.original = saved
            withAnimation(Motion.pop) { savedPulse += 1 }
            model.toasts.show("Saved \(entry.name)")
        } catch {
            withAnimation(Motion.standard) { self.error = error.asAgentError }
        }
    }
}

struct DiffSheet: View {
    let path: String
    let old: String
    let new: String
    let issues: [ValidationIssue]
    let isSensitive: Bool
    let biometry: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = LineDiff.diff(old: old, new: new)
        let hunks = LineDiff.hunks(lines)
        let summary = LineDiff.summary(lines)
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("+\(summary.added)").foregroundStyle(BB.Palette.success)
                    Text("−\(summary.removed)").foregroundStyle(BB.Palette.danger)
                    Text(path).foregroundStyle(BB.Palette.textTertiary).lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .font(BB.Font.monoSmall)
                .padding(.horizontal, BB.Space.l)
                .padding(.vertical, 10)

                if !issues.isEmpty {
                    Label("\(issues.count) validation warning\(issues.count == 1 ? "" : "s") — check before saving.", systemImage: "exclamationmark.triangle.fill")
                        .font(BB.Font.caption)
                        .foregroundStyle(BB.Palette.warning)
                        .padding(.horizontal, BB.Space.l)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hunks) { line in
                            HStack(spacing: 8) {
                                Text(line.oldNumber.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
                                Text(line.newNumber.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
                                Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " "))
                                Text(line.text.isEmpty ? " " : line.text).fixedSize()
                            }
                            .font(BB.Font.monoSmall)
                            .foregroundStyle(line.kind == .unchanged ? BB.Palette.textSecondary : BB.Palette.textPrimary)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind == .added ? BB.Palette.success.opacity(0.14) : (line.kind == .removed ? BB.Palette.danger.opacity(0.14) : Color.clear))
                        }
                    }
                }
                .background(BB.Palette.codeBackground)

                PrimaryButton(title: isSensitive ? "Save with \(biometry)" : "Save to server", systemImage: isSensitive ? "lock.shield" : "arrow.up.doc", action: onConfirm)
                    .padding(BB.Space.l)
            }
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
