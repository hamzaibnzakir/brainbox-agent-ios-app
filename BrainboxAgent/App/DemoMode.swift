import BrainboxCore
import Foundation
import HermesKit

/// `-BBDemo` launch argument: sample data with no server, for UI tests and screenshots.
extension AppModel {
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-BBDemo") }

    func loadDemo() {
        let target = SSHTarget(host: "203.0.113.10", port: 22, username: "root")
        profile = ServerProfile(name: "Brainbox VPS", target: target)
        connection = .connected(ServerInfo(target: target, hostFingerprint: "SHA256:demoDemoDemoDemo", version: "0.21.2",
                                           hermesPath: "/root/.local/bin/hermes", reusedBackend: true, skinAccent: nil))
        var t = Transcript()
        t.title = "Server check"
        t.model = "claude-opus-4"
        t.items = [
            ChatItem(kind: .user(text: "Is the Telegram bot healthy? Restart nothing, just check.", attachments: [])),
            ChatItem(kind: .assistant(text: "Checking the gateway and recent logs.", reasoning: "Look at the gateway status first, then the log tail.", streaming: false)),
            ChatItem(id: "tool-1", kind: .tool(ToolActivity(id: "1", name: "terminal", context: "hermes gateway status", args: .null, status: .done,
                                                            duration: 0.8, output: "gateway: running (pid 1834)\ntelegram: connected", inlineDiff: nil, approvalNote: nil))),
            ChatItem(kind: .assistant(text: "**All good.** The gateway is running and Telegram is connected.\n\n- Last message handled 4 minutes ago\n- No errors in the last 24 hours\n\n```bash\nhermes gateway status\n```", reasoning: nil, streaming: false)),
            ChatItem(id: "req-demo", kind: .request(PendingRequest(requestID: "demo", kind: .approval(command: "systemctl restart hermes-gateway", description: "restart a service", choices: ["once", "session", "always", "deny"])))),
        ]
        t.todos = [TodoItem(id: "1", content: "Check gateway status", status: "completed"),
                   TodoItem(id: "2", content: "Read the last 200 log lines", status: "in_progress"),
                   TodoItem(id: "3", content: "Report back", status: "pending")]
        t.usage = nil
        transcripts["demo"] = t
        currentChat = "demo"
        let now = Date().timeIntervalSince1970
        sessions = [
            SessionSummary(["id": "demo", "title": "Server check", "preview": "Is the Telegram bot healthy?", "started_at": .number(now - 300), "message_count": 6, "source": "tui"]),
            SessionSummary(["id": "t1", "title": "Weekly report", "preview": "Summarise this week", "started_at": .number(now - 7200), "message_count": 12, "source": "telegram"]),
            SessionSummary(["id": "c1", "title": "Morning briefing", "preview": "Daily brief", "started_at": .number(now - 90_000), "message_count": 4, "source": "cron"]),
        ].compactMap { $0 }
    }
}
