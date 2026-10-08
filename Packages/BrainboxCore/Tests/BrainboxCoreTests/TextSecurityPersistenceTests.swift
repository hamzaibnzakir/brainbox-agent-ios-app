import Foundation
import XCTest
@testable import BrainboxCore

final class MarkdownParserTests: XCTestCase {
    func testParsesCommonBlocks() {
        let text = """
        # Title
        Some **bold** text
        continues here.

        - one
        - two
          wrapped

        1. first
        2. second

        > quoted

        ---
        ```yaml
        key: value
        ```
        """
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\ncontinues here."),
            .bulletList(["one", "two wrapped"]),
            .orderedList(start: 1, items: ["first", "second"]),
            .quote("quoted"),
            .rule,
            .code(language: "yaml", code: "key: value", isOpen: false)
        ])
    }

    func testUnterminatedFenceStreamsAsOpenCode() {
        let blocks = MarkdownParser.parse("Here:\n\n```python\nprint('hi')\nx = 1")
        XCTAssertEqual(blocks.last, .code(language: "python", code: "print('hi')\nx = 1", isOpen: true))
        XCTAssertEqual(MarkdownParser.codeBlocks(in: "a\n```\nb\n```"), ["b"])
    }

    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(MarkdownParser.parse("#hashtag"), [.paragraph("#hashtag")])
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    func testTokensReassembleExactlyForEveryLanguage() {
        let samples: [CodeLanguage: String] = [
            .yaml: "server:\n  listen: 100.64.0.10:8443 # tailscale\n  tls: true\n- name: \"x\"",
            .json: "{\n  \"a\": 1,\n  \"b\": [true, null, \"s\"]\n}",
            .jsonc: "{ // c\n \"a\": /* b */ 2 }",
            .python: "def f(x):\n    return x * 2  # double\nprint(f(3))",
            .shell: "#!/bin/bash\nexport A=1\necho \"$A ${HOME}\" # hi",
            .markdown: "# H\n- **b** `c`\n```\ncode\n```",
            .javascript: "const a = `t`; // x",
            .swift: "let x = 1 /* y */",
            .plainText: "plain"
        ]
        for (language, text) in samples {
            let tokens = SyntaxHighlighter.tokenize(text, language: language)
            XCTAssertEqual(tokens.map(\.text).joined(), text, language.rawValue)
        }
    }

    func testClassifiesTokens() {
        let yaml = SyntaxHighlighter.tokenize("tls: true # on", language: .yaml)
        XCTAssertTrue(yaml.contains(SyntaxToken("tls", .key)))
        XCTAssertTrue(yaml.contains(SyntaxToken("true", .keyword)))
        XCTAssertTrue(yaml.contains(SyntaxToken("# on", .comment)))

        let json = SyntaxHighlighter.tokenize("{\"port\": 8443}", language: .json)
        XCTAssertTrue(json.contains(SyntaxToken("\"port\"", .key)))
        XCTAssertTrue(json.contains(SyntaxToken("8443", .number)))

        let shell = SyntaxHighlighter.tokenize("echo $HOME", language: .shell)
        XCTAssertTrue(shell.contains(SyntaxToken("$HOME", .variable)))

        let python = SyntaxHighlighter.tokenize("url = 'a#b'", language: .python)
        XCTAssertFalse(python.contains { $0.kind == .comment }, "# inside a string is not a comment")
    }

    func testLanguageDetection() {
        XCTAssertEqual(CodeLanguage.detect(fileName: "gateway.YML"), .yaml)
        XCTAssertEqual(CodeLanguage.detect(fileName: "settings.jsonc"), .jsonc)
        XCTAssertEqual(CodeLanguage.detect(fileName: "deploy.sh"), .shell)
        XCTAssertEqual(CodeLanguage.detect(fileName: ".env"), .shell)
        XCTAssertEqual(CodeLanguage.detect(fileName: "README"), .plainText)
        XCTAssertEqual(CodeLanguage.fromFence("py"), .python)
    }
}

final class TextToolTests: XCTestCase {
    func testLineDiff() {
        let diff = LineDiff.diff(old: "a\nb\nc", new: "a\nB\nc\nd")
        XCTAssertEqual(diff.map(\.kind), [.unchanged, .added, .removed, .unchanged, .added])
        XCTAssertEqual(LineDiff.summary(diff), DiffSummary(added: 2, removed: 1))
        XCTAssertTrue(LineDiff.summary(LineDiff.diff(old: "same", new: "same")).isEmpty)
        XCTAssertEqual(LineDiff.hunks(LineDiff.diff(old: "same", new: "same")), [])
    }

    func testValidators() {
        XCTAssertTrue(ConfigValidator.validate("{\"a\": 1}", language: .json).isEmpty)
        XCTAssertFalse(ConfigValidator.validate("{\"a\": }", language: .json).isEmpty)
        XCTAssertFalse(ConfigValidator.validate("{\"a\": 1,}", language: .json).isEmpty)
        XCTAssertTrue(ConfigValidator.validate("{ // c\n\"a\": \"//x\" /* y */ }", language: .jsonc).isEmpty)
        XCTAssertEqual(ConfigValidator.validate("a:\n\tb: 1", language: .yaml).first?.line, 2)
        XCTAssertTrue(ConfigValidator.validate("a: 1\nb:\n  - c", language: .yaml).isEmpty)
        XCTAssertEqual(ConfigValidator.stripJSONComments("{\"u\": \"http://x\"} // c"), "{\"u\": \"http://x\"} ")
    }

    func testSearchAndReplace() {
        XCTAssertEqual(TextSearch.matches(of: "ab", in: "abAB ab").count, 3)
        let replaced = TextSearch.replaceAll("port", with: "listen", in: "port: 1\nPORT: 2")
        XCTAssertEqual(replaced.count, 2)
        XCTAssertEqual(replaced.text, "listen: 1\nlisten: 2")
        XCTAssertEqual(TextSearch.matches(of: "", in: "x").count, 0)
    }
}

final class SecurityTests: XCTestCase {
    func testBiometricPolicy() {
        let policy = SecurityPolicy(biometricsEnabled: true, gracePeriod: 60, sessionTimeout: 300)
        let now = Date()
        XCTAssertTrue(policy.requiresAuthentication(for: .openTerminal, lastAuthenticatedAt: nil, now: now))
        XCTAssertFalse(policy.requiresAuthentication(for: .openTerminal, lastAuthenticatedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(policy.requiresAuthentication(for: .openTerminal, lastAuthenticatedAt: now.addingTimeInterval(-90), now: now))
        XCTAssertTrue(policy.requiresAuthentication(for: .deleteFile, lastAuthenticatedAt: now, now: now), "Destructive actions always prompt")
        XCTAssertFalse(SecurityPolicy(biometricsEnabled: false).requiresAuthentication(for: .deleteFile, lastAuthenticatedAt: nil))

        XCTAssertTrue(policy.shouldLock(backgroundedAt: now.addingTimeInterval(-301), now: now))
        XCTAssertFalse(policy.shouldLock(backgroundedAt: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(SecurityPolicy(sessionTimeout: nil).shouldLock(backgroundedAt: .distantPast))
    }

    func testBackendURLValidation() {
        XCTAssertEqual(BackendURLValidator.validate("wss://brainbox.tail1234.ts.net/v1/agent"), .valid(URL(string: "wss://brainbox.tail1234.ts.net/v1/agent")!))
        if case .valid = BackendURLValidator.validate("ws://100.101.102.103:8443") {} else { XCTFail("Tailscale IP over ws should be allowed") }
        if case .invalid = BackendURLValidator.validate("ws://example.com") {} else { XCTFail("Public ws:// must be rejected") }
        if case .invalid = BackendURLValidator.validate("https://example.com") {} else { XCTFail("https is not a websocket") }
        if case .invalid = BackendURLValidator.validate("wss://user:pass@example.com") {} else { XCTFail("Credentials in URL must be rejected") }
        if case .invalid = BackendURLValidator.validate("") {} else { XCTFail() }
        XCTAssertTrue(BackendURLValidator.isPrivateHost("100.64.0.1"))
        XCTAssertFalse(BackendURLValidator.isPrivateHost("100.128.0.1"))
        XCTAssertTrue(BackendURLValidator.isPrivateHost("172.20.1.1"))
        XCTAssertFalse(BackendURLValidator.isPrivateHost("8.8.8.8"))
    }

    func testTokenValidation() {
        XCTAssertNotNil(TokenValidator.validate("short"))
        XCTAssertNotNil(TokenValidator.validate("has spaces in the middle of it"))
        XCTAssertNil(TokenValidator.validate("  abcdefghijklmnopqrstuvwxyz012345  "))
        XCTAssertEqual(TokenValidator.redacted("abcdefghijklmnop"), "••••••••mnop")
    }

    func testInMemoryCredentialStore() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.read(.gatewayToken))
        try store.write("secret-token-value", for: .gatewayToken)
        XCTAssertEqual(try store.read(.gatewayToken), "secret-token-value")
        try store.delete(.gatewayToken)
        XCTAssertNil(try store.read(.gatewayToken))
    }

    func testReconnectBackoff() {
        let policy = ReconnectPolicy(initialDelay: 0.5, multiplier: 2, maxDelay: 30, maxAttempts: 10, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 0.5)
        XCTAssertEqual(policy.delay(forAttempt: 2), 1)
        XCTAssertEqual(policy.delay(forAttempt: 4), 4)
        XCTAssertEqual(policy.delay(forAttempt: 10), 30)
        XCTAssertNil(policy.delay(forAttempt: 11))
        let jittered = ReconnectPolicy(initialDelay: 1, multiplier: 2, maxDelay: 30, jitter: 0.25)
        XCTAssertEqual(jittered.delay(forAttempt: 3, random: 0)!, 3, accuracy: 0.0001)
        XCTAssertEqual(jittered.delay(forAttempt: 3, random: 1)!, 5, accuracy: 0.0001)
    }

    func testTimeoutHelper() async {
        do {
            _ = try await Timeout.run(seconds: 0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error.asAgentError, .timedOut)
        }
        let value = try? await Timeout.run(seconds: 1) { 42 }
        XCTAssertEqual(value, 42)
    }
}

final class PersistenceTests: XCTestCase {
    private func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bb-tests-" + UUID().uuidString, isDirectory: true)
    }

    func testConversationStoreRoundTrip() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileConversationStore(directory: dir)
        XCTAssertEqual(try store.loadAll(), [])

        let call = ToolCall(id: "t", kind: .terminal, name: "terminal.run", title: "Run", input: "ls", status: .succeeded, result: ToolResult(output: "a", exitCode: 0))
        var older = Conversation(title: "Older", updatedAt: Date(timeIntervalSince1970: 100), providerKind: .mock, messages: [Message(role: .user, content: "hi")])
        let newer = Conversation(title: "Newer", updatedAt: Date(timeIntervalSince1970: 200), providerKind: .remote, messages: [
            Message(role: .assistant, content: "x", state: .failed(.permissionDenied(detail: "no")), toolCalls: [call])
        ])
        try store.save(older)
        try store.save(newer)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.title), ["Newer", "Older"])
        XCTAssertEqual(loaded.first?.messages.first?.state, .failed(.permissionDenied(detail: "no")))
        XCTAssertEqual(loaded.first?.messages.first?.toolCalls.first?.result?.output, "a")

        older.title = "Renamed"
        try store.save(older)
        XCTAssertEqual(try store.loadAll().count, 2)
        try store.delete(newer.id)
        XCTAssertEqual(try store.loadAll().map(\.title), ["Renamed"])
        try store.deleteAll()
        XCTAssertEqual(try store.loadAll(), [])
    }

    func testJSONFileCache() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = JSONFileCache<ServerSnapshot>(url: dir.appendingPathComponent("snapshot.json"))
        XCTAssertNil(cache.load())
        let info = ServerInfo(hostname: "h", operatingSystem: "os", kernel: "k", architecture: "a", cpuCores: 2, bootedAt: Date(timeIntervalSince1970: 1_000))
        let metrics = ServerMetrics(cpuUsage: 0.5, memoryUsedBytes: 1, memoryTotalBytes: 2, diskUsedBytes: 1, diskTotalBytes: 2, networkRxBytesPerSecond: 1, networkTxBytesPerSecond: 1, loadAverage: [0.1])
        cache.store(ServerSnapshot(info: info, metrics: metrics, services: [ServiceStatus(name: "x", summary: "y", state: .running)]))
        XCTAssertEqual(cache.load()?.info.hostname, "h")
        XCTAssertEqual(cache.load()?.services.first?.state, .running)
        cache.clear()
        XCTAssertNil(cache.load())
    }

    func testBroadcasterReplaysLatestToNewSubscribers() async throws {
        let broadcaster = Broadcaster<Int>(initial: 1)
        broadcaster.send(2)
        var iterator = broadcaster.subscribe().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, 2)
        broadcaster.send(3)
        let second = await iterator.next()
        XCTAssertEqual(second, 3)
    }
}
