import Foundation
import XCTest
@testable import BrainboxCore

final class WireProtocolTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let original = WireEnvelope(type: "message.delta", requestId: "r1", conversationId: "c1", payload: ["text": "hi", "n": 3, "ok": true, "list": ["a", "b"]])
        let decoded = try WireEnvelope.decode(try original.encodedString())
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.requestId, "r1")
        XCTAssertEqual(decoded.payload["text"]?.stringValue, "hi")
        XCTAssertEqual(decoded.payload["n"]?.intValue, 3)
        XCTAssertEqual(decoded.payload["ok"]?.boolValue, true)
        XCTAssertEqual(abs(decoded.ts.timeIntervalSince(original.ts)) < 0.01, true)
    }

    func testRejectsWrongVersionAndGarbage() {
        XCTAssertThrowsError(try WireEnvelope.decode("not json"))
        let future = #"{"v":99,"type":"x","id":"e","ts":"2026-10-08T04:38:00Z","payload":{}}"#
        XCTAssertThrowsError(try WireEnvelope.decode(future)) { error in
            guard case .protocolViolation = error.asAgentError else { return XCTFail("\(error)") }
        }
    }

    func testEveryEventRoundTripsThroughTheWire() throws {
        let rid = UUID(), cid = UUID()
        let call = ToolCall(id: "tc", kind: .git, name: "git.pull", title: "Pulling", input: "git pull")
        let events: [AgentEvent] = [
            .accepted(requestID: rid),
            .status(.runningTool(name: "Git")),
            .status(.unavailable(reason: "maintenance")),
            .textDelta("Hello **world**"),
            .toolOutput(toolCallID: "tc", chunk: "Fast-forward\n"),
            .toolFinished(toolCallID: "tc", result: ToolResult(output: "done", exitCode: 0), status: .succeeded),
            .toolFinished(toolCallID: "tc", result: ToolResult(output: "boom", exitCode: 2, isError: true), status: .failed),
            .conversationTitle("Deploy"),
            .completed,
            .failed(.permissionDenied(detail: "no")),
            .failed(.remote(code: "rate_limited", message: "slow down"))
        ]
        for event in events {
            let wire = try WireCodec.envelope(for: event, requestID: rid, conversationID: cid)
            let reparsed = try WireEnvelope.decode(try wire.encodedString())
            XCTAssertEqual(try WireCodec.event(from: reparsed), event, "\(event)")
        }
        // Tool started carries a fresh timestamp, compare fields
        let started = try WireCodec.event(from: try WireCodec.envelope(for: .toolStarted(call), requestID: rid, conversationID: cid))
        guard case .toolStarted(let parsed) = started else { return XCTFail() }
        XCTAssertEqual(parsed.id, "tc")
        XCTAssertEqual(parsed.kind, .git)
        XCTAssertEqual(parsed.input, "git pull")
    }

    func testUnknownToolKindFallsBackToOther() throws {
        let frame = WireEnvelope(type: BrainboxProtocol.ServerType.toolStarted, requestId: "r", payload: ["toolCallId": "1", "kind": "quantum", "name": "q", "title": "Q", "input": "?"])
        guard case .toolStarted(let call)? = try WireCodec.event(from: frame) else { return XCTFail() }
        XCTAssertEqual(call.kind, .other)
    }

    func testTerminalFrameTypes() {
        XCTAssertTrue(WireCodec.isTerminal("message.completed"))
        XCTAssertTrue(WireCodec.isTerminal("error"))
        XCTAssertTrue(WireCodec.isTerminal("rpc.result"))
        XCTAssertFalse(WireCodec.isTerminal("message.delta"))
    }

    func testErrorCodeMapping() {
        XCTAssertEqual(ErrorPayload(code: "auth_failed", message: "x").agentError, .authenticationFailed(detail: "x"))
        XCTAssertEqual(ErrorPayload(code: "timeout", message: "x").agentError, .timedOut)
        XCTAssertEqual(ErrorPayload(code: "weird", message: "x").agentError, .remote(code: "weird", message: "x"))
    }
}

final class ModelTests: XCTestCase {
    func testFilePathHelpers() {
        XCTAssertEqual(FilePath.normalize("/a//b/./c/../d/"), "/a/b/d")
        XCTAssertEqual(FilePath.normalize("/../../etc"), "/etc")
        XCTAssertTrue(FilePath.isPath("/etc/brainbox/x.yaml", inside: "/etc/brainbox"))
        XCTAssertFalse(FilePath.isPath("/etc/brainboxevil/x", inside: "/etc/brainbox"))
        XCTAssertEqual(FilePath.parent(of: "/a/b/c"), "/a/b")
        XCTAssertEqual(FilePath.parent(of: "/a"), "/")
        XCTAssertEqual(FilePath.lastComponent(of: "/a/b.txt"), "b.txt")
        XCTAssertEqual(FilePath.join("/a/", "b"), "/a/b")
        XCTAssertFalse(FilePath.isValidName("a/b"))
        XCTAssertFalse(FilePath.isValidName(".."))
        XCTAssertTrue(FilePath.isValidName("notes.md"))
    }

    func testFileEntryLanguageAndSorting() {
        let entries = [
            FileEntry(path: "/x/b.yaml", isDirectory: false, size: 5, modifiedAt: Date(timeIntervalSince1970: 10)),
            FileEntry(path: "/x/a.json", isDirectory: false, size: 50, modifiedAt: Date(timeIntervalSince1970: 20)),
            FileEntry(path: "/x/z", isDirectory: true)
        ]
        XCTAssertEqual(entries[0].language, .yaml)
        XCTAssertEqual(FileSortOrder.name.sort(entries).map(\.name), ["z", "a.json", "b.yaml"])
        XCTAssertEqual(FileSortOrder.size.sort(entries).map(\.name), ["z", "a.json", "b.yaml"])
        XCTAssertEqual(FileSortOrder.modified.sort(entries).first?.isDirectory, true)
    }

    func testCommandHistoryNavigation() {
        var history = CommandHistory(limit: 3)
        ["ls", "pwd", "pwd", "  ", "uptime", "df -h"].forEach { history.record($0) }
        XCTAssertEqual(history.entries, ["pwd", "uptime", "df -h"])
        XCTAssertEqual(history.previous(), "df -h")
        XCTAssertEqual(history.previous(), "uptime")
        XCTAssertEqual(history.previous(), "pwd")
        XCTAssertEqual(history.previous(), "pwd")
        XCTAssertEqual(history.next(), "uptime")
        XCTAssertEqual(history.next(), "df -h")
        XCTAssertEqual(history.next(), "")
    }

    func testLogFilter() {
        let entry = LogEntry(level: .warning, category: .gateway, source: "gw", message: "heartbeat late")
        XCTAssertTrue(LogFilter().matches(entry))
        XCTAssertFalse(LogFilter(minimumLevel: .error).matches(entry))
        XCTAssertFalse(LogFilter(categories: [.agent]).matches(entry))
        XCTAssertTrue(LogFilter(query: "HEARTBEAT").matches(entry))
        XCTAssertFalse(LogFilter(query: "disk").matches(entry))
    }

    func testMetricsHealth() {
        let gb: Int64 = 1_073_741_824
        let healthy = ServerMetrics(cpuUsage: 0.2, memoryUsedBytes: 2 * gb, memoryTotalBytes: 8 * gb, diskUsedBytes: 10 * gb, diskTotalBytes: 80 * gb, networkRxBytesPerSecond: 0, networkTxBytesPerSecond: 0, loadAverage: [])
        XCTAssertEqual(healthy.health, .healthy)
        XCTAssertEqual(healthy.memoryUsage, 0.25, accuracy: 0.0001)
        var hot = healthy
        hot.cpuUsage = 0.95
        XCTAssertEqual(hot.health, .critical)
        let empty = ServerMetrics(cpuUsage: 0, memoryUsedBytes: 1, memoryTotalBytes: 0, diskUsedBytes: 0, diskTotalBytes: 0, networkRxBytesPerSecond: 0, networkTxBytesPerSecond: 0, loadAverage: [])
        XCTAssertEqual(empty.memoryUsage, 0)
    }

    func testConversationTitleAndPreview() {
        XCTAssertEqual(Conversation.suggestedTitle(from: "  check the gateway logs for errors please now  "), "Check the gateway logs for errors")
        XCTAssertEqual(Conversation.suggestedTitle(from: "   "), Conversation.untitled)
        var conversation = Conversation(providerKind: .mock)
        conversation.messages = [Message(role: .user, content: "hello\nworld")]
        XCTAssertEqual(conversation.preview, "hello world")
    }

    func testErrorNormalisation() {
        XCTAssertEqual(CancellationError().asAgentError, .cancelled)
        XCTAssertEqual(AgentError.timedOut.asAgentError, .timedOut)
        XCTAssertTrue(AgentError.webSocketDisconnected.isRetryable)
        XCTAssertFalse(AgentError.authenticationFailed(detail: "").isRetryable)
        XCTAssertEqual(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut).asAgentError, .timedOut)
    }

    func testFormatters() {
        XCTAssertEqual(ByteFormatter.string(512), "512 B")
        XCTAssertEqual(ByteFormatter.string(1536), "1.5 KB")
        XCTAssertEqual(ByteFormatter.string(200 * 1_048_576), "200 MB")
        XCTAssertEqual(DurationFormatter.short(90), "1m")
        XCTAssertEqual(DurationFormatter.short(3 * 86_400 + 7_200), "3d 2h")
    }
}

final class ChatReducerTests: XCTestCase {
    func testCancellationMarksMessageAndTools() {
        var message = Message(role: .assistant, content: "", state: .streaming)
        ChatReducer.apply(.toolStarted(ToolCall(id: "1", kind: .terminal, name: "t", title: "T", input: "sleep 9")), to: &message)
        ChatReducer.apply(.textDelta("Work"), to: &message)
        let effects = ChatReducer.apply(.failed(.cancelled), to: &message)
        XCTAssertTrue(effects.finished)
        XCTAssertEqual(message.state, .cancelled)
        XCTAssertEqual(message.toolCalls.first?.status, .cancelled)
    }

    func testFailureKeepsPartialContent() {
        var message = Message(role: .assistant, content: "", state: .streaming)
        ChatReducer.apply(.textDelta("partial"), to: &message)
        ChatReducer.apply(.failed(.webSocketDisconnected), to: &message)
        XCTAssertEqual(message.content, "partial")
        XCTAssertEqual(message.state, .failed(.webSocketDisconnected))
    }

    func testRetryPromptFindsPrecedingUserMessage() {
        let user = Message(role: .user, content: "deploy it")
        let assistant = Message(role: .assistant, content: "", state: .failed(.timedOut))
        let conversation = Conversation(providerKind: .mock, messages: [Message(role: .user, content: "first"), Message(role: .assistant, content: "ok"), user, assistant])
        XCTAssertEqual(ChatReducer.retryPrompt(for: assistant.id, in: conversation), "deploy it")
    }

    func testToolOutputIsBounded() {
        var message = Message(role: .assistant, content: "")
        ChatReducer.apply(.toolStarted(ToolCall(id: "x", kind: .terminal, name: "t", title: "T", input: "yes")), to: &message)
        for _ in 0..<300 { ChatReducer.apply(.toolOutput(toolCallID: "x", chunk: String(repeating: "y", count: 100)), to: &message) }
        XCTAssertLessThanOrEqual(message.toolCalls[0].liveOutput.count, 20_000)
    }
}
