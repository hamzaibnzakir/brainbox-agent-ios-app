import BrainboxCore
import HermesKit
import SwiftUI

struct ChatItemView: View {
    var item: ChatItem
    var chat: String
    @Environment(AppModel.self) private var model

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments)
        case .assistant(let text, let reasoning, let streaming):
            AssistantMessage(text: text, reasoning: model.preferences.showReasoning ? reasoning : nil, streaming: streaming)
        case .tool(let tool):
            ToolCard(tool: tool, expandedByDefault: false)
        case .request(let request):
            RequestCard(request: request, chat: chat)
        case .command(let name, let output):
            CommandCard(name: name, output: output)
        case .side(let label, let title, let text, let done):
            SideCard(label: label, title: title, text: text, done: done)
        case .notice(let text, let level):
            HStack(spacing: DS.S.s) {
                Image(systemName: level == "warn" || level == "warning" ? "exclamationmark.circle" : "info.circle")
                Text(text).multilineTextAlignment(.leading)
            }
            .font(DS.F.caption).foregroundStyle(DS.C.ink3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.S.xs)
        case .error(let text):
            ErrorBanner(message: text)
        }
    }
}

struct UserBubble: View {
    var text: String
    var attachments: [String]
    @Environment(\.chatTextScale) private var scale

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: DS.S.s) {
                ForEach(attachments, id: \.self) { name in
                    Label(name, systemImage: "paperclip").font(DS.F.caption).foregroundStyle(DS.C.userText.opacity(0.8))
                }
                if !text.isEmpty {
                    Text(text).font(.system(size: 17 * scale)).foregroundStyle(DS.C.userText).textSelection(.enabled)
                }
            }
            .padding(.horizontal, DS.S.m)
            .padding(.vertical, DS.S.s + 4)
            .background(DS.C.userBubble, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                                    bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous))
            .contextMenu {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
    }
}

struct AssistantMessage: View {
    var text: String
    var reasoning: String?
    var streaming: Bool
    @State private var showReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            if let reasoning, !reasoning.isEmpty {
                Button {
                    withAnimation(.snappy) { showReasoning.toggle() }
                } label: {
                    HStack(spacing: DS.S.xs) {
                        Image(systemName: "brain").font(.system(size: 12, weight: .semibold))
                        Text(streaming && text.isEmpty ? "Thinking…" : "Reasoning").font(DS.F.captionStrong)
                        Image(systemName: showReasoning ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(DS.C.ink3)
                }
                if showReasoning {
                    Text(reasoning).font(DS.F.small).foregroundStyle(DS.C.ink3)
                        .padding(DS.S.s + 4)
                        .background(DS.C.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if !text.isEmpty {
                MarkdownText(text: text, streaming: streaming)
            }
            if streaming {
                TypingDots()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(DS.C.volt)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
        .frame(height: 12)
        .accessibilityLabel("Hermes is typing")
    }
}

struct ToolCard: View {
    var tool: ToolActivity
    var expandedByDefault: Bool
    @State private var expanded: Bool? = nil
    @Environment(AppModel.self) private var model

    private var isExpanded: Bool { expanded ?? expandedByDefault }

    private var symbol: String {
        switch tool.name {
        case "terminal", "process": return "terminal"
        case let n where n.contains("file") || n.contains("patch") || n.contains("write") || n.contains("read"): return "doc.text"
        case let n where n.contains("web") || n.contains("browser"): return "globe"
        case let n where n.contains("search"): return "magnifyingglass"
        case "delegate_task": return "person.2"
        case "memory": return "brain"
        case "todo": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            Button {
                withAnimation(.snappy) { expanded = !isExpanded }
            } label: {
                HStack(spacing: DS.S.s + 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(statusColor.opacity(0.12)).frame(width: 32, height: 32)
                        if tool.status == .running { ProgressView().controlSize(.mini) }
                        else { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(statusColor) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name.replacingOccurrences(of: "_", with: " ")).font(DS.F.smallStrong).foregroundStyle(DS.C.ink)
                        if !tool.context.isEmpty {
                            Text(tool.context).font(DS.F.monoSmall).foregroundStyle(DS.C.ink3).lineLimit(isExpanded ? 6 : 1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let d = tool.duration { Text(Fmt.duration(d)).font(DS.F.caption).foregroundStyle(DS.C.ink3) }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.C.ink3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let note = tool.approvalNote { Text(note).font(DS.F.caption).foregroundStyle(DS.C.warn) }
                if let diff = tool.inlineDiff, !diff.isEmpty {
                    DiffText(diff: diff)
                } else if !tool.output.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(String(tool.output.prefix(6000))).font(DS.F.monoSmall).foregroundStyle(DS.C.ink2)
                            .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxHeight: 240)
                    .padding(DS.S.s + 4)
                    .background(DS.C.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(DS.S.s + 4)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.line, lineWidth: 1))
        .onAppear { if expanded == nil, model.preferences.showToolDetails, tool.status == .failed { expanded = true } }
    }

    private var statusColor: Color {
        switch tool.status {
        case .running: return DS.C.volt
        case .done: return DS.C.good
        case .failed: return DS.C.bad
        }
    }
}

struct DiffText: View {
    var diff: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(String(line).isEmpty ? " " : String(line))
                        .font(DS.F.monoSmall)
                        .foregroundStyle(line.hasPrefix("+") ? DS.C.good : line.hasPrefix("-") ? DS.C.bad : DS.C.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.hasPrefix("+") ? DS.C.good.opacity(0.08) : line.hasPrefix("-") ? DS.C.bad.opacity(0.08) : .clear)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxHeight: 280)
        .padding(DS.S.s)
        .background(DS.C.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CommandCard: View {
    var name: String
    var output: String
    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            Label(name, systemImage: "command").font(DS.F.captionStrong).foregroundStyle(DS.C.volt)
            Text(output.isEmpty ? "(no output)" : output)
                .font(DS.F.monoSmall).foregroundStyle(DS.C.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card(padding: DS.S.m, tint: DS.C.raised)
    }
}

struct SideCard: View {
    var label: String
    var title: String
    var text: String
    var done: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            HStack {
                Pill(text: label == "btw" ? "By the way" : "Background", color: DS.C.volt, symbol: label == "btw" ? "bubble.left" : "moon.stars")
                Spacer()
                if !done { ProgressView().controlSize(.small) }
            }
            Text(title).font(DS.F.smallStrong).foregroundStyle(DS.C.ink2).lineLimit(3)
            if !text.isEmpty { MarkdownText(text: text) }
        }
        .card(padding: DS.S.m, tint: DS.C.voltSoft)
    }
}

// MARK: - Hermes is waiting on you

struct RequestCard: View {
    var request: PendingRequest
    var chat: String
    @Environment(AppModel.self) private var model
    @State private var answer = ""
    @State private var picked: Set<String> = []
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            header
            if let resolution = request.resolution {
                Label(resolution, systemImage: resolution.hasPrefix("Denied") || resolution == "Expired" ? "xmark.circle" : "checkmark.circle.fill")
                    .font(DS.F.smallStrong).foregroundStyle(resolution.hasPrefix("Denied") || resolution == "Expired" ? DS.C.ink3 : DS.C.good)
            } else {
                controls
            }
        }
        .card(padding: DS.S.m, tint: request.resolution == nil ? DS.C.surface : DS.C.raised)
        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
            .stroke(request.resolution == nil ? DS.C.warn.opacity(0.6) : .clear, lineWidth: 1.5))
        .disabled(sending)
    }

    @ViewBuilder private var header: some View {
        switch request.kind {
        case .approval(let command, let description, _):
            VStack(alignment: .leading, spacing: DS.S.s) {
                Label("Approve this command?", systemImage: "hand.raised.fill").font(DS.F.bodyStrong).foregroundStyle(DS.C.warn)
                if !description.isEmpty { Text(description.capitalized).font(DS.F.small).foregroundStyle(DS.C.ink2) }
                Text(command).font(DS.F.monoSmall).foregroundStyle(DS.C.ink)
                    .padding(DS.S.s + 4).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.C.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .clarify(let question, _, _):
            Label(question, systemImage: "questionmark.bubble.fill").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
        case .clarifyBatch:
            Label("Hermes has a few questions", systemImage: "questionmark.bubble.fill").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
        case .sudo:
            Label("Hermes needs the sudo password", systemImage: "lock.fill").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
        case .secret(let prompt, let envVar):
            VStack(alignment: .leading, spacing: DS.S.xs) {
                Label(prompt.isEmpty ? "Hermes needs a secret" : prompt, systemImage: "key.fill").font(DS.F.bodyStrong).foregroundStyle(DS.C.ink)
                if !envVar.isEmpty { Text("Saved on the server as \(envVar)").font(DS.F.caption).foregroundStyle(DS.C.ink3) }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch request.kind {
        case .approval(_, _, let choices):
            let ordered = ["once", "session", "always"].filter(choices.contains)
            VStack(spacing: DS.S.s) {
                HStack(spacing: DS.S.s) {
                    ForEach(ordered, id: \.self) { choice in
                        Button(Self.label(choice)) { send(choice) }
                            .buttonStyle(SecondaryButtonStyle(tint: choice == "once" ? DS.C.good : DS.C.ink2))
                    }
                }
                Button("Deny") { send("deny") }.buttonStyle(SecondaryButtonStyle(tint: DS.C.bad)).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .clarify(_, let choices, let multi):
            VStack(alignment: .leading, spacing: DS.S.s) {
                if !choices.isEmpty {
                    FlowChips(items: choices, selected: picked) { choice in
                        if multi { if picked.contains(choice) { picked.remove(choice) } else { picked.insert(choice) } }
                        else { send(choice) }
                    }
                }
                answerField(placeholder: choices.isEmpty ? "Your answer" : "Or type something else")
                if multi, !picked.isEmpty {
                    Button("Send \(picked.count) selected") { send(picked.sorted().joined(separator: ", ")) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        case .clarifyBatch(let questions):
            ClarifyBatchForm(questions: questions) { qid, value in
                Task { await model.respond(request, answer: value, questionID: qid, chat: chat) }
            }
        case .sudo, .secret:
            HStack(spacing: DS.S.s) {
                SecureField("Type it here", text: $answer)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, DS.S.m).frame(minHeight: 44)
                    .background(DS.C.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Send") { send(answer) }.buttonStyle(SecondaryButtonStyle()).disabled(answer.isEmpty)
                Button("Skip") { send("") }.buttonStyle(SecondaryButtonStyle(tint: DS.C.ink3))
            }
        }
    }

    private func answerField(placeholder: String) -> some View {
        HStack(spacing: DS.S.s) {
            TextField(placeholder, text: $answer, axis: .vertical)
                .padding(.horizontal, DS.S.m).padding(.vertical, DS.S.s + 2)
                .background(DS.C.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button { send(answer) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }
                .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func send(_ value: String) {
        sending = true
        Haptic.tap()
        Task {
            await model.respond(request, answer: value, chat: chat)
            sending = false
            answer = ""
        }
    }

    static func label(_ choice: String) -> String {
        switch choice {
        case "once": return "Allow once"
        case "session": return "This chat"
        case "always": return "Always"
        default: return choice.capitalized
        }
    }
}

struct ClarifyBatchForm: View {
    var questions: [ClarifyQuestion]
    var submit: (String, String) -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            ForEach(questions, id: \.id) { q in
                VStack(alignment: .leading, spacing: DS.S.s) {
                    Text(q.question).font(DS.F.smallStrong).foregroundStyle(DS.C.ink)
                    if !q.choices.isEmpty {
                        FlowChips(items: q.choices, selected: Set([answers[q.id] ?? ""])) { choice in
                            answers[q.id] = choice
                            submit(q.id, choice)
                        }
                    } else {
                        TextField("Answer", text: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 }))
                            .padding(.horizontal, DS.S.m).frame(minHeight: 44)
                            .background(DS.C.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onSubmit { submit(q.id, answers[q.id] ?? "") }
                    }
                }
            }
        }
    }
}

/// Wrapping row of chips.
struct FlowChips: View {
    var items: [String]
    var selected: Set<String>
    var tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: DS.S.s) {
            ForEach(items, id: \.self) { item in
                Button(item) { tap(item) }.buttonStyle(ChipButtonStyle(selected: selected.contains(item)))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
