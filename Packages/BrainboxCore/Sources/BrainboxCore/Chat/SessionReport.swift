import Foundation

/// Text for /status and /usage, built from Hermes' own session record
/// (`GET /api/sessions/{id}`) — the same facts Telegram's handlers read from SessionDB.
public enum SessionReport {
    static func number(_ value: Int?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func date(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    public static func status(session: HermesSession?, sessionID: String?, modelOverride: String?,
                              runID: String?, liveness: RunLiveness?, queued: Int, connection: String) -> String {
        var lines: [String] = []
        if let sessionID { lines.append("Session: `\(sessionID)`") }
        if let title = session?.title, !title.isEmpty { lines.append("Title: \(title)") }
        if let created = date(session?.startedAt) { lines.append("Created: \(created)") }
        if let active = date(session?.lastActive) { lines.append("Last activity: \(active)") }
        if let model = modelOverride ?? session?.model, !model.isEmpty {
            lines.append("Model: \(model)" + (modelOverride != nil ? " (chosen for this chat)" : ""))
        }
        if let session {
            let total = (session.inputTokens ?? 0) + (session.outputTokens ?? 0)
            lines.append("Tokens: \(number(total)) (in \(number(session.inputTokens)) · out \(number(session.outputTokens)))")
            if let count = session.messageCount { lines.append("Messages: \(count)") }
        } else if sessionID != nil {
            lines.append("Hermes has no record of this chat yet (it's created with the first message).")
        }
        if let runID {
            var running = "Agent running: yes (run \(runID))"
            if let liveness { running += " · \(liveness.label)" + (liveness.transportLabel.map { " · \($0)" } ?? "") }
            lines.append(running)
        } else {
            lines.append("Agent running: no")
        }
        if queued > 0 { lines.append("Queued: \(queued)") }
        lines.append(connection)
        return lines.joined(separator: "\n")
    }

    public static func usage(session: HermesSession) -> String {
        var lines = [
            "Input tokens: \(number(session.inputTokens))",
            "Output tokens: \(number(session.outputTokens))",
        ]
        if let cached = session.cacheReadTokens, cached > 0 { lines.append("Cache reads: \(number(cached))") }
        if let reasoning = session.reasoningTokens, reasoning > 0 { lines.append("Reasoning tokens: \(number(reasoning))") }
        if let calls = session.apiCallCount { lines.append("Model calls: \(number(calls))") }
        if let cost = session.actualCostUSD ?? session.estimatedCostUSD, cost > 0 {
            lines.append(String(format: "Cost: $%.4f%@", cost, session.actualCostUSD == nil ? " (estimated)" : ""))
        }
        lines.append("Rate limits and plan details are only shown by Telegram's /usage.")
        return lines.joined(separator: "\n")
    }
}
