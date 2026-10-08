import Foundation

/// Applies provider events to the assistant message being streamed.
/// Pure and deterministic so the chat behaviour is unit tested without UI.
public enum ChatReducer {
    public struct Effects: Equatable, Sendable {
        public var title: String?
        public var status: AgentStatus?
        public var finished: Bool = false
        public init(title: String? = nil, status: AgentStatus? = nil, finished: Bool = false) {
            self.title = title
            self.status = status
            self.finished = finished
        }
    }

    @discardableResult
    public static func apply(_ event: AgentEvent, to message: inout Message) -> Effects {
        var effects = Effects()
        switch event {
        case .accepted(let requestID):
            message.requestID = requestID
        case .status(let status):
            effects.status = status
        case .textDelta(let text):
            message.content += text
            message.state = .streaming
        case .toolStarted(let call):
            if let index = message.toolCalls.firstIndex(where: { $0.id == call.id }) {
                message.toolCalls[index] = call
            } else {
                message.toolCalls.append(call)
                // Anchor the tool in the text so the UI can render it inline,
                // exactly where it happened in the reply.
                message.content += MessageSegment.marker(for: call.id)
            }
            message.state = .streaming
        case .toolOutput(let id, let chunk):
            if let index = message.toolCalls.firstIndex(where: { $0.id == id }) {
                message.toolCalls[index].liveOutput += chunk
                // Keep memory bounded for chatty tools.
                if message.toolCalls[index].liveOutput.count > 20_000 {
                    message.toolCalls[index].liveOutput = String(message.toolCalls[index].liveOutput.suffix(16_000))
                }
            }
        case .toolFinished(let id, let result, let status):
            if let index = message.toolCalls.firstIndex(where: { $0.id == id }) {
                message.toolCalls[index].status = status
                message.toolCalls[index].result = result
                message.toolCalls[index].finishedAt = Date()
            }
        case .conversationTitle(let title):
            effects.title = title
        case .completed:
            message.state = .complete
            finishRunningTools(in: &message, as: .succeeded)
            effects.finished = true
        case .failed(let error):
            message.state = error == .cancelled ? .cancelled : .failed(error)
            finishRunningTools(in: &message, as: error == .cancelled ? .cancelled : .failed)
            effects.finished = true
        }
        return effects
    }

    private static func finishRunningTools(in message: inout Message, as status: ToolStatus) {
        for index in message.toolCalls.indices where !message.toolCalls[index].status.isFinished {
            message.toolCalls[index].status = status
            message.toolCalls[index].finishedAt = Date()
        }
    }

    /// The user message to resend when the user taps Retry on a failed
    /// assistant reply.
    public static func retryPrompt(for assistantID: UUID, in conversation: Conversation) -> String? {
        guard let index = conversation.messages.firstIndex(where: { $0.id == assistantID }) else { return nil }
        return conversation.messages[..<index].last(where: { $0.role == .user })?.content
    }
}

/// A piece of an assistant message: text or an inline tool call.
public enum MessageSegment: Hashable, Sendable {
    case text(String)
    case tool(id: String)

    /// Record separator characters never appear in normal model output.
    static let delimiter: Character = "\u{1E}"

    public static func marker(for toolCallID: String) -> String {
        "\n\(delimiter)tool:\(toolCallID)\(delimiter)\n"
    }

    /// Splits content into text and tool segments (empty text is dropped).
    public static func split(_ content: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        let parts = content.split(separator: delimiter, omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if index % 2 == 1, part.hasPrefix("tool:") {
                segments.append(.tool(id: String(part.dropFirst(5))))
            } else {
                let text = String(part).trimmingCharacters(in: .newlines)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.text(text)) }
            }
        }
        return segments
    }

    /// Content with tool markers removed (for copy, previews and search).
    public static func plainText(_ content: String) -> String {
        split(content).compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n\n")
    }
}

public extension Message {
    var segments: [MessageSegment] { MessageSegment.split(content) }
    var plainText: String { MessageSegment.plainText(content) }
}
