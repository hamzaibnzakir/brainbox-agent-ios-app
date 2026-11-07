import XCTest
@testable import BrainboxCore

/// Brainbox proxy endpoints: overview, files, terminal frames, push, deep links.
/// Synthetic payloads in the proxy's shapes; nothing talks to a real server.
final class ServerFeaturesTests: XCTestCase {
    private func client(_ transport: MockHTTPTransport, profile: String? = nil) -> HermesAPIClient {
        HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!, profile: profile),
                        transport: transport, tokenProvider: { "device-token-0123456789" })
    }

    func testFeaturesAndOverviewDecode() async throws {
        let info = try JSONDecoder().decode(BrainboxGatewayInfo.self, from: Data(#"{"service":"brainbox-hermes-proxy","features":{"chat_management":true,"files":true,"diagnostics":true,"terminal":false,"push":{"enabled":true,"ready":false}}}"#.utf8))
        XCTAssertEqual(info.features?.files, true)
        XCTAssertEqual(info.features?.push, .init(enabled: true, ready: false))
        let old = try JSONDecoder().decode(BrainboxGatewayInfo.self, from: Data(#"{"service":"brainbox-hermes-proxy"}"#.utf8))
        XCTAssertNil(old.features, "older proxies: features unknown, not assumed")

        let transport = MockHTTPTransport()
        transport.on("GET /hermes/brainbox/system") { _ in
            MockHTTPTransport.json(#"{"object":"brainbox.system","host":{"hostname":"vps","uptime_seconds":3600,"load_average":[0.1,0.2,0.3],"cpu_count":2,"memory":{"total_bytes":4000,"available_bytes":1000},"disks":[{"path":"/","total_bytes":100,"used_bytes":25,"free_bytes":75}]},"hermes":{"reachable":false,"http_status":null,"latency_ms":null,"status":null,"key_configured":true},"proxy":{"version":"0.1.0","uptime_seconds":10}}"#)
        }
        // A profile-routed client still reaches the proxy root.
        let overview = try await client(transport, profile: "research").systemOverview()
        XCTAssertEqual(overview.host.memory?.usedFraction ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(overview.host.disks.first?.usedFraction ?? 0, 0.25, accuracy: 0.001)
        XCTAssertFalse(overview.hermes.reachable)
        XCTAssertNil(overview.hermes.latencyMs)
        XCTAssertEqual(transport.requests.first?.url.path, "/hermes/brainbox/system")
    }

    func testWorkspaceListUploadAndErrors() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/brainbox/files") { request in
            XCTAssertEqual(request.url.query, "path=inbox")
            return MockHTTPTransport.json(#"{"object":"list","path":"inbox","data":[{"name":"a.png","path":"inbox/a.png","kind":"file","size":12,"modified":1,"mime":"image/png"}],"max_upload_bytes":1000,"allowed_extensions":["png"]}"#)
        }
        transport.on("POST /hermes/brainbox/files/upload") { request in
            XCTAssertEqual(request.headers["Content-Type"], "application/octet-stream")
            XCTAssertEqual(request.body, Data("hi".utf8))
            return MockHTTPTransport.json(#"{"object":"brainbox.file","file":{"name":"n.txt","path":"inbox/n.txt","kind":"file","size":2},"absolute_path":"/var/lib/brainbox-gateway/workspace/inbox/n.txt"}"#, status: 201)
        }
        transport.on("DELETE /hermes/brainbox/files") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"Paths must start with inbox/ or outbox/.","code":"invalid_path"}}"#, status: 400)
        }
        let api = client(transport)
        let listing = try await api.workspaceList(path: "inbox")
        XCTAssertEqual(listing.entries.first?.isImage, true)
        XCTAssertEqual(listing.allowedExtensions, ["png"])
        let upload = try await api.workspaceUpload(name: "n.txt", data: Data("hi".utf8))
        XCTAssertEqual(upload.absolutePath, "/var/lib/brainbox-gateway/workspace/inbox/n.txt")
        do { try await api.workspaceDelete(path: "../x"); XCTFail() } catch AgentError.remote(let code, let message) {
            XCTAssertEqual(code, "invalid_path")
            XCTAssertTrue(message.contains("inbox/"))
        }
    }

    func testWorkspacePolicy() {
        XCTAssertEqual(WorkspacePolicy.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(WorkspacePolicy.safeName("C:\\Users\\me\\Photo 1.JPG"), "Photo 1.JPG")
        XCTAssertEqual(WorkspacePolicy.safeName(".env"), "env")
        XCTAssertEqual(WorkspacePolicy.safeName("a;b$(c).txt"), "a_b_(c).txt")
        XCTAssertNil(WorkspacePolicy.safeName(".."))
        XCTAssertNil(WorkspacePolicy.safeName(""))
        XCTAssertEqual(try WorkspacePolicy.check(name: "IMG_1.HEIC", size: 10).get(), "IMG_1.HEIC")
        XCTAssertEqual(WorkspacePolicy.check(name: "tool.exe", size: 10), .failure(.typeNotAllowed("exe")))
        XCTAssertEqual(WorkspacePolicy.check(name: "big.pdf", size: 26_000_000), .failure(.tooLarge(limit: 25_000_000)))
        XCTAssertEqual(WorkspacePolicy.check(name: "a.txt", size: 0), .failure(.empty))
        XCTAssertEqual(WorkspacePolicy.check(name: "README", size: 3), .failure(.typeNotAllowed("")))
    }

    func testAttachmentPrompt() {
        let items = [AttachmentPrompt.Item(name: "a.png", serverPath: "/w/inbox/a.png", isImage: true)]
        XCTAssertEqual(AttachmentPrompt.compose("What is this?", attachments: []), "What is this?")
        let prompt = AttachmentPrompt.compose("What is this?", attachments: items)
        XCTAssertTrue(prompt.hasPrefix("What is this?\n\n[Attached file on the server]"))
        XCTAssertTrue(prompt.contains("- /w/inbox/a.png (image)"))
        XCTAssertTrue(AttachmentPrompt.compose("  ", attachments: items).hasPrefix("Please look at the attached file."))
    }

    func testTerminalFramesAndSocketURL() {
        XCTAssertEqual(TerminalServerFrame.decode(#"{"type":"ready","session":"abc","user":"brainbox-term","reattached":true,"cols":100,"rows":30}"#),
                       .ready(session: "abc", user: "brainbox-term", reattached: true, cols: 100, rows: 30))
        XCTAssertEqual(TerminalServerFrame.decode(#"{"type":"output","data":"$ "}"#), .output("$ "))
        XCTAssertEqual(TerminalServerFrame.decode(#"{"type":"exit","code":0}"#), .exit(code: 0))
        XCTAssertNil(TerminalServerFrame.decode("nonsense"))
        let input = try? JSONDecoder().decode(JSONValue.self, from: Data(TerminalClientFrame.input("ls\r").json.utf8))
        XCTAssertEqual(input?["type"]?.stringValue, "input")
        XCTAssertEqual(input?["data"]?.stringValue, "ls\r")
        XCTAssertTrue(TerminalClientFrame.resize(cols: 120, rows: 40).json.contains(#""cols":120"#))

        let api = client(MockHTTPTransport(), profile: "research")
        let socket = api.terminalSocket(session: "s1", cols: 80, rows: 24)
        XCTAssertEqual(socket.url.scheme, "wss")
        XCTAssertEqual(socket.url.path, "/hermes/brainbox/terminal")
        XCTAssertTrue(socket.url.query?.contains("session=s1") ?? false)
        XCTAssertEqual(socket.headers["Authorization"], "Bearer device-token-0123456789")
        XCTAssertFalse(socket.url.absoluteString.contains("device-token"), "the token never goes in the URL")
    }

    func testCommandRiskWarnsOnlyOnDestructiveCommands() {
        for risky in ["rm -rf /", "sudo rm -rf /*", "rm -fr ~", "rm -r -f /etc", "rm --recursive --force /", "mkfs.ext4 /dev/sda1",
                      "dd if=/dev/zero of=/dev/sda", "shutdown -h now", "sudo reboot", "chmod -R 777 /", ":(){ :|:& };:",
                      "curl https://x.sh | sudo bash", "systemctl stop tailscaled", "ls; rm -rf ~"] {
            XCTAssertNotNil(CommandRisk.warning(for: risky), risky)
        }
        for safe in ["ls -la", "rm -rf ./build", "rm notes.txt", "df -h", "systemctl status hermes", "echo reboot later",
                     "grep -r shutdown /var/log", "tail -f /var/log/syslog", ""] {
            XCTAssertNil(CommandRisk.warning(for: safe), safe)
        }
    }

    func testPushStatusAndRegistration() async throws {
        let transport = MockHTTPTransport()
        transport.on("GET /hermes/brainbox/push") { _ in
            MockHTTPTransport.json(#"{"enabled":false,"ready":false,"problems":["Push notifications are turned off on the server ([push] enabled = false)."],"environment":null,"registered_tokens":0,"prefs":{"job_done":true},"events":["job_done"]}"#)
        }
        transport.on("POST /hermes/brainbox/push/register") { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.body ?? Data())
            XCTAssertEqual(body["environment"]?.stringValue, "development")
            XCTAssertEqual(body["preferences"]?["approval"]?.boolValue, false)
            return MockHTTPTransport.json(#"{"object":"brainbox.push.registration"}"#)
        }
        transport.on("POST /hermes/brainbox/push/test") { _ in
            MockHTTPTransport.json(#"{"error":{"message":"Push notifications are turned off on the server ([push] enabled = false).","code":"push_not_ready"}}"#, status: 503)
        }
        let api = client(transport)
        let status = try await api.pushStatus()
        XCTAssertFalse(status.ready)
        XCTAssertEqual(status.problems.count, 1)
        try await api.registerPush(token: String(repeating: "a", count: 64), environment: "development", preferences: ["approval": false])
        do { _ = try await api.sendTestPush(); XCTFail("must not report a send that didn't happen") } catch AgentError.remote(let code, _) {
            XCTAssertEqual(code, "push_not_ready")
        }
    }

    func testDeepLinks() {
        let session = "ios_" + String(repeating: "a", count: 32)
        XCTAssertEqual(BrainboxDeepLink.parse(URL(string: "brainbox://chat/\(session)")!), .chat(sessionID: session))
        XCTAssertEqual(BrainboxDeepLink.parse(URL(string: "brainbox://tasks/job/a1b2c3d4e5f6")!), .job(id: "a1b2c3d4e5f6"))
        XCTAssertEqual(BrainboxDeepLink.parse(URL(string: "brainbox://tasks/run/run_123")!), .run(id: "run_123"))
        XCTAssertEqual(BrainboxDeepLink.parse(URL(string: "brainbox://server")!), .server)
        XCTAssertNil(BrainboxDeepLink.parse(URL(string: "brainbox://chat/telegram_1")!), "only the app's own chats")
        XCTAssertNil(BrainboxDeepLink.parse(URL(string: "https://evil.example/chat/x")!))
        XCTAssertNil(BrainboxDeepLink.parse(URL(string: "brainbox://tasks/job/..%2F..")!))
    }

    func testRequestLogKeepsPathsOnly() async throws {
        let inner = MockHTTPTransport()
        inner.on("GET /hermes/api/jobs") { _ in MockHTTPTransport.json(#"{"jobs":[]}"#) }
        let recording = RecordingHTTPTransport(inner, capacity: 2)
        let api = HermesAPIClient(configuration: HermesConfiguration(baseURL: URL(string: "https://vps.example.ts.net/hermes")!),
                                  transport: recording, tokenProvider: { "secret-device-token" })
        _ = try await api.jobs()
        _ = try? await api.session(id: "missing")
        _ = try await api.jobs()
        XCTAssertEqual(recording.log.count, 2, "bounded")
        XCTAssertEqual(recording.log.first?.path, "/hermes/api/jobs")
        XCTAssertEqual(recording.log.last?.status, 404)
        XCTAssertTrue(recording.log.last?.isFailure ?? false)
        XCTAssertFalse(String(describing: recording.log).contains("secret-device-token"))
    }
}
