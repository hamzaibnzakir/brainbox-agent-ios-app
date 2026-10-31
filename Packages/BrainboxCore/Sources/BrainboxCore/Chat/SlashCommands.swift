import Foundation

// Slash commands in the chat composer — routed, never sent to the model as text.
//
// Hermes' API server never interprets slash commands: `/v1/runs` passes `input` straight
// to the model (hermes-agent 284d220). Telegram's commands run inside Hermes' messaging
// gateway (`gateway/slash_commands*.py`) against its live session state, which the API
// doesn't expose. So each command typed here goes to the right place:
//
// * Brainbox commands — the Telegram equivalents performed through real API calls:
//   /stop, /steer, /queue, /new (/reset), /model, /status, /usage, /bg, /approve, /deny, …
// * Hermes commands with a shared handler (`hermes_cli.slash_exec`: /help, /commands,
//   /version, /profile, …) and /btw — run by Hermes' own code on the proxy.
// * Skill commands (`/<skill> …`) — Hermes builds the message from the skill files.
// * Other Hermes commands — recognised from Hermes' registry and refused with the reason
//   (CLI-only, or needs Telegram's live session). Unknown commands are an error.
// * `//text` sends "/text" literally.

/// Hermes' registry and skills (`GET /brainbox/commands`), or the bundled snapshot.
public struct HermesCommandCatalog: Decodable, Hashable, Sendable {
    public struct Native: Decodable, Hashable, Sendable {
        public var name: String
        public var description: String
        public var category: String
        public var aliases: [String]
        public var argsHint: String
        public var cliOnly: Bool
        public var subcommands: [String]
        public var gatewayOnly: Bool
        /// Mid-run behaviour in Telegram: "dispatch", "reject" or "interrupt_then_dispatch".
        public var busyPolicy: String
        /// Has a registry-owned handler the proxy can run (`slash_exec`).
        public var executor: Bool

        enum CodingKeys: String, CodingKey {
            case name, description, category, aliases, subcommands, executor
            case argsHint = "args_hint"
            case cliOnly = "cli_only"
            case gatewayOnly = "gateway_only"
            case busyPolicy = "busy_policy"
        }

        public init(name: String, description: String, category: String = "", aliases: [String] = [], argsHint: String = "",
                    cliOnly: Bool = false, subcommands: [String] = [], gatewayOnly: Bool = false, busyPolicy: String = "reject",
                    executor: Bool = false) {
            self.name = name
            self.description = description
            self.category = category
            self.aliases = aliases
            self.argsHint = argsHint
            self.cliOnly = cliOnly
            self.subcommands = subcommands
            self.gatewayOnly = gatewayOnly
            self.busyPolicy = busyPolicy
            self.executor = executor
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = (try? c.decode(String.self, forKey: .description)) ?? ""
            category = (try? c.decode(String.self, forKey: .category)) ?? ""
            aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
            argsHint = (try? c.decode(String.self, forKey: .argsHint)) ?? ""
            cliOnly = (try? c.decode(Bool.self, forKey: .cliOnly)) ?? false
            subcommands = (try? c.decode([String].self, forKey: .subcommands)) ?? []
            gatewayOnly = (try? c.decode(Bool.self, forKey: .gatewayOnly)) ?? false
            busyPolicy = (try? c.decode(String.self, forKey: .busyPolicy)) ?? "reject"
            executor = (try? c.decode(Bool.self, forKey: .executor)) ?? false
        }

        public func matches(_ name: String) -> Bool { self.name == name || aliases.contains(name) }
    }

    public struct Skill: Decodable, Hashable, Sendable {
        public var name: String
        public var description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
        enum CodingKeys: String, CodingKey { case name, description }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = (try? c.decode(String.self, forKey: .description)) ?? ""
        }
    }

    public var native: [Native]
    public var skills: [Skill]
    /// False for the bundled snapshot (skills unknown until the live list loads).
    public var isLive: Bool

    public init(native: [Native] = [], skills: [Skill] = [], isLive: Bool = true) {
        self.native = native
        self.skills = skills
        self.isLive = isLive
    }

    enum CodingKeys: String, CodingKey { case native, skills }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        native = (try? c.decode([Native].self, forKey: .native)) ?? []
        skills = (try? c.decode([Skill].self, forKey: .skills)) ?? []
        isLive = true
    }

    public static let bundled = HermesCommandCatalog(native: bundledRegistry, skills: [], isLive: false)

    /// Snapshot of `hermes_cli.commands.COMMAND_REGISTRY` from hermes-agent 284d220, used until
    /// the live registry loads (or when connected without the Brainbox proxy).
    public static let bundledRegistry: [Native] = [
        Native(name: "start", description: "Acknowledge platform start pings without a reply", category: "Session", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "dispatch", executor: false),
        Native(name: "new", description: "Start a new session (fresh session ID + history)", category: "Session", aliases: ["reset"], argsHint: "[name]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "interrupt_then_dispatch", executor: false),
        Native(name: "topic", description: "Enable or inspect Telegram DM topic sessions", category: "Session", aliases: [], argsHint: "[off|help|session-id]", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "reject", executor: false),
        Native(name: "clear", description: "Clear screen and start a new session", category: "Session", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "redraw", description: "Force a full UI repaint (recovers from terminal drift)", category: "Session", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "history", description: "Show conversation history", category: "Session", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "save", description: "Export the current conversation (bare /save shows usage)", category: "Session", aliases: [], argsHint: "<json|md|html> [filename] [redact]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "retry", description: "Retry the last message (resend to agent)", category: "Session", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "prompt", description: "Compose your next prompt in $EDITOR (markdown), then send it", category: "Session", aliases: ["compose"], argsHint: "[initial text]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "undo", description: "Back up N user turns and re-prompt (default 1)", category: "Session", aliases: [], argsHint: "[N]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "title", description: "Set a title for the current session", category: "Session", aliases: [], argsHint: "[name]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "handoff", description: "Hand off this session to a messaging platform (Telegram, Discord, etc.)", category: "Session", aliases: [], argsHint: "<platform>", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "branch", description: "Branch the current session (explore a different path)", category: "Session", aliases: ["fork"], argsHint: "[name]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "worktree", description: "Show, list, create, or prune isolated git worktrees", category: "Session", aliases: [], argsHint: "[new [name]|list|prune [--dry-run]]", cliOnly: true, subcommands: ["new", "list", "prune"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "compress", description: "Compress conversation context (add 'here [N]' to keep recent N turns; --preview shows what would happen)", category: "Session", aliases: ["compact"], argsHint: "[here [N] | focus topic | --preview|--dry-run]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "rollback", description: "List or restore filesystem checkpoints (restores keep your hand-edits; --all overrides)", category: "Session", aliases: [], argsHint: "[number] [--all]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "snapshot", description: "Create or restore state snapshots of Hermes config/state", category: "Session", aliases: ["snap"], argsHint: "[create|restore <id>|prune]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "export", description: "Export a profile (config, skills, theme) to a shareable archive", category: "Configuration", aliases: [], argsHint: "[profile] [-o output.tar.gz]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "import", description: "Import a shared profile archive as a new profile", category: "Configuration", aliases: [], argsHint: "<archive.tar.gz> [--name <name>]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "stop", description: "Kill all running background processes", category: "Session", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "interrupt_then_dispatch", executor: false),
        Native(name: "pause", description: "Pause new work globally (emergency stop); '/pause off' resumes", category: "Session", aliases: [], argsHint: "[reason | off]", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "dispatch", executor: false),
        Native(name: "approve", description: "Approve a pending dangerous command", category: "Session", aliases: [], argsHint: "[session|always]", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "dispatch", executor: false),
        Native(name: "deny", description: "Deny a pending dangerous command (optionally with a reason)", category: "Session", aliases: [], argsHint: "[all] [reason]", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "dispatch", executor: false),
        Native(name: "bg", description: "Run a prompt in a separate background session", category: "Session", aliases: [], argsHint: "<prompt>", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "btw", description: "Ask a side question about the current conversation without interrupting it", category: "Session", aliases: [], argsHint: "<question>", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "agents", description: "Show active agents and running tasks", category: "Session", aliases: ["tasks"], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "journey", description: "Open the learning journey timeline", category: "Session", aliases: ["learning", "memory-graph"], argsHint: "[list|delete <id>|edit <id>]", cliOnly: true, subcommands: ["list", "delete", "edit"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "queue", description: "Queue a prompt for the next turn (doesn't interrupt)", category: "Session", aliases: ["q"], argsHint: "<prompt>", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "steer", description: "Inject a message after the next tool call without interrupting", category: "Session", aliases: [], argsHint: "<prompt>", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "goal", description: "Set a standing goal Hermes works on across turns until achieved", category: "Session", aliases: [], argsHint: "[text | draft <text> | show | gate add <cmd> | pause | resume | clear | status | wait <pid> | unwait]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "heartbeat", description: "Set a recurring prompt that re-enters this session when idle", category: "Session", aliases: ["hb"], argsHint: "[every <interval> <prompt> | status | pause | resume | clear]", cliOnly: false, subcommands: ["status", "pause", "resume", "clear"], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "refine", description: "Review this conversation now and save lessons to memory/skills", category: "Session", aliases: [], argsHint: "[focus instructions]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "review", description: "Spawn an independent subagent to review the work just discussed (PR, code, docs)", category: "Session", aliases: [], argsHint: "[review instructions]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "loop", description: "Re-run a prompt on a recurring interval in this session", category: "Session", aliases: ["proactive"], argsHint: "[interval] <prompt> [--times N] [--until <condition>] | status | pause | resume | stop", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "plan", description: "Write a markdown implementation plan to .hermes/plans/ without executing anything", category: "Session", aliases: [], argsHint: "[task]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "moa", description: "Run one prompt through the default Mixture of Agents preset, then restore your model", category: "Session", aliases: [], argsHint: "<prompt>", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "subgoal", description: "Add or manage extra criteria on the active goal", category: "Session", aliases: [], argsHint: "[text | remove N | clear]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "status", description: "Show session, model, token, and context info", category: "Session", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "egress", description: "Show Docker egress proxy status", category: "Session", aliases: [], argsHint: "[status]", cliOnly: false, subcommands: ["status"], gatewayOnly: false, busyPolicy: "dispatch", executor: true),
        Native(name: "context", description: "Show detailed context window view with usage gauge, category breakdown, compression stats, and throughput", category: "Session", aliases: ["ctx"], argsHint: "[all]", cliOnly: false, subcommands: ["all"], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "whoami", description: "Show your slash command access (admin / user)", category: "Info", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "profile", description: "Show active profile name and home directory", category: "Info", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: true),
        Native(name: "sethome", description: "Set this chat as the home channel", category: "Session", aliases: ["set-home"], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "reject", executor: false),
        Native(name: "resume", description: "Resume a previously-named session", category: "Session", aliases: [], argsHint: "[name]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "sessions", description: "Browse and resume previous sessions", category: "Session", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "config", description: "Show current configuration", category: "Configuration", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "model", description: "Switch model (session-scoped; --global to persist)", category: "Configuration", aliases: [], argsHint: "[model] [--provider name] [--global|--session] [--refresh]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "codex-runtime", description: "Toggle codex app-server runtime for OpenAI/Codex models", category: "Configuration", aliases: ["codex_runtime"], argsHint: "[auto|codex_app_server]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "personality", description: "Set a predefined personality", category: "Configuration", aliases: [], argsHint: "[name]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "statusbar", description: "Toggle the context/model status bar", category: "Configuration", aliases: ["sb"], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "battery", description: "Toggle a color-coded battery indicator in the status bar", category: "Configuration", aliases: [], argsHint: "[on|off|status]", cliOnly: true, subcommands: ["on", "off", "status"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "timestamps", description: "Toggle [HH:MM] timestamps on messages and /history", category: "Configuration", aliases: ["ts"], argsHint: "[on|off|status]", cliOnly: true, subcommands: ["on", "off", "status"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "diff", description: "Show git changes in the working directory", category: "Info", aliases: [], argsHint: "[staged|all|session] [--stat] [path...]", cliOnly: false, subcommands: ["staged", "all", "session"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "verbose", description: "Cycle tool progress display: off -> new -> all -> verbose", category: "Configuration", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "focus", description: "Toggle focus view — show only your prompt and the final response", category: "Configuration", aliases: [], argsHint: "[on|off|status]", cliOnly: true, subcommands: ["on", "off", "status"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "footer", description: "Toggle gateway runtime-metadata footer on final replies", category: "Configuration", aliases: [], argsHint: "[on|off|status]", cliOnly: false, subcommands: ["on", "off", "status"], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "yolo", description: "Toggle YOLO mode (skip all dangerous command approvals)", category: "Configuration", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "approvals", description: "Show or set the persistent dangerous-command approval mode", category: "Configuration", aliases: [], argsHint: "[manual|smart|off]", cliOnly: false, subcommands: ["manual", "smart", "off"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "reasoning", description: "Manage reasoning effort and display", category: "Configuration", aliases: [], argsHint: "[level|show|hide|full|clamp] [--global]", cliOnly: false, subcommands: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "show", "hide", "on", "off", "full", "clamp", "--global"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "fast", description: "Fast mode — OpenAI Priority Processing / Anthropic Fast Mode (normal/fast/auto/cold)", category: "Configuration", aliases: [], argsHint: "[normal|fast|auto|cold|status] [--global]", cliOnly: false, subcommands: ["normal", "fast", "auto", "cold", "status", "on", "off", "--global"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "skin", description: "Show or change the display skin/theme", category: "Configuration", aliases: [], argsHint: "[name]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "indicator", description: "Pick the TUI busy-indicator style", category: "Configuration", aliases: [], argsHint: "[ascii|emoji|kaomoji|unicode]", cliOnly: true, subcommands: ["ascii", "emoji", "kaomoji", "unicode"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "voice", description: "Toggle voice mode", category: "Configuration", aliases: [], argsHint: "[on|off|tts|status]", cliOnly: false, subcommands: ["on", "off", "tts", "status"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "wake", description: "Toggle the 'Hey Hermes' wake word listener", category: "Configuration", aliases: [], argsHint: "[on|off|status]", cliOnly: true, subcommands: ["on", "off", "status"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "busy", description: "Control how messages behave while Hermes is working", category: "Configuration", aliases: [], argsHint: "[queue|steer|interrupt|status]", cliOnly: false, subcommands: ["queue", "steer", "interrupt", "status"], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "tools", description: "Manage tools: /tools [list|disable|enable] [name...]", category: "Tools & Skills", aliases: [], argsHint: "[list|disable|enable] [name...]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "toolsets", description: "List available toolsets", category: "Tools & Skills", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "skills", description: "Search, install, inspect, or manage skills", category: "Tools & Skills", aliases: [], argsHint: "", cliOnly: true, subcommands: ["search", "browse", "inspect", "install", "audit", "pending", "approve", "reject", "diff", "approval"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "memory", description: "Review pending memory writes / toggle the approval gate", category: "Tools & Skills", aliases: [], argsHint: "[pending|approve|reject|approval] [id|on|off]", cliOnly: false, subcommands: ["pending", "approve", "reject", "approval"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "bundles", description: "List skill bundles (aliases /<name> for multiple skills)", category: "Tools & Skills", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: true),
        Native(name: "pet", description: "Toggle or adopt a petdex mascot (/pet, /pet list, /pet <slug>)", category: "Tools & Skills", aliases: [], argsHint: "[toggle|list|scale <n>|<slug>]", cliOnly: true, subcommands: ["toggle", "list", "scale", "off"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "hatch", description: "Generate a new petdex pet from a description", category: "Tools & Skills", aliases: ["generate-pet"], argsHint: "[description]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "learn", description: "Learn a reusable skill from anything you describe (dirs, URLs, this chat, notes)", category: "Tools & Skills", aliases: [], argsHint: "<what to learn from>", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "init", description: "Generate or update AGENTS.md project instructions from a repo scan", category: "Tools & Skills", aliases: [], argsHint: "[notes]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "cron", description: "Manage scheduled tasks", category: "Tools & Skills", aliases: [], argsHint: "[subcommand]", cliOnly: true, subcommands: ["list", "add", "create", "edit", "pause", "resume", "run", "remove"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "suggestions", description: "Review suggested automations (accept/dismiss)", category: "Tools & Skills", aliases: ["suggest"], argsHint: "[accept|dismiss N | catalog]", cliOnly: false, subcommands: ["accept", "dismiss", "catalog", "clear"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "blueprint", description: "Set up an automation from a blueprint template", category: "Tools & Skills", aliases: ["bp"], argsHint: "[name] [slot=value ...]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "curator", description: "Background skill maintenance (status, run, pin, archive, list-archived)", category: "Tools & Skills", aliases: [], argsHint: "[subcommand]", cliOnly: false, subcommands: ["status", "run", "pause", "resume", "pin", "unpin", "restore", "list-archived"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "kanban", description: "Multi-profile collaboration board (tasks, links, comments)", category: "Tools & Skills", aliases: [], argsHint: "[subcommand]", cliOnly: false, subcommands: ["init", "boards", "create", "list", "ls", "show", "assign", "reclaim", "reassign", "diagnostics", "diag", "link", "unlink", "claim", "comment", "complete", "edit", "block", "unblock", "archive", "tail", "dispatch", "stats", "notify-subscribe", "notify-list", "notify-unsubscribe", "log", "runs", "heartbeat", "assignees", "context", "specify", "gc"], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "reload", description: "Reload .env variables into the running session", category: "Tools & Skills", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "reload-mcp", description: "Reload MCP servers from config", category: "Tools & Skills", aliases: ["reload_mcp"], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "reload-skills", description: "Re-scan ~/.hermes/skills/ for newly installed or removed skills", category: "Tools & Skills", aliases: ["reload_skills"], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "browser", description: "Connect browser tools to your live Chromium-family browser via CDP, or switch to Browser Use mode", category: "Tools & Skills", aliases: [], argsHint: "[connect|disconnect|status|use]", cliOnly: true, subcommands: ["connect", "disconnect", "status", "use"], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "plugins", description: "List installed plugins and their status", category: "Tools & Skills", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "commands", description: "Browse all commands and skills (paginated)", category: "Info", aliases: [], argsHint: "[page]", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "dispatch", executor: true),
        Native(name: "help", description: "Show available commands (/help skills lists skill commands, /help <text> filters)", category: "Info", aliases: [], argsHint: "[skills|<filter>]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: true),
        Native(name: "palette", description: "Open the fuzzy command palette (also Ctrl+P)", category: "Info", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "restart", description: "Gracefully restart the gateway after draining active runs", category: "Session", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "dispatch", executor: false),
        Native(name: "usage", description: "Show token usage and rate limits; `reset` redeems a banked Codex limit reset", category: "Info", aliases: [], argsHint: "[reset [--force]]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "subscription", description: "View your Nous plan and change it in the browser", category: "Info", aliases: ["upgrade"], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "login", description: "Sign in with a Nous account (keeps your connectors)", category: "Info", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "topup", description: "Show your Nous balance and manage billing on the portal", category: "Info", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "insights", description: "Show usage insights and analytics", category: "Info", aliases: [], argsHint: "[days]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "platforms", description: "Show gateway/messaging platform status", category: "Info", aliases: ["gateway"], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "platform", description: "Pause, resume, or list a failing gateway platform", category: "Info", aliases: [], argsHint: "<pause|resume|list> [name]", cliOnly: false, subcommands: [], gatewayOnly: true, busyPolicy: "reject", executor: false),
        Native(name: "copy", description: "Copy the last assistant response to clipboard", category: "Info", aliases: [], argsHint: "[number]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "paste", description: "Attach clipboard image from your clipboard", category: "Info", aliases: [], argsHint: "", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "image", description: "Attach a local image file for your next prompt", category: "Info", aliases: [], argsHint: "<path>", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "update", description: "Update Hermes Agent to the latest version", category: "Info", aliases: [], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: false),
        Native(name: "version", description: "Show Hermes Agent version", category: "Info", aliases: ["v"], argsHint: "", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "dispatch", executor: true),
        Native(name: "debug", description: "Upload debug report (system info + logs) and get shareable links", category: "Info", aliases: [], argsHint: "[nous|local]", cliOnly: false, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
        Native(name: "quit", description: "Exit the CLI (use --delete to also remove session history)", category: "Exit", aliases: ["exit"], argsHint: "[--delete]", cliOnly: true, subcommands: [], gatewayOnly: false, busyPolicy: "reject", executor: false),
    ]
}

/// Commands Brainbox performs itself, each the Telegram equivalent done through real API calls.
public enum AppCommand: String, CaseIterable, Sendable {
    case new, stop, steer, queue, bg, btw, retry, title, model, approve, deny, status, usage
    case agents, sessions, skills, help, archive, files, terminal, parallel

    public var aliases: [String] {
        switch self {
        case .new: return ["reset"]
        case .queue: return ["q"]
        case .bg: return ["background"]
        case .agents: return ["tasks"]
        default: return []
        }
    }

    public var argsHint: String {
        switch self {
        case .steer, .queue, .bg: return "<prompt>"
        case .btw: return "<question>"
        case .title: return "<name>"
        case .model: return "[model | default]"
        case .parallel: return "<task> | <task> | …"
        default: return ""
        }
    }

    public var requiresArgument: Bool { [.steer, .queue, .bg, .btw, .title, .parallel].contains(self) }

    public var summary: String {
        switch self {
        case .new: return "Start a new chat (fresh Hermes session)"
        case .stop: return "Stop the running reply (waits for Hermes to confirm)"
        case .steer: return "Inject guidance after the agent's next tool call, without stopping it"
        case .queue: return "Queue a prompt for after the current reply"
        case .bg: return "Run a prompt in a separate background session; the result comes back here"
        case .btw: return "Ask a side question about this chat without touching its history"
        case .retry: return "Run the last message again"
        case .title: return "Rename this chat (here and on Hermes)"
        case .model: return "Choose the model for this chat, or list models"
        case .approve: return "Approve the action the agent is waiting on (once)"
        case .deny: return "Deny the action the agent is waiting on"
        case .status: return "Session, model, tokens and run status"
        case .usage: return "Token usage and cost for this chat"
        case .agents: return "Open the Agent Workspace"
        case .sessions: return "Browse all Hermes sessions"
        case .skills: return "List the skills Hermes has"
        case .help: return "Hermes' command list, plus what runs here"
        case .archive: return "Archive this chat"
        case .files: return "Open the server's Brainbox files"
        case .terminal: return "Open the VPS terminal"
        case .parallel: return "Run several tasks as independent agents at once"
        }
    }

    /// Safe while a reply is running (Telegram's busy_policy "dispatch").
    public var worksWhileBusy: Bool {
        switch self {
        case .stop, .steer, .queue, .bg, .btw, .status, .usage, .approve, .deny, .help, .agents, .sessions, .skills, .files, .terminal, .parallel, .new:
            return true
        case .retry, .title, .model, .archive:
            return false
        }
    }
}

public enum ParsedCommand: Equatable, Sendable {
    /// Plain text for the agent (including `//escaped` text, already unescaped).
    case text(String)
    case app(AppCommand, argument: String)
    /// A Hermes command with a shared handler the proxy runs with Hermes' own code.
    case hermes(name: String, argument: String)
    case skill(name: String, instruction: String)
    /// A real Hermes command the API can't run.
    case unavailable(name: String, description: String, cliOnly: Bool)
    case missingArgument(AppCommand)
    case unknown(name: String, suggestion: String?)
}

public struct CommandSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case brainbox, hermes, skill, unavailable }
    public var name: String
    public var argsHint: String
    public var detail: String
    public var kind: Kind
    public var aliases: [String]
    public var id: String { "\(kind)-\(name)" }

    public init(name: String, argsHint: String, detail: String, kind: Kind, aliases: [String] = []) {
        self.name = name
        self.argsHint = argsHint
        self.detail = detail
        self.kind = kind
        self.aliases = aliases
    }

    /// What the composer becomes when the suggestion is picked.
    public var completion: String { "/\(name)" + (argsHint.isEmpty && kind != .skill ? "" : " ") }

    public var badge: String {
        switch kind {
        case .brainbox: return "APP"
        case .hermes: return "HERMES"
        case .skill: return "SKILL"
        case .unavailable: return "CLI/TELEGRAM"
        }
    }
}

/// Argument help shown while typing a command's arguments.
public struct CommandArgumentHelp: Hashable, Sendable {
    public var name: String
    public var argsHint: String
    public var summary: String
    /// Subcommands / choices matching what's typed so far.
    public var options: [String]
}

public enum SlashCommandRouter {
    private static let nameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))

    /// `/name rest…` → (name, rest); nil when the text isn't shaped like a command
    /// (e.g. "/etc/hosts is broken" — the first token contains another slash).
    static func split(_ text: String) -> (name: String, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") else { return nil }
        let body = trimmed.dropFirst()
        let token = body.prefix { !$0.isWhitespace }
        guard !token.isEmpty, token.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else { return nil }
        let argument = body.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (token.lowercased(), argument)
    }

    public static func appCommand(named name: String) -> AppCommand? {
        AppCommand.allCases.first { $0.rawValue == name || $0.aliases.contains(name) }
    }

    /// The live catalog when loaded, else the bundled registry (skills unknown then).
    static func effective(_ catalog: HermesCommandCatalog?) -> HermesCommandCatalog { catalog ?? .bundled }

    public static func parse(_ text: String, catalog: HermesCommandCatalog?) -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") { return .text(String(trimmed.dropFirst())) }
        guard let parts = split(trimmed) else { return .text(trimmed) }
        let name = parts.name
        let argument = parts.argument
        if let command = appCommand(named: name) {
            if command.requiresArgument && argument.isEmpty { return .missingArgument(command) }
            return .app(command, argument: argument)
        }
        let registry = effective(catalog)
        let skillKey = name.replacingOccurrences(of: "_", with: "-")
        if let skill = registry.skills.first(where: { $0.name == skillKey }) {
            return .skill(name: skill.name, instruction: argument)
        }
        if let native = registry.native.first(where: { $0.matches(name) }) {
            if native.executor && !native.cliOnly { return .hermes(name: native.name, argument: argument) }
            return .unavailable(name: native.name, description: native.description, cliOnly: native.cliOnly)
        }
        return .unknown(name: name, suggestion: closest(to: name, catalog: registry))
    }

    /// Searchable picker: name/alias prefix first, then substring, then description.
    public static func suggestions(for text: String, catalog: HermesCommandCatalog?, limit: Int = 40) -> [CommandSuggestion] {
        guard text.hasPrefix("/"), !text.hasPrefix("//"), !text.contains(" "), !text.contains("\n") else { return [] }
        let query = String(text.dropFirst()).lowercased()
        let registry = effective(catalog)
        var all: [CommandSuggestion] = AppCommand.allCases.map {
            CommandSuggestion(name: $0.rawValue, argsHint: $0.argsHint, detail: $0.summary, kind: .brainbox, aliases: $0.aliases)
        }
        let taken = Set(AppCommand.allCases.flatMap { [$0.rawValue] + $0.aliases })
        for native in registry.native where !taken.contains(native.name) {
            let runnable = native.executor && !native.cliOnly
            let detail = runnable ? native.description
                : native.description + (native.cliOnly ? " — Hermes CLI only" : " — needs Telegram's live session")
            all.append(CommandSuggestion(name: native.name, argsHint: native.argsHint, detail: detail,
                                         kind: runnable ? .hermes : .unavailable, aliases: native.aliases))
        }
        for skill in registry.skills {
            all.append(CommandSuggestion(name: skill.name, argsHint: "[instruction]", detail: skill.description, kind: .skill))
        }
        guard !query.isEmpty else {
            return Array(all.filter { $0.kind != .unavailable }.prefix(limit))
        }
        let skillQuery = query.replacingOccurrences(of: "_", with: "-")
        func rank(_ s: CommandSuggestion) -> Int? {
            let names = [s.name] + s.aliases
            if names.contains(query) || s.name == skillQuery { return 0 }
            if names.contains(where: { $0.hasPrefix(query) }) || s.name.hasPrefix(skillQuery) { return 1 }
            if names.contains(where: { $0.contains(query) }) { return 2 }
            if query.count >= 3, s.detail.lowercased().contains(query) { return 3 }
            return nil
        }
        let kindOrder: [CommandSuggestion.Kind: Int] = [.brainbox: 0, .hermes: 1, .skill: 2, .unavailable: 3]
        let ranked = all.compactMap { s in rank(s).map { (s, $0) } }
            .sorted { ($0.1, kindOrder[$0.0.kind] ?? 9, $0.0.name) < ($1.1, kindOrder[$1.0.kind] ?? 9, $1.0.name) }
        return Array(ranked.map(\.0).prefix(limit))
    }

    /// While typing arguments (`/model gp…`): the command's hint and matching choices.
    public static func argumentHelp(for text: String, catalog: HermesCommandCatalog?) -> CommandArgumentHelp? {
        guard text.hasPrefix("/"), !text.hasPrefix("//"), let space = text.firstIndex(of: " ") else { return nil }
        let name = String(text[text.index(after: text.startIndex)..<space]).lowercased()
        let typed = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces).lowercased()
        if let command = appCommand(named: name) {
            let options: [String] = command == .model ? ["default"] : []
            return CommandArgumentHelp(name: command.rawValue, argsHint: command.argsHint, summary: command.summary,
                                       options: options.filter { typed.isEmpty || $0.hasPrefix(typed) })
        }
        let registry = effective(catalog)
        if let skill = registry.skills.first(where: { $0.name == name.replacingOccurrences(of: "_", with: "-") }) {
            return CommandArgumentHelp(name: skill.name, argsHint: "[instruction]", summary: skill.description, options: [])
        }
        if let native = registry.native.first(where: { $0.matches(name) }) {
            return CommandArgumentHelp(name: native.name, argsHint: native.argsHint, summary: native.description,
                                       options: native.subcommands.filter { typed.isEmpty || $0.hasPrefix(typed) })
        }
        return nil
    }

    /// Nearest command name (edit distance ≤ 2) for "did you mean".
    static func closest(to name: String, catalog: HermesCommandCatalog) -> String? {
        var candidates = AppCommand.allCases.map(\.rawValue)
        candidates += catalog.native.filter { !$0.cliOnly }.map(\.name)
        candidates += catalog.skills.map(\.name)
        let scored = candidates.map { ($0, distance(name, $0)) }.filter { $0.1 <= 2 }
        return scored.min { $0.1 < $1.1 }?.0
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// The error shown for commands that can't run, without sending anything.
    public static func explanation(for parsed: ParsedCommand, catalogIsLive: Bool = true) -> String? {
        switch parsed {
        case .unavailable(let name, let description, let cliOnly):
            let what = description.isEmpty ? "Hermes command" : description
            if cliOnly {
                return "/\(name) (\(what)) only works in the Hermes CLI. Nothing was sent."
            }
            return "/\(name) (\(what)) runs inside Hermes' Telegram gateway against its live session, and Hermes' API doesn't expose it. Nothing was sent — use it in Telegram."
        case .missingArgument(let command):
            let example: String
            switch command {
            case .title: example = "Trip plan"
            case .btw: example = "what did we decide about nginx?"
            case .bg: example = "summarise today's logs"
            default: example = "focus on the failing test"
            }
            return "/\(command.rawValue) needs \(command.argsHint) — e.g. /\(command.rawValue) \(example)."
        case .unknown(let name, let suggestion):
            let hint = suggestion.map { " Did you mean /\($0)?" } ?? ""
            let skills = catalogIsLive ? "" : " (Hermes' skill list hasn't loaded, so skill commands can't be recognised yet.)"
            return "There's no /\(name) command.\(hint)\(skills) Type / to search commands, or start with // to send text that begins with a slash."
        default:
            return nil
        }
    }

    /// `/parallel a | b | c` → ["a", "b", "c"] (empty parts dropped).
    public static func parallelTasks(_ argument: String) -> [String] {
        argument.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// A command Hermes ran with its own handler (`POST /brainbox/commands/run`).
public struct HermesCommandReply: Decodable, Hashable, Sendable {
    public var name: String
    public var text: String
    public var format: String
}

extension HermesAPIClient {
    /// Hermes' command registry and skill commands, via the Brainbox proxy.
    public func commandCatalog() async throws -> HermesCommandCatalog {
        let request = authorizedRequest("GET", "/brainbox/commands", extraHeaders: ["Accept": "application/json"], timeout: 30)
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        return try decode(HermesCommandCatalog.self, from: response)
    }

    /// The message Hermes builds for `/<skill> <instruction>` (sent as the run input).
    public func skillInvocation(name: String, instruction: String) async throws -> String {
        var request = authorizedRequest("POST", "/brainbox/commands/skill", extraHeaders: ["Content-Type": "application/json", "Accept": "application/json"], timeout: 30)
        request.body = try JSONEncoder().encode(JSONValue.object(["name": .string(name), "instruction": .string(instruction)]))
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        let json = try JSONDecoder().decode(JSONValue.self, from: response.body)
        guard let message = json["message"]?.stringValue, !message.isEmpty else {
            throw AgentError.protocolViolation(detail: "Hermes returned an empty skill message.")
        }
        return message
    }

    /// Runs a Hermes command with Hermes' own handler on the proxy (registry executors, /btw).
    public func runHermesCommand(name: String, arguments: String, sessionID: String? = nil) async throws -> HermesCommandReply {
        var request = authorizedRequest("POST", "/brainbox/commands/run",
                                        extraHeaders: ["Content-Type": "application/json", "Accept": "application/json"],
                                        timeout: name == "btw" ? 240 : 60)
        var body: [String: JSONValue] = ["name": .string(name), "args": .string(arguments)]
        if let sessionID { body["session_id"] = .string(sessionID) }
        request.body = try JSONEncoder().encode(JSONValue.object(body))
        let response = try await send(request)
        guard (200..<300).contains(response.status) else { throw Self.sessionError(response) }
        return try decode(HermesCommandReply.self, from: response)
    }
}
