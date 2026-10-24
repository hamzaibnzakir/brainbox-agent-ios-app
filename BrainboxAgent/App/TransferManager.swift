import Foundation
import SwiftUI
import BrainboxCore

/// Uploads to / downloads from the Brainbox workspace with real progress and
/// cancel. Only the proxy's /brainbox/files routes are used, so nothing outside
/// <workspace>/inbox and <workspace>/outbox is reachable.
@MainActor
@Observable
final class TransferManager {
    struct Transfer: Identifiable, Equatable {
        enum Direction: Equatable { case upload, download }
        enum State: Equatable {
            case running
            case finished(serverPath: String?, localURL: URL?)
            case failed(String)
            case cancelled
        }
        let id = UUID()
        let name: String
        let direction: Direction
        var bytesTotal: Int64
        var progress: Double = 0
        var state: State = .running
    }

    private(set) var transfers: [Transfer] = []
    @ObservationIgnored private var cancellers: [UUID: () -> Void] = [:]
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    var active: [Transfer] { transfers.filter { $0.state == .running } }

    func cancel(_ id: UUID) {
        cancellers[id]?()
    }

    func dismiss(_ id: UUID) {
        transfers.removeAll { $0.id == id && $0.state != .running }
    }

    private func update(_ id: UUID, _ body: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        body(&transfers[index])
    }

    private static func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    // MARK: Upload

    /// Uploads a local file to the inbox. Checks name, type and size first
    /// (the server checks again). Returns the server's record of the file.
    func upload(fileAt url: URL, name: String, client: HermesAPIClient,
                limits: (allowed: Set<String>, maxBytes: Int64)? = nil) async throws -> WorkspaceUpload {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let clean: String
        switch WorkspacePolicy.check(name: name, size: size, allowed: limits?.allowed ?? WorkspacePolicy.defaultExtensions,
                                     maxBytes: limits?.maxBytes ?? WorkspacePolicy.defaultMaxUploadBytes) {
        case .success(let value): clean = value
        case .failure(let problem): throw AgentError.permissionDenied(detail: problem.message)
        }
        var transfer = Transfer(name: clean, direction: .upload, bytesTotal: size)
        transfer.progress = 0
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        let request = client.authorizedRequest("POST", "/brainbox/files/upload", query: ["area": "inbox", "name": clean],
                                               extraHeaders: ["Content-Type": "application/octet-stream", "Accept": "application/json"])
        let progress = ProgressDelegate { [weak self] fraction in
            Task { @MainActor in self?.update(id) { $0.progress = fraction } }
        }
        let session = self.session
        let work = Task<WorkspaceUpload, Error> {
            let (data, response) = try await session.upload(for: Self.urlRequest(request), fromFile: url, delegate: progress)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw HermesAPIClient.sessionError(HTTPResponse(status: status, body: data))
            }
            do {
                return try JSONDecoder().decode(WorkspaceUpload.self, from: data)
            } catch {
                throw AgentError.protocolViolation(detail: "The server returned an unexpected upload response.")
            }
        }
        cancellers[id] = { work.cancel() }
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            update(id) { $0.progress = 1; $0.state = .finished(serverPath: result.absolutePath ?? result.file.path, localURL: nil) }
            cancellers[id] = nil
            return result
        } catch {
            let cancelled = work.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError
            update(id) { $0.state = cancelled ? .cancelled : .failed(error.asAgentError.message) }
            cancellers[id] = nil
            throw cancelled ? AgentError.cancelled : error
        }
    }

    /// Uploads in-memory data (e.g. a photo) by writing it to a temporary file first.
    func upload(data: Data, name: String, client: HermesAPIClient,
                limits: (allowed: Set<String>, maxBytes: Int64)? = nil) async throws -> WorkspaceUpload {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bb-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("payload")
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return try await upload(fileAt: file, name: name, client: client, limits: limits)
    }

    // MARK: Download

    /// Downloads a workspace file to a private temporary folder (for preview / share).
    func download(_ entry: WorkspaceEntry, client: HermesAPIClient) async throws -> URL {
        var transfer = Transfer(name: entry.name, direction: .download, bytesTotal: entry.size ?? 0)
        transfer.progress = 0
        transfers.insert(transfer, at: 0)
        let id = transfer.id
        let request = client.authorizedRequest("GET", "/brainbox/files/download", query: ["path": entry.path])
        let progress = ProgressDelegate { [weak self] fraction in
            Task { @MainActor in self?.update(id) { $0.progress = fraction } }
        }
        let session = self.session
        let name = WorkspacePolicy.safeName(entry.name) ?? "download"
        let work = Task<URL, Error> {
            let (temp, response) = try await session.download(for: Self.urlRequest(request), delegate: progress)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let body = (try? Data(contentsOf: temp)) ?? Data()
                throw HermesAPIClient.sessionError(HTTPResponse(status: status, body: body))
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bb-download-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: temp, to: destination)
            return destination
        }
        cancellers[id] = { work.cancel() }
        do {
            let url = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            update(id) { $0.progress = 1; $0.state = .finished(serverPath: entry.path, localURL: url) }
            cancellers[id] = nil
            return url
        } catch {
            let cancelled = work.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError
            update(id) { $0.state = cancelled ? .cancelled : .failed(error.asAgentError.message) }
            cancellers[id] = nil
            throw cancelled ? AgentError.cancelled : error
        }
    }
}

/// Reports upload / download progress for one task.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by URLSessionDownloadDelegate; the async API returns the file itself.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
