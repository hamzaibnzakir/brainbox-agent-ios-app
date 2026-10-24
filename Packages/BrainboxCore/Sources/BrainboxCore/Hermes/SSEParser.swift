import Foundation

/// One Server-Sent Event, as defined by the WHATWG EventSource spec.
public struct SSEEvent: Hashable, Sendable {
    /// `event:` field. `nil` means the default ("message") type.
    public var event: String?
    /// All `data:` lines of the event joined with "\n".
    public var data: String
    /// `id:` field, if the server sent one.
    public var id: String?
    /// `retry:` field in milliseconds, if the server sent one.
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// Incremental, allocation-light SSE parser.
///
/// Feed it raw bytes exactly as they arrive from the network — chunks may
/// split anywhere, including inside a UTF-8 sequence or between `\r` and
/// `\n`. Complete events are returned as soon as their terminating blank
/// line arrives. Comment lines (`: keepalive`) are ignored, which is how
/// Hermes keeps idle run streams alive.
public struct SSEParser: Sendable {
    private var buffer: [UInt8] = []
    private var pendingCR = false
    private var dataLines: [String] = []
    private var eventType: String?
    private var eventID: String?
    private var retry: Int?
    private var sawField = false

    /// The last event id seen (persists across events, per the spec).
    public private(set) var lastEventID: String?

    public init() {}

    /// Appends bytes and returns every event they completed.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if pendingCR {
                pendingCR = false
                if byte == 0x0A { continue } // CRLF: the CR already ended the line
            }
            switch byte {
            case 0x0D:
                pendingCR = true
                if let event = endLine() { events.append(event) }
            case 0x0A:
                if let event = endLine() { events.append(event) }
            default:
                buffer.append(byte)
            }
        }
        return events
    }

    /// Convenience for tests and string-based transports.
    public mutating func feed(_ text: String) -> [SSEEvent] {
        feed(Array(text.utf8))
    }

    /// Flushes a trailing event that was never terminated by a blank line
    /// (servers that close the stream right after the last `data:` line).
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty, let event = endLine() { events.append(event) }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func endLine() -> SSEEvent? {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if line.isEmpty { return dispatch() }
        process(line)
        return nil
    }

    private mutating func process(_ line: String) {
        if line.hasPrefix(":") { return } // comment / keepalive
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(String(value))
            sawField = true
        case "event":
            eventType = String(value)
            sawField = true
        case "id":
            // Ids containing NUL are ignored per spec.
            if !value.contains("\u{0}") {
                eventID = String(value)
                lastEventID = String(value)
            }
            sawField = true
        case "retry":
            if let ms = Int(value), ms >= 0 { retry = ms }
            sawField = true
        default:
            break // unknown fields are ignored
        }
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            dataLines.removeAll()
            eventType = nil
            eventID = nil
            retry = nil
            sawField = false
        }
        guard sawField, !dataLines.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n")
        let type = (eventType?.isEmpty ?? true) ? nil : eventType
        return SSEEvent(event: type, data: data, id: eventID, retry: retry)
    }
}
