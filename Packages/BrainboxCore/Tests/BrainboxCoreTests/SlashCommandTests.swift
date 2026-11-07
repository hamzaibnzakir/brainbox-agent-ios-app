import XCTest
@testable import BrainboxCore

final class SlashCommandTests: XCTestCase {
    // Shapes from the real catalog of hermes-agent 284d220 (subset).
    private let catalog = HermesCommandCatalog(
        native: [.init(name: "compress", description: "Compress the conversation context", aliases: ["compact"]),
                 .init(name: "steer", description: "Steer", argsHint: "<text>"),
                 .init(name: "skin", description: "Change the CLI theme", cliOnly: true),
                 .init(name: "yolo", description: "Toggle auto-approve"),
                 .init(name: "version", description: "Show Hermes Agent version", aliases: ["v"], busyPolicy: "dispatch", executor: true),
                 .init(name: "personality", description: "Set a predefined personality", argsHint: "[name]")],
        skills: [.init(name: "github-pr", description: "Review a GitHub PR"), .init(name: "demo-skill", description: "Demo")])

    func testRouting() {
        XCTAssertEqual(SlashCommandRouter.parse("hello there", catalog: catalog), .text("hello there"))
        XCTAssertEqual(SlashCommandRouter.parse("/etc/hosts looks wrong", catalog: catalog), .text("/etc/hosts looks wrong"))
        XCTAssertEqual(SlashCommandRouter.parse("//stop is a word", catalog: catalog), .text("/stop is a word"))
        XCTAssertEqual(SlashCommandRouter.parse("/stop", catalog: catalog), .app(.stop, argument: ""))
        XCTAssertEqual(SlashCommandRouter.parse("/Steer  focus on tests ", catalog: catalog), .app(.steer, argument: "focus on tests"))
        XCTAssertEqual(SlashCommandRouter.parse("/q then summarise", catalog: catalog), .app(.queue, argument: "then summarise"))
        XCTAssertEqual(SlashCommandRouter.parse("/reset", catalog: catalog), .app(.new, argument: ""))
        XCTAssertEqual(SlashCommandRouter.parse("/steer", catalog: catalog), .missingArgument(.steer))
        XCTAssertEqual(SlashCommandRouter.parse("/github_pr 123", catalog: catalog), .skill(name: "github-pr", instruction: "123"))
        XCTAssertEqual(SlashCommandRouter.parse("/compact", catalog: catalog),
                       .unavailable(name: "compress", description: "Compress the conversation context", cliOnly: false))
        XCTAssertEqual(SlashCommandRouter.parse("/stpo", catalog: catalog), .unknown(name: "stpo", suggestion: "stop"))
        // Hermes commands with a shared handler run through Hermes' own code.
        XCTAssertEqual(SlashCommandRouter.parse("/v", catalog: catalog), .hermes(name: "version", argument: ""))
        XCTAssertEqual(SlashCommandRouter.parse("/bg check disks", catalog: catalog), .app(.bg, argument: "check disks"))
        XCTAssertEqual(SlashCommandRouter.parse("/btw", catalog: catalog), .missingArgument(.btw))
        // Without the live catalog (no proxy), the bundled 284d220 registry still classifies
        // Hermes commands — never "no such command", never sent to the model.
        XCTAssertEqual(SlashCommandRouter.parse("/compress", catalog: nil),
                       .unavailable(name: "compress", description: HermesCommandCatalog.bundled.native.first { $0.name == "compress" }!.description, cliOnly: false))
        XCTAssertEqual(SlashCommandRouter.parse("/help", catalog: nil), .app(.help, argument: ""))
        XCTAssertEqual(SlashCommandRouter.parse("/commands", catalog: nil), .hermes(name: "commands", argument: ""))
        guard case .unknown = SlashCommandRouter.parse("/definitelynotacommand", catalog: nil) else { return XCTFail() }
    }

    func testExplanationsNeverClaimSending() {
        let unavailable = SlashCommandRouter.explanation(for: SlashCommandRouter.parse("/skin", catalog: catalog))!
        XCTAssertTrue(unavailable.contains("only works in the Hermes CLI"))
        XCTAssertTrue(unavailable.contains("Nothing was sent"))
        let telegramOnly = SlashCommandRouter.explanation(for: SlashCommandRouter.parse("/personality pirate", catalog: catalog))!
        XCTAssertTrue(telegramOnly.contains("Telegram") && telegramOnly.contains("Nothing was sent"))
        XCTAssertTrue(SlashCommandRouter.explanation(for: .unknown(name: "x", suggestion: nil))!.contains("//"))
        XCTAssertNil(SlashCommandRouter.explanation(for: .text("hi")))
    }

    func testSuggestions() {
        XCTAssertTrue(SlashCommandRouter.suggestions(for: "hi", catalog: catalog).isEmpty)
        XCTAssertTrue(SlashCommandRouter.suggestions(for: "/stop now", catalog: catalog).isEmpty, "closes once arguments start")
        let st = SlashCommandRouter.suggestions(for: "/st", catalog: catalog)
        XCTAssertEqual(Array(st.prefix(3)).map(\.name), ["status", "steer", "stop"])
        XCTAssertTrue(st.prefix(3).allSatisfy { $0.kind == .brainbox }, "Hermes' /steer is handled by Brainbox, listed once")
        XCTAssertEqual(st.filter { $0.name == "steer" }.count, 1)
        XCTAssertEqual(SlashCommandRouter.suggestions(for: "/gi", catalog: catalog).first?.kind, .skill)
        XCTAssertEqual(SlashCommandRouter.suggestions(for: "/yo", catalog: catalog).first?.kind, .unavailable)
        XCTAssertEqual(SlashCommandRouter.suggestions(for: "/v", catalog: catalog).first { $0.name == "version" }?.kind, .hermes)
        // Search reaches descriptions, so "/theme" finds /skin.
        XCTAssertTrue(SlashCommandRouter.suggestions(for: "/theme", catalog: catalog).contains { $0.name == "skin" })
        XCTAssertFalse(SlashCommandRouter.suggestions(for: "/", catalog: catalog).contains { $0.kind == .unavailable })
        XCTAssertEqual(CommandSuggestion(name: "steer", argsHint: "<x>", detail: "", kind: .brainbox).completion, "/steer ")
        XCTAssertEqual(CommandSuggestion(name: "stop", argsHint: "", detail: "", kind: .brainbox).completion, "/stop")
    }

    func testArgumentHelp() {
        let model = SlashCommandRouter.argumentHelp(for: "/model de", catalog: catalog)
        XCTAssertEqual(model?.options, ["default"])
        let reasoning = SlashCommandRouter.argumentHelp(for: "/reasoning o", catalog: nil)
        XCTAssertEqual(reasoning?.name, "reasoning")
        XCTAssertEqual(reasoning?.options, ["on", "off"])
        XCTAssertNil(SlashCommandRouter.argumentHelp(for: "/model", catalog: catalog), "no help before the space")
    }

    func testBundledRegistryCoversTheTelegramCommands() {
        let names = Set(HermesCommandCatalog.bundled.native.flatMap { [$0.name] + $0.aliases })
        for name in ["help", "status", "model", "stop", "new", "reset", "queue", "q", "steer", "bg", "btw", "approve", "deny"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertTrue(HermesCommandCatalog.bundled.native.contains { $0.name == "help" && $0.executor })
    }

    func testRunHermesCommandClient() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/brainbox/commands/run") { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
            XCTAssertEqual(body["name"]?.stringValue, "btw")
            XCTAssertEqual(body["session_id"]?.stringValue, "ios_abc")
            return MockHTTPTransport.json(#"{"name":"btw","text":"It was nginx.","format":"markdown","source":"hermes"}"#)
        }
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!),
                                     transport: transport, tokenProvider: { "t0123456789" })
        let reply = try await client.runHermesCommand(name: "btw", arguments: "what broke?", sessionID: "ios_abc")
        XCTAssertEqual(reply.text, "It was nginx.")
    }

    func testParallelSplit() {
        XCTAssertEqual(SlashCommandRouter.parallelTasks(" check disk | review logs || summarise "), ["check disk", "review logs", "summarise"])
    }

    func testCatalogDecodesProxyPayload() throws {
        let json = #"{"object":"brainbox.commands","api_runs_commands":false,"native":[{"name":"compress","description":"x","category":"Session","aliases":["compact"],"args_hint":"","cli_only":false,"gateway_only":false}],"skills":[{"name":"demo-skill","skill":"demo-skill","description":"Demo"}]}"#
        let decoded = try JSONDecoder().decode(HermesCommandCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.native.first?.aliases, ["compact"])
        XCTAssertEqual(decoded.skills.first?.name, "demo-skill")
    }

    func testSkillInvocationClient() async throws {
        let transport = MockHTTPTransport()
        transport.on("POST /hermes/brainbox/commands/skill") { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
            XCTAssertEqual(body["name"]?.stringValue, "demo-skill")
            return MockHTTPTransport.json(#"{"object":"brainbox.skill_invocation","name":"demo-skill","message":"[IMPORTANT: The user has invoked the \"demo-skill\" skill]"}"#)
        }
        transport.on("GET /hermes/brainbox/commands") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"Hermes' Python wasn't found","code":"hermes_python_missing"}}"#, status: 503)
        }
        let client = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!, profile: "research"),
                                     transport: transport, tokenProvider: { "t0123456789" })
        let message = try await client.skillInvocation(name: "demo-skill", instruction: "go")
        XCTAssertTrue(message.contains("invoked"))
        do { _ = try await client.commandCatalog(); XCTFail() } catch AgentError.remote(let code, _) {
            XCTAssertEqual(code, "hermes_python_missing")
        }
    }
}
