import AVFoundation
import BrainboxCore
import Foundation
import HermesKit
import Observation

/// Voice through Hermes' own audio endpoints (the same ones Desktop uses):
/// speech-to-text with `/api/audio/transcribe`, replies read aloud with
/// `/api/audio/speak`. Keys stay on the server; the phone only records and plays.
@MainActor
@Observable
final class Voice: NSObject, AVAudioPlayerDelegate {
    static let shared = Voice()

    enum Phase: Equatable { case idle, recording, transcribing, speaking, failed(String) }
    var phase: Phase = .idle
    /// 0…1 microphone level while recording.
    var level: Double = 0
    /// Hands-free loop: listen → send → speak the reply → listen again.
    var conversation = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meter: Task<Void, Never>?
    private var silenceSince: Date?
    private var heardSpeech = false
    private weak var model: AppModel?

    private var fileURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("brainbox-voice.m4a") }

    func startRecording(model: AppModel) async {
        self.model = model
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Microphone access is off. Turn it on in Settings › Brainbox.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                           AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            phase = .recording
            heardSpeech = false
            silenceSince = nil
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    await self?.tickMeter()
                }
            }
        } catch {
            phase = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func tickMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let db = Double(recorder.averagePower(forChannel: 0))
        level = max(0, min(1, (db + 55) / 45))
        // In conversation mode, stop after ~1.2 s of quiet once speech was heard.
        guard conversation else { return }
        if level > 0.25 { heardSpeech = true; silenceSince = nil }
        else if heardSpeech {
            if silenceSince == nil { silenceSince = Date() }
            if let since = silenceSince, Date().timeIntervalSince(since) > 1.2 {
                Task { await self.finishRecording() }
            }
        }
    }

    func cancelRecording() {
        meter?.cancel()
        recorder?.stop()
        recorder = nil
        phase = .idle
        conversation = false
    }

    /// Stops recording, transcribes on the server, and sends the text to the chat.
    func finishRecording() async {
        guard let recorder else { return }
        meter?.cancel()
        recorder.stop()
        self.recorder = nil
        level = 0
        guard let model else { phase = .idle; return }
        guard let data = try? Data(contentsOf: fileURL), data.count > 2000 else {
            phase = conversation ? .idle : .failed("That was too short to hear.")
            if conversation { await startRecording(model: model) }
            return
        }
        phase = .transcribing
        do {
            let client = try await model.client()
            let body: JSONValue = ["data_url": .string("data:audio/mp4;base64," + data.base64EncodedString()), "mime_type": "audio/mp4"]
            let result = try await client.send("POST", "/api/audio/transcribe", json: body, timeout: 120)
            let text = (result["transcript"]?.stringValue ?? result["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .idle
            if text.isEmpty {
                if conversation { await startRecording(model: model) }
                return
            }
            await model.send(text)
        } catch {
            phase = .failed(error.localizedDescription)
            conversation = false
        }
    }

    /// Reads a reply aloud using Hermes' configured TTS voice.
    func speak(_ text: String, using model: AppModel) async {
        self.model = model
        let plain = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code omitted) ", options: .regularExpression)
            .replacingOccurrences(of: "[*_#`>]", with: "", options: .regularExpression)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let client = try await model.client()
            let result = try await client.send("POST", "/api/audio/speak", json: ["text": .string(String(plain.prefix(4000)))], timeout: 120)
            guard let audio = Self.findAudio(result) else { return }
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            self.player = player
            phase = .speaking
            player.play()
        } catch {
            phase = .failed("Couldn't play the reply: \(error.localizedDescription)")
        }
    }

    func stopSpeaking() {
        player?.stop()
        player = nil
        if phase == .speaking { phase = .idle }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.phase = .idle
            if self.conversation, let model = self.model { await self.startRecording(model: model) }
        }
    }

    /// Finds base64 audio in Hermes' speak response (a data URL or a base64 field).
    static func findAudio(_ json: JSONValue) -> Data? {
        switch json {
        case .string(let s):
            if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") { return Data(base64Encoded: String(s[s.index(after: comma)...])) }
            return nil
        case .object(let o):
            for key in ["data_url", "audio", "audio_base64", "url"] {
                if let v = o[key], let d = findAudio(v) { return d }
                if key == "audio_base64", let s = o[key]?.stringValue { return Data(base64Encoded: s) }
            }
            for v in o.values { if let d = findAudio(v) { return d } }
            return nil
        default:
            return nil
        }
    }
}
