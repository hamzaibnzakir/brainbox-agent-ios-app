import AVFoundation
import AVKit
import HermesKit
import QuickLook
import SwiftUI

/// Fetches files the agent sends (server paths over SSH, or http(s) links) into a local cache.
@MainActor
final class MediaStore {
    static let shared = MediaStore()
    private var cache: [String: URL] = [:]
    private var inFlight: [String: Task<URL, Error>] = [:]
    static let maxBytes = 200 * 1024 * 1024

    enum MediaError: LocalizedError {
        case tooLarge(Int), missing, failed(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let n): return "The file is \(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)) — too big to preview here."
            case .missing: return "That file isn't on the server anymore."
            case .failed(let why): return why
            }
        }
    }

    func file(for ref: MediaRef, model: AppModel) async throws -> URL {
        if let url = cache[ref.location], FileManager.default.fileExists(atPath: url.path) { return url }
        if let task = inFlight[ref.location] { return try await task.value }
        let task = Task<URL, Error> { try await self.download(ref, model: model) }
        inFlight[ref.location] = task
        defer { inFlight[ref.location] = nil }
        let url = try await task.value
        cache[ref.location] = url
        return url
    }

    private func download(_ ref: MediaRef, model: AppModel) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brainbox-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(abs(ref.location.hashValue)) + "-" + (ref.filename.isEmpty ? "file" : ref.filename)
        let target = dir.appendingPathComponent(name)
        let data: Data
        if ref.isRemoteURL, let url = URL(string: ref.location) {
            data = try await URLSession.shared.data(from: url).0
        } else {
            let client = try await model.client()
            let quoted = ref.location.hasPrefix("~/") ? "\"$HOME\"/" + RemoteBackend.shq(String(ref.location.dropFirst(2)))
                                                       : RemoteBackend.shq(ref.location)
            let size = try await client.ssh.exec("stat -c %s -- \(quoted) 2>/dev/null || stat -f %z -- \(quoted) 2>/dev/null", timeout: 20)
            guard let bytes = Int(size.output.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw MediaError.missing }
            guard bytes <= Self.maxBytes else { throw MediaError.tooLarge(bytes) }
            let result = try await client.ssh.exec("cat -- \(quoted)", timeout: 600)
            guard result.succeeded else { throw MediaError.failed(result.errorOutput.isEmpty ? "Couldn't read the file." : result.errorOutput) }
            data = result.stdout
        }
        try data.write(to: target)
        return target
    }
}

/// Everything the agent attached to one reply.
struct MediaGallery: View {
    var refs: [MediaRef]
    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.s) {
            ForEach(refs) { ref in MediaTile(ref: ref) }
        }
    }
}

struct MediaTile: View {
    var ref: MediaRef
    @Environment(AppModel.self) private var model
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = false
    @State private var fullScreen = false
    @State private var preview: URL?

    var body: some View {
        Group {
            switch ref.kind {
            case .image: imageTile
            case .video: videoTile
            case .audio: audioTile
            case .document: documentTile
            }
        }
        .task(id: ref.location) { if ref.kind == .image { await load() } }
        .sheet(isPresented: $fullScreen) {
            if let image { ImageViewer(image: image, url: url, title: ref.filename) }
        }
        .sheet(item: Binding(get: { preview.map { IdentifiedURL(url: $0) } }, set: { preview = $0?.url })) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
    }

    private func load() async {
        guard url == nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let file = try await MediaStore.shared.file(for: ref, model: model)
            url = file
            if ref.kind == .image { image = UIImage(contentsOfFile: file.path) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder private var imageTile: some View {
        if let image {
            Image(uiImage: image)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                .onTapGesture { fullScreen = true }
                .contextMenu {
                    if let url { ShareLink(item: url) { Label("Share or save", systemImage: "square.and.arrow.up") } }
                }
                .accessibilityLabel("Image \(ref.filename)")
        } else {
            placeholder(symbol: "photo", label: ref.filename)
        }
    }

    @ViewBuilder private var videoTile: some View {
        if let url {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").padding(DS.S.s).background(.ultraThinMaterial, in: Circle()) }
                        .padding(DS.S.s)
                }
        } else {
            Button { Task { await load() } } label: { placeholder(symbol: "play.rectangle.fill", label: ref.filename, action: "Play") }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var audioTile: some View {
        if let url {
            AudioRow(url: url, title: ref.filename)
        } else {
            Button { Task { await load() } } label: { placeholder(symbol: "waveform", label: ref.filename, action: "Play") }
                .buttonStyle(.plain)
        }
    }

    private var documentTile: some View {
        Button {
            Task {
                await load()
                if let url { preview = url }
            }
        } label: {
            placeholder(symbol: Self.docSymbol(ref.filename), label: ref.filename, action: "Open")
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url { ShareLink(item: url) { Label("Share or save", systemImage: "square.and.arrow.up") } }
            Button { UIPasteboard.general.string = ref.location } label: { Label("Copy path", systemImage: "doc.on.doc") }
        }
    }

    private func placeholder(symbol: String, label: String, action: String? = nil) -> some View {
        HStack(spacing: DS.S.s + 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.C.voltSoft).frame(width: 40, height: 40)
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(DS.C.volt) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(DS.F.smallStrong).foregroundStyle(DS.C.ink).lineLimit(1)
                Text(error ?? (ref.isRemoteURL ? "Link" : "On your server")).font(DS.F.caption)
                    .foregroundStyle(error == nil ? DS.C.ink3 : DS.C.bad).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let action, error == nil, !loading { Text(action).font(DS.F.captionStrong).foregroundStyle(DS.C.volt) }
        }
        .padding(DS.S.s + 4)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous).stroke(DS.C.line, lineWidth: 1))
    }

    static func docSymbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext.fill"
        case "zip", "gz", "tar": return "doc.zipper"
        case "csv", "xlsx", "xls": return "tablecells.fill"
        default: return "doc.fill"
        }
    }
}

struct AudioRow: View {
    var url: URL
    var title: String
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        HStack(spacing: DS.S.s + 4) {
            Button {
                if player == nil { player = AVPlayer(url: url) }
                if playing { player?.pause() } else { player?.play() }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(DS.C.volt, in: Circle())
            }
            Text(title).font(DS.F.smallStrong).foregroundStyle(DS.C.ink).lineLimit(1)
            Spacer()
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up").foregroundStyle(DS.C.ink2) }
        }
        .padding(DS.S.s + 4)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            playing = false
            player?.seek(to: .zero)
        }
    }
}

struct ImageViewer: View {
    var image: UIImage
    var url: URL?
    var title: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                }
                .gesture(MagnificationGesture().onChanged { scale = min(max($0, 1), 5) })
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let url { ToolbarItem(placement: .primaryAction) { ShareLink(item: url) } }
            }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    var url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
