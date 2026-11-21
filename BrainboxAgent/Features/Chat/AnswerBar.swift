import HermesKit
import SwiftUI

/// What the composer is answering while Hermes waits on you. While a question is open, Hermes'
/// turn is paused on it: a normal message would only queue behind that turn (and never run), so
/// the composer answers the question instead.
struct AnswerTarget: Equatable {
    var prompt: String
    var choices: [String]
    var multiSelect: Bool
    var secure: Bool
    var questionID: String?
    /// "2 of 3" for a batch of questions.
    var step: String?

    /// The open question in `request`, skipping batch questions already answered.
    static func from(_ request: PendingRequest?, answered: Set<String>) -> AnswerTarget? {
        guard let request, request.resolution == nil else { return nil }
        switch request.kind {
        case .clarify(let question, let choices, let multi):
            return AnswerTarget(prompt: question, choices: choices, multiSelect: multi, secure: false, questionID: request.questionID)
        case .clarifyBatch(let questions):
            guard let index = questions.firstIndex(where: { !answered.contains($0.id) }) else { return nil }
            let q = questions[index]
            return AnswerTarget(prompt: q.question, choices: q.choices, multiSelect: q.multiSelect, secure: false, questionID: q.id,
                                step: questions.count > 1 ? "\(index + 1) of \(questions.count)" : nil)
        case .sudo:
            return AnswerTarget(prompt: "Hermes needs the sudo password", choices: [], multiSelect: false, secure: true, questionID: nil)
        case .secret(let prompt, let envVar):
            return AnswerTarget(prompt: prompt.isEmpty ? "Hermes needs \(envVar.isEmpty ? "a secret" : envVar)" : prompt,
                                choices: [], multiSelect: false, secure: true, questionID: nil)
        case .approval:
            return nil
        }
    }
}

/// The question (and its choices) pinned right above the keyboard.
struct AnswerBar: View {
    var target: AnswerTarget
    var answer: (String) -> Void
    var skip: (() -> Void)?
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.S.s) {
                Image(systemName: target.secure ? "lock.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.C.volt)
                Text(target.prompt).font(DS.F.smallStrong).foregroundStyle(DS.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let step = target.step { Text(step).font(DS.F.caption).foregroundStyle(DS.C.ink3) }
            }
            if !target.choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.S.s) {
                        ForEach(target.choices, id: \.self) { choice in
                            Button {
                                Haptic.tap()
                                if target.multiSelect {
                                    if picked.contains(choice) { picked.remove(choice) } else { picked.insert(choice) }
                                } else {
                                    answer(choice)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if target.multiSelect {
                                        Image(systemName: picked.contains(choice) ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                                    }
                                    Text(choice).lineLimit(1)
                                }
                            }
                            .buttonStyle(ChipButtonStyle(selected: picked.contains(choice)))
                        }
                        if target.multiSelect, !picked.isEmpty {
                            Button("Send \(picked.count)") { answer(picked.sorted().joined(separator: ", ")); picked = [] }
                                .buttonStyle(ChipButtonStyle(selected: true))
                        }
                    }
                }
            }
            HStack {
                Text(target.secure ? "Type it below — it's sent straight to the server, not saved in the chat."
                                   : target.choices.isEmpty ? "Type your answer below." : "Tap a choice, or type your own answer below.")
                    .font(DS.F.caption).foregroundStyle(DS.C.ink3)
                Spacer(minLength: 0)
                if let skip { Button("Skip", action: skip).font(DS.F.captionStrong).foregroundStyle(DS.C.ink2) }
            }
        }
        .padding(DS.S.m)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.volt.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, DS.S.m)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onChange(of: target) { _, _ in picked = [] }
    }
}

/// Approve / deny a command without scrolling back to its card.
struct ApprovalBar: View {
    var command: String
    var choices: [String]
    var choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            HStack(spacing: DS.S.s) {
                Image(systemName: "hand.raised.fill").foregroundStyle(DS.C.warn)
                Text("Approve this command?").font(DS.F.smallStrong).foregroundStyle(DS.C.ink)
                Spacer(minLength: 0)
                Button("Deny") { Haptic.tap(); choose("deny") }
                    .font(DS.F.smallStrong).foregroundStyle(DS.C.bad).lineLimit(1)
            }
            Text(command).font(DS.F.monoSmall).foregroundStyle(DS.C.ink2).lineLimit(2)
            HStack(spacing: DS.S.s) {
                ForEach(["once", "session", "always"].filter(choices.contains), id: \.self) { c in
                    Button { Haptic.tap(); choose(c) } label: {
                        Text(RequestCard.label(c)).lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: c == "once" ? DS.C.good : DS.C.ink2))
                }
            }
        }
        .padding(DS.S.m)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.warn.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, DS.S.m)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
