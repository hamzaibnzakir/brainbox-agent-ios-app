import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP request description so the Hermes client can be tested
/// against an in-memory server on any platform (including Linux CI).
public struct HTTPRequest: Hashable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Hashable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A streaming response: status/headers first, then body bytes in chunks.
public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var chunks: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String] = [:], chunks: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Opens a long-lived response (SSE). Cancelling the consuming task
    /// must close the underlying connection.
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse
}

#if canImport(Darwin)
/// Production transport built on URLSession. Uses the system trust store
/// (no certificate-validation overrides) and ephemeral storage, so no
/// cookies or caches are written to disk.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        // SSE streams can be idle for long periods between keepalives.
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    private func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    private static func headers(of response: URLResponse) -> (Int, [String: String]) {
        guard let http = response as? HTTPURLResponse else { return (0, [:]) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return (http.statusCode, headers)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: urlRequest(request))
        let (status, headers) = Self.headers(of: response)
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        var urlRequest = urlRequest(request)
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: urlRequest)
        let (status, headers) = Self.headers(of: response)
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(1024)
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Flush on line ends so events are delivered promptly.
                        if byte == 0x0A || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: status, headers: headers, chunks: chunks)
    }
}
#endif

/// Scriptable in-memory HTTP server for tests and the Motion Lab.
public final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse
    public typealias StreamHandler = @Sendable (HTTPRequest) async throws -> HTTPStreamResponse

    private let state = Locked<(handlers: [(String, Handler)], streams: [(String, StreamHandler)], log: [HTTPRequest])>(([], [], []))

    public init() {}

    /// Registers a handler for `"METHOD /path"` (path relative to host, query ignored).
    public func on(_ route: String, _ handler: @escaping Handler) {
        state.withLock { $0.handlers.append((route, handler)) }
    }

    public func onStream(_ route: String, _ handler: @escaping StreamHandler) {
        state.withLock { $0.streams.append((route, handler)) }
    }

    public var requests: [HTTPRequest] { state.withLock { $0.log } }

    public func requests(matching route: String) -> [HTTPRequest] {
        requests.filter { Self.key(for: $0) == route }
    }

    static func key(for request: HTTPRequest) -> String {
        "\(request.method) \(request.url.path)"
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = Self.key(for: request)
        let handler = state.withLock { s -> Handler? in
            s.log.append(request)
            return s.handlers.last { $0.0 == key }?.1
        }
        guard let handler else {
            return HTTPResponse(status: 404, body: Data(#"{"error":{"message":"No mock for \#(key)","code":"not_found"}}"#.utf8))
        }
        return try await handler(request)
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let key = Self.key(for: request)
        let handler = state.withLock { s -> StreamHandler? in
            s.log.append(request)
            return s.streams.last { $0.0 == key }?.1
        }
        guard let handler else {
            return HTTPStreamResponse(status: 404, chunks: AsyncThrowingStream { $0.finish() })
        }
        return try await handler(request)
    }

    /// Builds an SSE stream from pre-encoded text chunks.
    public static func sse(_ chunks: [String], status: Int = 200, delay: TimeInterval = 0, failAtEnd: Error? = nil) -> HTTPStreamResponse {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                for chunk in chunks {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    if Task.isCancelled { break }
                    continuation.yield(Data(chunk.utf8))
                }
                if let failAtEnd { continuation.finish(throwing: failAtEnd) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: status, headers: ["Content-Type": "text/event-stream"], chunks: stream)
    }

    public static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }
}
