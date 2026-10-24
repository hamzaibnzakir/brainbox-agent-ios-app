import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import BrainboxCore

/// A photo or file being prepared for the next message.
struct PendingAttachment: Identifiable, Equatable {
    enum State: Equatable { case preparing, uploading(Double), ready, failed(String) }
    let id = UUID()
    var name: String
    var kind: MessageAttachment.Kind
    var byteCount: Int64
    var thumbnail: Data?
    var dataURL: String?          // images: sent inline to the model
    var serverPath: String?       // files: stored in the workspace inbox
    var state: State = .preparing

    var asMessageAttachment: MessageAttachment {
        MessageAttachment(id: id, name: name, kind: kind, byteCount: byteCount, serverPath: serverPath,
                          status: kind == .file ? .uploaded : .preparing, thumbnail: thumbnail)
    }
}

/// Downscales photos for inline delivery (Hermes / proxy body limits).
enum ImagePrep {
    static let maxDimension: CGFloat = 1600
    static let maxBytes = 1_500_000

    static func prepare(_ data: Data) -> (jpeg: Data, dataURL: String, thumbnail: Data?)? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = resize(image, to: maxDimension)
        var quality: CGFloat = 0.8
        var jpeg = scaled.jpegData(compressionQuality: quality)
        while let current = jpeg, current.count > maxBytes, quality > 0.3 {
            quality -= 0.15
            jpeg = scaled.jpegData(compressionQuality: quality)
        }
        guard let jpeg, jpeg.count <= maxBytes else { return nil }
        let thumb = resize(image, to: 160).jpegData(compressionQuality: 0.6)
        return (jpeg, "data:image/jpeg;base64," + jpeg.base64EncodedString(), thumb)
    }

    private static func resize(_ image: UIImage, to limit: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, limit / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}

struct Composer: View {
    @Binding var text: String
    @Binding var attachments: [PendingAttachment]
    var isStreaming: Bool
    var isOnline: Bool
    var focused: FocusState<Bool>.Binding
    var suggestions: [CommandSuggestion]
    var argumentHelp: CommandArgumentHelp? = nil
    var canAttach: Bool
    var canInject: Bool
    /// Telegram's busy-input mode, when known: the default action for a message typed mid-reply.
    var busyMode: ChatStore.SteerMode? = nil
    var onSend: () -> Void
    var onStop: () -> Void
    var onSteer: (ChatStore.SteerMode) -> Void
    var onPickPhotos: ([PhotosPickerItem]) -> Void
    var onPickFiles: ([URL]) -> Void
    var placeholder: String = "Message the agent…"

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var uploadsBusy: Bool { attachments.contains { if case .ready = $0.state { return false } else { return true } } }
    private var canSend: Bool { (hasText || (!attachments.isEmpty && !uploadsBusy)) && isOnline && !uploadsBusy }

    var body: some View {
        VStack(spacing: 6) {
            if !suggestions.isEmpty {
                CommandSuggestionList(suggestions: suggestions) { suggestion in
                    text = suggestion.completion
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let help = argumentHelp {
                CommandArgumentHelpView(help: help) { option in
                    text = "/\(help.name) \(option) "
                }
                .transition(.opacity)
            }
            if !attachments.isEmpty {
                PendingAttachmentRow(attachments: $attachments)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if canAttach && !isStreaming {
                    Menu {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                            Label("Photo", systemImage: "photo")
                        }
                        Button { importing = true } label: { Label("File", systemImage: "doc") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(BB.Palette.textPrimary)
                            .frame(width: 36, height: 36)
                    }
                    .padding(.leading, 5)
                    .padding(.vertical, 5)
                    .accessibilityLabel("Attach")
                    .accessibilityIdentifier("composer.attach")
                }

                TextField(isOnline ? (isStreaming ? "Steer, queue, or type /…" : placeholder) : "Offline — reconnecting…", text: $text, axis: .vertical)
                    .font(BB.Font.body)
                    .foregroundStyle(BB.Palette.textPrimary)
                    .lineLimit(1...6)
                    .focused(focused)
                    .textInputAutocapitalization(text.hasPrefix("/") ? .never : .sentences)
                    .autocorrectionDisabled(text.hasPrefix("/"))
                    .padding(.leading, canAttach && !isStreaming ? 0 : 14)
                    .padding(.trailing, 4)
                    .padding(.vertical, 11)
                    .accessibilityIdentifier("composer.field")

                if isStreaming && hasText && !text.hasPrefix("/") {
                    Menu {
                        ForEach(ChatStore.SteerMode.allCases) { mode in
                            Button { onSteer(mode) } label: { Label(mode.title, systemImage: symbol(for: mode)) }
                                .disabled(mode == .inject && !canInject)
                        }
                    } label: {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(BB.Palette.onSignal)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(BB.Palette.signal))
                    } primaryAction: {
                        onSteer(primaryMode)
                    }
                    .padding(.vertical, 5)
                    .accessibilityLabel("\(primaryMode.title) (hold for more options)")
                    .accessibilityIdentifier("composer.steer")
                }

                Button {
                    if isStreaming && !(hasText && text.hasPrefix("/")) { onStop() } else if canSend { onSend() }
                } label: {
                    let showStop = isStreaming && !(hasText && text.hasPrefix("/"))
                    Image(systemName: showStop ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(showStop || canSend ? BB.Palette.onSignal : BB.Palette.textTertiary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(showStop || canSend ? BB.Palette.signal : BB.Palette.surfaceHigh))
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                .buttonStyle(.pressable)
                .disabled(!isStreaming && !canSend)
                .padding(5)
                .sensoryFeedback(.impact(weight: .medium), trigger: isStreaming)
                .accessibilityLabel(isStreaming ? "Stop" : "Send")
                .accessibilityIdentifier("composer.send")
            }
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(BB.Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(focused.wrappedValue ? BB.Palette.strokeStrong : BB.Palette.stroke, lineWidth: 1)
            )
        }
        .animation(Motion.snappy, value: canSend)
        .animation(Motion.snappy, value: isStreaming)
        .animation(Motion.snappy, value: suggestions)
        .padding(.horizontal, BB.Space.gutter)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            onPickPhotos(items)
            photoItems = []
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { onPickFiles(urls) }
        }
    }

    private var primaryMode: ChatStore.SteerMode {
        if let busyMode { return busyMode == .inject && !canInject ? .queue : busyMode }
        return canInject ? .inject : .queue
    }

    private func symbol(for mode: ChatStore.SteerMode) -> String {
        switch mode {
        case .inject: return "arrow.turn.down.right"
        case .queue: return "text.append"
        case .interrupt: return "stop.circle"
        }
    }
}

struct CommandSuggestionList: View {
    let suggestions: [CommandSuggestion]
    let pick: (CommandSuggestion) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button { pick(suggestion) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/" + suggestion.name).font(BB.Font.mono)
                                    .foregroundStyle(suggestion.kind == .unavailable ? BB.Palette.textTertiary : BB.Palette.textPrimary)
                                if !suggestion.argsHint.isEmpty {
                                    Text(suggestion.argsHint).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(suggestion.badge).font(BB.Font.label).foregroundStyle(BB.Palette.textTertiary)
                            }
                            Text(suggestion.detail + (suggestion.aliases.isEmpty ? "" : "  ·  /" + suggestion.aliases.joined(separator: " /")))
                                .font(BB.Font.caption)
                                .foregroundStyle(BB.Palette.textSecondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressableSubtle)
                    .accessibilityIdentifier("command.\(suggestion.name)")
                    if suggestion.id != suggestions.last?.id { Divider().overlay(BB.Palette.stroke) }
                }
            }
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: min(CGFloat(suggestions.count) * 58, 290))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BB.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BB.Palette.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("command.picker")
    }
}

/// Shown while typing a command's arguments: what it takes, and matching choices.
struct CommandArgumentHelpView: View {
    let help: CommandArgumentHelp
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("/\(help.name)").font(BB.Font.mono).foregroundStyle(BB.Palette.textPrimary)
                if !help.argsHint.isEmpty {
                    Text(help.argsHint).font(BB.Font.monoSmall).foregroundStyle(BB.Palette.textTertiary).lineLimit(1)
                }
            }
            Text(help.summary).font(BB.Font.caption).foregroundStyle(BB.Palette.textSecondary).lineLimit(2)
            if !help.options.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(help.options, id: \.self) { option in
                            Button { pick(option) } label: {
                                Text(option).font(BB.Font.monoSmall)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(BB.Palette.surfaceHigh))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(BB.Palette.textPrimary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BB.Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BB.Palette.stroke))
        .accessibilityIdentifier("command.argumentHelp")
    }
}

struct PendingAttachmentRow: View {
    @Binding var attachments: [PendingAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    HStack(spacing: 8) {
                        if let data = item.thumbnail, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: item.kind == .image ? "photo" : "doc").frame(width: 24)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(BB.Font.caption).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                            switch item.state {
                            case .preparing: Text("Preparing…").font(.system(size: 10)).foregroundStyle(BB.Palette.textTertiary)
                            case .uploading(let p): ProgressView(value: p).frame(width: 80)
                            case .ready: Text(item.kind == .image ? "Ready · sent inline" : "On your server").font(.system(size: 10)).foregroundStyle(BB.Palette.textTertiary)
                            case .failed(let reason): Text(reason).font(.system(size: 10)).foregroundStyle(BB.Palette.danger).lineLimit(2).frame(maxWidth: 140, alignment: .leading)
                            }
                        }
                        Button { attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(BB.Palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BB.Palette.surfaceHigh))
                    .foregroundStyle(BB.Palette.textPrimary)
                }
            }
        }
    }
}

/// Instructions waiting for the running reply to end.
struct QueuedInstructionsView: View {
    let items: [ChatStore.QueuedInstruction]
    let canSendNow: Bool
    let remove: (UUID) -> Void
    let sendNow: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.afterInterrupt ? "stop.circle" : "text.append").foregroundStyle(BB.Palette.textTertiary)
                    Text(item.text).font(BB.Font.caption).foregroundStyle(BB.Palette.textPrimary).lineLimit(1)
                    Spacer()
                    Text(item.afterInterrupt ? "after stop" : "next").font(BB.Font.label).foregroundStyle(BB.Palette.textTertiary)
                    if canSendNow {
                        Button("Send") { sendNow(item.id) }.font(BB.Font.caption)
                    }
                    Button { remove(item.id) } label: { Image(systemName: "xmark") }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(BB.Palette.textTertiary)
                        .accessibilityLabel("Remove queued instruction")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BB.Palette.surfaceSunken))
            }
        }
        .padding(.horizontal, BB.Space.gutter)
        .accessibilityIdentifier("composer.queue")
    }
}
