import Foundation

/// One frame from a run's event stream. Through the Brainbox relay frames carry a
/// sequence number (`seq`, also the SSE `id:`) so the stream resumes with
/// `Last-Event-ID` without loss or duplicates; straight from Hermes they don't.
public struct HermesRunFrame: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A real Hermes run event.
        case event(HermesRunEvent)
        /// Relay transport heartbeat — the link is alive. Never agent progress.
        case heartbeat(RelayHeartbeat)
        /// The relay's link to Hermes changed (`live`, `polling`, `gone`).
        case upstream(state: String, detail: String?)
        /// Text whose individual delta events were evicted from the relay buffer.
        case snapshot(text: String)
    }

    public var seq: Int?
    /// The run this frame says it belongs to (Hermes stamps `run_id` on every event).
    public var runID: String?
    public var kind: Kind
    /// True when Hermes' stream was lost and the relay derived this event from run status.
    public var fromStatus: Bool

    public init(seq: Int? = nil, runID: String? = nil, kind: Kind, fromStatus: Bool = false) {
        self.seq = seq
        self.runID = runID
        self.kind = kind
        self.fromStatus = fromStatus
    }

    public static func parse(_ sse: SSEEvent) -> HermesRunFrame? {
        guard let bytes = sse.data.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: bytes),
              let name = json["event"]?.stringValue else { return nil }
        let seq = json["seq"]?.intValue ?? sse.id.flatMap { Int($0) }
        let runID = json["run_id"]?.stringValue
        switch name {
        case "brainbox.heartbeat":
            return HermesRunFrame(seq: nil, runID: runID, kind: .heartbeat(RelayHeartbeat(
                lastSeq: json["last_seq"]?.intValue, upstream: json["upstream"]?.stringValue,
                hermesStatus: json["hermes_status"]?.stringValue)))
        case "brainbox.upstream":
            return HermesRunFrame(seq: seq, runID: runID, kind: .upstream(state: json["state"]?.stringValue ?? "",
                                                                          detail: json["detail"]?.stringValue))
        case "replay.truncated":
            // Newer Hermes evicted events before this client read them; the final output still arrives.
            return HermesRunFrame(seq: seq, runID: runID, kind: .upstream(state: "truncated",
                detail: "Some live events were dropped by Hermes before they reached the app; the final answer is unaffected."))
        case "brainbox.snapshot":
            return HermesRunFrame(seq: seq, runID: runID, kind: .snapshot(text: json["text"]?.stringValue ?? ""))
        default:
            guard let event = HermesRunEvent.parse(data: sse.data) else { return nil }
            return HermesRunFrame(seq: seq, runID: runID, kind: .event(event),
                                  fromStatus: json["source"]?.stringValue == "status")
        }
    }
}

extension HermesAPIClient {
    /// Opens a run's event stream. `lastEventID` resumes after that sequence number
    /// (the Brainbox relay honours it; plain Hermes can't resume and answers 404).
    public func runFrames(id: String, lastEventID: Int? = nil) -> AsyncThrowingStream<HermesRunFrame, Error> {
        var extra = ["Accept": "text/event-stream"]
        if let lastEventID { extra["Last-Event-ID"] = String(lastEventID) }
        let request = HTTPRequest(method: "GET", url: url("/v1/runs/\(Self.escape(id))/events"),
                                  headers: headers(json: false, extra: extra), timeout: 60 * 60)
        let transport = self.transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await transport.stream(request)
                    guard (200..<300).contains(response.status) else {
                        var body = Data()
                        for try await chunk in response.chunks { body.append(chunk); if body.count > 8192 { break } }
                        throw Self.error(status: response.status, body: body)
                    }
                    var parser = SSEParser()
                    for try await chunk in response.chunks {
                        for sse in parser.feed(chunk) {
                            if let frame = HermesRunFrame.parse(sse) { continuation.yield(frame) }
                        }
                    }
                    for sse in parser.finish() {
                        if let frame = HermesRunFrame.parse(sse) { continuation.yield(frame) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? AgentError.cancelled : error.asAgentError)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
