import SwiftUI
import UIKit
import BrainboxCore

struct MessageRow: View {
    let message: Message
    let agentName: String
    var isLatest: Bool
    var onRetry: () -> Void
    var onCopy: (String) -> Void

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant, .system: assistantBody
        }
    }

    // MARK: User

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
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
                AgentOrb(mode: orbMode, size: 22)
                Text(agentName).font(BB.Font.subhead).foregroundStyle(BB.Palette.textPrimary)
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(BB.Font.caption)
                    .foregroundStyle(BB.Palette.textTertiary)
                Spacer()
            }

            if message.state == .sending && message.content.isEmpty {
                ThinkingLine()
                    .transition(.bbRise)
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

            if message.state == .streaming {
                StreamingCaret().transition(.opacity)
            }

            switch message.state {
            case .failed(let error):
                ErrorBanner(error: error, retry: onRetry)
                    .bbShakeOnAppear()
                    .transition(.bbRise)
            case .cancelled:
                Label("Stopped", systemImage: "stop.circle")
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
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text("Thinking")
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
        .accessibilityLabel("Agent is thinking")
    }
}
