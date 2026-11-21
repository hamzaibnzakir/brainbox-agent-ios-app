import Foundation

/// Something that carries bytes both ways — an SSH direct-tcpip channel in the
/// app, an in-memory pipe in tests.
public protocol ByteDuplex: AnyObject, Sendable {
    var events: AsyncThrowingStream<SSHStreamEvent, Error> { get }
    func write(_ data: Data) async throws
    func close()
}

extension SSHByteStream: ByteDuplex {}

/// Opens a fresh byte stream to the backend's port each time it's asked.
public protocol TunnelDialer: Sendable {
    func dial() async throws -> ByteDuplex
}

/// Buffered reader over a duplex's inbound events.
final class ByteReader {
    private var iterator: AsyncThrowingStream<SSHStreamEvent, Error>.AsyncIterator
    private(set) var buffer = Data()
    private(set) var finished = false

    init(_ duplex: ByteDuplex) {
        iterator = duplex.events.makeAsyncIterator()
    }

    /// Pulls one more chunk. Returns false at end of stream.
    @discardableResult
    func fill() async throws -> Bool {
        while !finished {
            guard let event = try await iterator.next() else { finished = true; return false }
            if case .data(let d) = event, !d.isEmpty { buffer.append(d); return true }
            if case .eof = event { finished = true; return false }
        }
        return false
    }

    /// Reads up to (and consumes) the delimiter; nil if the stream ends first.
    func read(until delimiter: Data, limit: Int = 1 << 20) async throws -> Data? {
        while true {
            if let range = buffer.range(of: delimiter) {
                let head = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return head
            }
            if buffer.count > limit { throw TunnelHTTPError.malformed("header too large") }
            if try await !fill() { return nil }
        }
    }

    func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            if try await !fill() { throw TunnelHTTPError.malformed("stream ended early") }
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    func readToEnd(limit: Int) async throws -> Data {
        while try await fill() {
            if buffer.count > limit { throw TunnelHTTPError.malformed("response too large") }
        }
        let out = buffer
        buffer.removeAll()
        return out
    }
}

public enum TunnelHTTPError: Error, LocalizedError, Equatable {
    case malformed(String)
    case status(Int, String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let why): return "Bad response from Hermes (\(why))."
        case .status(let code, let body): return HermesAPIErrorText.describe(status: code, body: body)
        }
    }
}

enum HermesAPIErrorText {
    static func describe(status: Int, body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String { return "Hermes said: \(detail) (\(status))" }
            if let error = json["error"] as? String { return "Hermes said: \(error) (\(status))" }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return "Hermes said: \(message) (\(status))"
            }
        }
        switch status {
        case 401, 403: return "Hermes refused the session token (\(status)). Reconnect to start a fresh session."
        case 404: return "This Hermes version doesn't have that feature (404)."
        default:
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Hermes returned \(status)" + (trimmed.isEmpty ? "." : ": \(String(trimmed.prefix(200)))")
        }
    }
}

public struct TunnelResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Minimal HTTP/1.1 client: one request per tunnel stream, `Connection: close`.
public struct TunnelHTTPClient: Sendable {
    public let dialer: TunnelDialer
    public let defaultHeaders: [String: String]
    public var maxBody: Int = 64 << 20

    public init(dialer: TunnelDialer, defaultHeaders: [String: String] = [:]) {
        self.dialer = dialer
        self.defaultHeaders = defaultHeaders
    }

    public func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil,
                     timeout: TimeInterval = 60) async throws -> TunnelResponse {
        let duplex = try await dialer.dial()
        defer { duplex.close() }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
        var merged = defaultHeaders
        for (k, v) in headers { merged[k] = v }
        if let body { merged["Content-Length"] = String(body.count) }
        else if method != "GET" && method != "HEAD" { merged["Content-Length"] = "0" }
        for (k, v) in merged.sorted(by: { $0.key < $1.key }) {
            request += "\(k): \(v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n"
        }
        request += "\r\n"
        var payload = Data(request.utf8)
        if let body { payload.append(body) }

        return try await withThrowingTaskGroup(of: TunnelResponse.self) { group in
            group.addTask {
                try await duplex.write(payload)
                return try await Self.readResponse(ByteReader(duplex), method: method, maxBody: maxBody)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                duplex.close()
                throw SSHError.timedOut("waiting for Hermes to answer \(path.split(separator: "?").first ?? "")")
            }
            let response = try await group.next()!
            group.cancelAll()
            return response
        }
    }

    static func readResponse(_ reader: ByteReader, method: String, maxBody: Int) async throws -> TunnelResponse {
        guard let head = try await reader.read(until: Data("\r\n\r\n".utf8)) else {
            throw TunnelHTTPError.malformed("connection closed before a response")
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { throw TunnelHTTPError.malformed("status line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data()
        if method == "HEAD" || status == 204 || status == 304 {
            // no body
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                guard let sizeLine = try await reader.read(until: Data("\r\n".utf8)) else { break }
                let sizeText = String(decoding: sizeLine, as: UTF8.self).split(separator: ";").first ?? "0"
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                    throw TunnelHTTPError.malformed("chunk size")
                }
                if size == 0 { _ = try await reader.read(until: Data("\r\n".utf8)); break }
                body.append(try await reader.read(exactly: size))
                _ = try await reader.read(exactly: 2)
                if body.count > maxBody { throw TunnelHTTPError.malformed("response too large") }
            }
        } else if let length = headers["content-length"].flatMap({ Int($0) }) {
            if length > maxBody { throw TunnelHTTPError.malformed("response too large") }
            body = try await reader.read(exactly: length)
        } else {
            body = try await reader.readToEnd(limit: maxBody)
        }
        return TunnelResponse(status: status, headers: headers, body: body)
    }
}
