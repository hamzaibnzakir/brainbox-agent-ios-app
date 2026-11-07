import Foundation

/// Builds the `conversation_history` sent with each run of a copied
/// conversation (e.g. "Continue in the app" on a Telegram chat).
///
/// Why every run: Hermes uses caller-supplied history for that turn but never
/// stores it (agent/session_persistence.py `_db_flush_collect` marks history
/// messages as already persisted), so the app's `ios_` session only ever
/// holds the new turns. The original session is only read, never written.
public enum CarriedHistory {
    public static let maxMessages = 80
    public static let maxCharacters = 120_000

    /// Completed user/assistant text before the turn being sent, newest
    /// `maxMessages`, trimmed from the oldest end to `maxCharacters`.
    public static func build(from conversation: Conversation,
                             maxMessages: Int = maxMessages,
                             maxCharacters: Int = maxCharacters) -> [HistoryTurn] {
        var messages = conversation.messages
        // Drop the turn being sent: the last user message and anything after
        // it (the assistant placeholder that is about to stream).
        if let lastUser = messages.lastIndex(where: { $0.role == .user }) {
            messages.removeSubrange(lastUser...)
        }
        var turns: [HistoryTurn] = messages.compactMap { message in
            guard message.role == .user || message.role == .assistant else { return nil }
            guard message.state == .complete else { return nil }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return HistoryTurn(role: message.role.rawValue, content: text)
        }
        if turns.count > maxMessages { turns.removeFirst(turns.count - maxMessages) }

        var total = turns.reduce(0) { $0 + $1.content.count }
        while total > maxCharacters, turns.count > 1 {
            total -= turns.removeFirst().content.count
        }
        if total > maxCharacters, var only = turns.first {
            // A single oversized message keeps its most recent part.
            only.content = String(only.content.suffix(maxCharacters))
            turns = [only]
        }
        return turns
    }
}
