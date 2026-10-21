import SwiftUI
import BrainboxCore

/// The agent is blocked on a human decision. Shows the exact action Hermes
/// reported (already redacted server-side), only the choices Hermes offered
/// (narrowed further by the teammate's approval scope), a one-tap Deny, and
/// hold-to-confirm for anything that allows the action. Nothing is ever
/// approved automatically.
struct ApprovalSheet: View {
    let approval: AgentApproval
    var teammate: Teammate?
    var onResolved: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working: HermesApprovalChoice?
    @State private var error: AgentError?
    @State private var appeared = false

    private var choices: [HermesApprovalChoice] {
        let allowed = (teammate?.approvalScope ?? .onceOnly).filter(approval.choices)
        return allowed.compactMap(HermesApprovalChoice.init(rawValue:)).filter { $0 != .deny }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    if let teammate {
                        MascotView(style: teammate.mascot, mood: .waitingApproval, size: 46, seed: teammate.id)
                    } else {
                        Image(systemName: "exclamationmark.shield.fill").font(.system(size: 30)).foregroundStyle(BB.Palette.warning)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Approval needed").font(BB.Font.title).foregroundStyle(BB.Palette.textPrimary)
                        Text("\(teammate?.name ?? "Hermes") wants to run this on your VPS").font(BB.Font.callout).foregroundStyle(BB.Palette.textSecondary)
                    }
                }
                .bbEntrance(index: 0)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Exact action").bbLabelStyle()
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(approval.command.isEmpty ? "(no command text provided)" : approval.command)
                            .font(BB.Font.mono)
                            .foregroundStyle(BB.Palette.textPrimary)
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.codeBackground))
                    .overlay(AmberPulseBorder())
                    .accessibilityIdentifier("approval.command")
                    if let description = approval.description, !description.isEmpty {
                        Label(description, systemImage: "info.circle")
                            .font(BB.Font.callout)
                            .foregroundStyle(BB.Palette.textSecondary)
                    }
                }
                .bbEntrance(index: 1)

                if let error {
                    ErrorBanner(error: error, dismiss: { self.error = nil }).transition(.bbRise)
                }

                VStack(spacing: 10) {
                    ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                        HoldToConfirmButton(
                            title: choice.title,
                            systemImage: choice.widensPermissions ? "lock.open" : "checkmark.shield",
                            tint: choice.widensPermissions ? BB.Palette.danger : BB.Palette.warning,
                            duration: choice.widensPermissions ? 1.6 : 1.2
                        ) {
                            Task { await decide(choice) }
                        }
                        .disabled(working != nil)
                        .accessibilityIdentifier("approval.\(choice.rawValue)")
                        .bbEntrance(index: index + 2)
                    }
                    Button {
                        Task { await decide(.deny) }
                    } label: {
                        Text(working == .deny ? "Denying…" : "Deny")
                            .font(BB.Font.headline)
                            .foregroundStyle(BB.Palette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surfaceHigh))
                    }
                    .buttonStyle(.pressable)
                    .disabled(working != nil)
                    .accessibilityIdentifier("approval.deny")
                }

                Text(footnote)
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.textTertiary)
            }
            .padding(22)
            .animation(Motion.smooth, value: error)
        }
        .background(BB.Palette.backgroundRaised)
        .sensoryFeedback(.warning, trigger: appeared)
        .onAppear { appeared = true }
    }

    private var footnote: String {
        var text = "Hermes waits for your answer; silence is never treated as consent. "
        if approval.choices.contains("always") && !choices.contains(.always) {
            text += "“Always allow” is hidden by this teammate's approval scope."
        }
        return text
    }

    private func decide(_ choice: HermesApprovalChoice) async {
        if choice.widensPermissions {
            guard await model.gate.authorize(.changeAgentConfiguration) else { return }
        }
        working = choice
        defer { working = nil }
        do {
            try await model.chat.respond(to: approval, choice: choice)
            onResolved(choice.rawValue)
            dismiss()
        } catch {
            withAnimation(Motion.smooth) { self.error = error.asAgentError }
        }
    }
}

/// Slow amber glow around the command while it waits for a decision.
private struct AmberPulseBorder: View {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.bbForceReduceMotion) private var forced
    var body: some View {
        let reduce = system || forced
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduce || !Motion.ambientEnabled)) { timeline in
            let pulse = reduce ? 0.6 : 0.45 + 0.35 * sin(timeline.date.timeIntervalSinceReferenceDate * 2.2)
            RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous)
                .strokeBorder(BB.Palette.warning.opacity(pulse), lineWidth: 1.5)
                .shadow(color: BB.Palette.warning.opacity(0.35 * pulse), radius: 8)
        }
        .allowsHitTesting(false)
    }
}

/// Inline card in the chat while a reply waits for approval.
struct InlineApprovalCard: View {
    let approval: AgentApproval
    var onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(BB.Palette.warning)
                    .symbolEffect(.pulse, options: .repeating, isActive: Motion.ambientEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting for your approval").font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                    Text(approval.command).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textSecondary).lineLimit(2)
                }
                Spacer()
                Text("Review").font(BB.Font.subhead).foregroundStyle(BB.Palette.signalText)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.warning.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.warning.opacity(0.45)))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("approval.inline")
    }
}

/// Collapsible reasoning the backend chose to expose.
struct ReasoningDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.smooth) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(BB.Palette.signalText)
                    Text("Reasoning").font(BB.Font.subhead).foregroundStyle(BB.Palette.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BB.Palette.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.pressableSubtle)
            if expanded {
                Text(text)
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: BB.Radius.s, style: .continuous).fill(BB.Palette.surfaceSunken))
                    .transition(.bbRise)
            }
        }
    }
}
