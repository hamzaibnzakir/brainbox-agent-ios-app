import SwiftUI
import UIKit
import BrainboxCore

struct MessageRow: View {
    let message: Message
    let agentName: String
    var isLatest: Bool
    var onRetry: () -> Void
    var onCopy: (String) -> Void
    var onReviewApproval: (AgentApproval) -> Void = { _ in }
    /// Stop again / stop following, for an unconfirmed stop on the live reply.
    var onStopAgain: (() -> Void)? = nil
    var onStopFollowing: (() -> Void)? = nil
    /// Re-open the live stream (shown with the silence warning).
    var onReconnect: (() -> Void)? = nil

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBody
        case .system: commandOutput
        }
    }

    // MARK: Command output (local, never sent)

    private var commandOutput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Brainbox", systemImage: "command")
                .font(BB.Font.label)
                .foregroundStyle(BB.Palette.textTertiary)
            MarkdownView(text: message.content, isStreaming: false, onCopy: onCopy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).fill(BB.Palette.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: BB.Radius.m, style: .continuous).strokeBorder(BB.Palette.stroke))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.command")
    }

    // MARK: User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                }
                if message.sentContent != nil && message.content.hasPrefix("/") {
                    Label("Ran as a Hermes skill", systemImage: "wand.and.stars")
                        .font(BB.Font.caption)
                        .foregroundStyle(BB.Palette.textTertiary)
                }
                Text(message.content)
                    .font(BB.Font.body)
                    .foregroundStyle(BB.Palette.onUserBubble)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous)
                            .fill(BB.Palette.userBubble)
                    )
                    .textSelection(.enabled)
                    .contextMenu {
                        Button { onCopy(message.content) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(message.content)")
    }

    // MARK: Assistant

    private var isActive: Bool { message.state == .streaming || message.state == .sending }

    private var botMood: MascotMood {
        if message.pendingApproval != nil { return .waitingApproval }
        switch message.state {
        case .sending: return .thinking
        case .streaming: return message.toolCalls.contains { $0.status == .running } ? .working : .thinking
        case .failed: return .failed
        case .cancelled: return .interrupted
        case .complete: return .idle
        }
    }

    private var orbMode: OrbMode {
        switch message.state {
        case .sending: return .thinking
        case .streaming: return message.toolCalls.contains { $0.status == .running } ? .tool : .streaming
        case .failed: return .error
        default: return .ready
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MascotView(style: .brainbox, mood: botMood, size: 24, seed: message.id)
                Text(agentName).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.textTertiary)
                Spacer()
            }

            if message.state == .sending && message.content.isEmpty && message.liveness == nil {
                ThinkingLine(label: "Connecting")
                    .transition(.bbRise)
            }

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ReasoningDisclosure(text: reasoning).transition(.bbRise)
            }

            ForEach(Array(message.segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let text):
                    MarkdownView(text: text, isStreaming: isActive, onCopy: onCopy)
                        .transition(.bbRise)
                case .tool(let id):
                    if let call = message.toolCalls.first(where: { $0.id == id }) {
                        ToolCardView(call: call)
                            .transition(.bbRise)
                    }
                }
            }

            if let approval = message.pendingApproval {
                InlineApprovalCard(approval: approval) { onReviewApproval(approval) }
                    .transition(.bbRise)
            }

            if let resolved = message.resolvedApprovals, !resolved.isEmpty {
                ForEach(Array(resolved.enumerated()), id: \.offset) { _, item in
                    Label("\(item.choice == "deny" ? "Denied" : "Approved (\(item.choice))"): \(item.command)", systemImage: item.choice == "deny" ? "hand.raised" : "checkmark.shield")
                        .font(BB.Font.caption)
                        .foregroundStyle(BB.Palette.textTertiary)
                        .lineLimit(1)
                }
            }

            if message.state == .streaming && message.pendingApproval == nil {
                StreamingCaret().transition(.opacity)
            }

            if let liveness = message.liveness, !message.state.isTerminal {
                RunStatusLine(liveness: liveness, onReconnect: onReconnect)
                    .transition(.bbRise)
            }

            if let stop = message.stop {
                StopPhaseLine(phase: stop, onStopAgain: onStopAgain, onStopFollowing: onStopFollowing)
                    .transition(.bbRise)
            }

            switch message.state {
            case .failed(let error):
                ErrorBanner(error: error, retry: onRetry)
                    .bbShakeOnAppear()
                    .transition(.bbRise)
            case .cancelled:
                Label(message.runID != nil ? "Stopped — Hermes confirmed" : "Stopped", systemImage: "stop.circle")
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.textTertiary)
            default:
                EmptyView()
            }

            if message.state == .complete || message.state == .cancelled {
                actions.transition(.opacity)
            }
        }
        .animation(Motion.standard, value: message.segments.count)
        .animation(Motion.standard, value: message.state)
        .animation(Motion.smooth, value: message.pendingApproval)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityState)
    }

    private var accessibilityState: String {
        switch message.state {
        case .complete: return "assistant.complete"
        case .failed: return "assistant.failed"
        case .cancelled: return "assistant.cancelled"
        case .sending, .streaming: return "assistant.streaming"
        }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Button { onCopy(message.plainText) } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy reply")
            if isLatest {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Regenerate")
            }
            Spacer()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(BB.Palette.textTertiary)
        .buttonStyle(.pressableSubtle)
    }
}

/// "Thinking" placeholder: shimmering label with three staggered dots.
struct ThinkingLine: View {
    var label: String = "Thinking"
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(BB.Font.callout)
                .foregroundStyle(BB.Palette.textSecondary)
                .bbShimmer()
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(BB.Palette.signal)
                        .frame(width: 5, height: 5)
                        .scaleEffect(phase ? 1 : 0.5)
                        .opacity(phase ? 1 : 0.35)
                        .animation(Motion.ambient(reduceMotion: reduceMotion) ? .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15) : nil, value: phase)
                }
            }
        }
        .onAppear { phase = true }
        .accessibilityLabel(label)
    }
}

/// Run status from real signals only — a status indicator, never model output.
/// Shows the phase, the link, time since Hermes' last event, and an honest warning
/// after three minutes without one.
struct RunStatusLine: View {
    let liveness: RunLiveness
    var onReconnect: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                    Text(statusText(now: context.date))
                        .lineLimit(1)
                }
                .font(BB.Font.caption)
                .foregroundStyle(BB.Palette.textTertiary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: " + statusText(now: context.date))
                .accessibilityIdentifier("run.status")

                if let note = liveness.upstreamNote {
                    Label(note, systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let warning = liveness.silenceWarning(now: context.date) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(warning, systemImage: "clock.badge.exclamationmark")
                            .font(BB.Font.caption)
                            .foregroundStyle(BB.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        if let onReconnect {
                            Button("Reconnect", action: onReconnect)
                                .font(BB.Font.subhead)
                                .foregroundStyle(BB.Palette.textPrimary)
                                .buttonStyle(.pressableSubtle)
                                .accessibilityIdentifier("run.reconnect")
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: BB.Radius.s, style: .continuous).fill(BB.Palette.surfaceHigh))
                    .accessibilityIdentifier("run.silence")
                }
            }
        }
    }

    private var icon: String {
        switch liveness.transport {
        case .live: return liveness.phase == .runningTool ? "gearshape" : "circle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .polling: return "arrow.clockwise"
        case .disconnected: return "wifi.slash"
        }
    }

    private func statusText(now: Date) -> String {
        var parts = [liveness.label]
        if let transport = liveness.transportLabel { parts.append(transport) }
        if let last = liveness.lastEventAt {
            let seconds = max(0, Int(now.timeIntervalSince(last)))
            if seconds >= 5 { parts.append("last event \(Self.ago(seconds))") }
        } else {
            let seconds = max(0, Int(now.timeIntervalSince(liveness.startedAt)))
            if seconds >= 5 { parts.append("no events yet · \(Self.ago(seconds))") }
        }
        return parts.joined(separator: " · ")
    }

    static func ago(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m \(seconds % 60)s ago"
    }
}


/// Where a Stop stands, in words (never "stopped" before Hermes says so).
struct StopPhaseLine: View {
    let phase: StopPhase
    var onStopAgain: (() -> Void)?
    var onStopFollowing: (() -> Void)?

    var body: some View {
        switch phase {
        case .requested:
            Label("Stop requested…", systemImage: "hourglass").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                .accessibilityIdentifier("stop.requested")
        case .acknowledged:
            Label("Hermes is stopping it…", systemImage: "stop.circle").font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary)
                .accessibilityIdentifier("stop.acknowledged")
        case .finishedFirst:
            Label("Finished before the stop reached it", systemImage: "checkmark.circle").font(BB.Font.caption).foregroundStyle(BB.Palette.textTertiary)
        case .unconfirmed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle").font(BB.Font.caption).foregroundStyle(BB.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if let onStopAgain { Button("Stop again", action: onStopAgain) }
                    if let onStopFollowing { Button("Stop following", action: onStopFollowing) }
                }
                .font(BB.Font.subhead)
                .foregroundStyle(BB.Palette.textPrimary)
                .buttonStyle(.pressableSubtle)
            }
            .accessibilityIdentifier("stop.unconfirmed")
        }
    }
}

/// Photos / files on a sent message with their real delivery status.
struct AttachmentStrip: View {
    let attachments: [MessageAttachment]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { item in
                HStack(spacing: 6) {
                    if let data = item.thumbnail, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: item.kind == .image ? "photo" : "doc").frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(BB.Font.caption).lineLimit(1)
                        Text(Self.status(item.status)).font(.system(size: 10)).foregroundStyle(BB.Palette.textTertiary)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(BB.Palette.surfaceHigh))
                .accessibilityElement(children: .combine)
            }
        }
        .foregroundStyle(BB.Palette.textPrimary)
    }

    static func status(_ status: MessageAttachment.Status) -> String {
        switch status {
        case .preparing: return "Preparing"
        case .uploading(let p): return "Uploading \(Int(p * 100))%"
        case .uploaded: return "On your server"
        case .sent: return "Sent with message"
        case .failed(let reason): return "Not sent: \(reason)"
        }
    }
}
