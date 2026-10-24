import XCTest
@testable import BrainboxCore

final class SlashCommandTests: XCTestCase {
    // Shapes from the real catalog of hermes-agent 284d220 (subset).
    private let catalog = HermesCommandCatalog(
        native: [.init(name: "compress", description: "Compress the conversation context", aliases: ["compact"]),
                 .init(name: "steer", description: "Steer", argsHint: "<text>"),
                 .init(name: "skin", description: "Change the CLI theme", cliOnly: true),
                 .init(name: "yolo", description: "Toggle auto-approve")],
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
        // Without a catalog (proxy unreachable), Hermes names are unknown — still never sent.
        XCTAssertEqual(SlashCommandRouter.parse("/compress", catalog: nil), .unknown(name: "compress", suggestion: nil))
    }

    func testExplanationsNeverClaimSending() {
        let unavailable = SlashCommandRouter.explanation(for: SlashCommandRouter.parse("/skin", catalog: catalog))!
        XCTAssertTrue(unavailable.contains("only works in the Hermes CLI"))
        XCTAssertTrue(unavailable.contains("nothing was sent"))
        XCTAssertTrue(SlashCommandRouter.explanation(for: .unknown(name: "x", suggestion: nil))!.contains("//"))
        XCTAssertNil(SlashCommandRouter.explanation(for: .text("hi")))
    }

    func testSuggestions() {
        XCTAssertTrue(SlashCommandRouter.suggestions(for: "hi", catalog: catalog).isEmpty)
        XCTAssertTrue(SlashCommandRouter.suggestions(for: "/stop now", catalog: catalog).isEmpty, "closes once arguments start")
        let st = SlashCommandRouter.suggestions(for: "/st", catalog: catalog)
        XCTAssertEqual(st.map(\.name), ["stop", "steer", "status"])
        XCTAssertTrue(st.allSatisfy { $0.kind == .brainbox }, "Hermes' /steer is handled by Brainbox, listed once")
        XCTAssertEqual(SlashCommandRouter.suggestions(for: "/gi", catalog: catalog).first?.kind, .skill)
        XCTAssertEqual(SlashCommandRouter.suggestions(for: "/yo", catalog: catalog).first?.kind, .unavailable)
        XCTAssertEqual(SlashCommandRouter.suggestions(for: "/", catalog: catalog).count, 8)
        XCTAssertEqual(CommandSuggestion(name: "steer", argsHint: "<x>", detail: "", kind: .brainbox).completion, "/steer ")
        XCTAssertEqual(CommandSuggestion(name: "stop", argsHint: "", detail: "", kind: .brainbox).completion, "/stop")
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
