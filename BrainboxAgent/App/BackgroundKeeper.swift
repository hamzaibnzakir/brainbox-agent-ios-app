import AVFoundation
import UIKit

/// Keeps Brainbox (and its SSH connection) running while you're in another app — the way
/// Termius does — until you swipe it away. iOS suspends ordinary apps ~30 s after they leave
/// the screen, which kills the SSH socket; an app playing audio is not suspended, so while in
/// the background Brainbox plays a silent loop mixed under anything else you're listening to.
/// Turn it off in Settings › Security to let iOS suspend the app instead.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observer: NSObjectProtocol?
    private(set) var active = false

    func enterBackground(keepAlive: Bool) {
        // A grace period either way, so a turn in flight can land.
        if task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "brainbox-ssh") { [weak self] in
                Task { @MainActor in self?.endTask() }
            }
        }
        guard keepAlive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
            active = true
        } catch {
            active = false
        }
        if observer == nil {
            // A call or Siri interrupts audio; resume the silent loop afterwards.
            observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                Task { @MainActor in
                    guard let self, self.active else { return }
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.player?.play()
                }
            }
        }
    }

    func enterForeground() {
        if active {
            player?.stop()
            player = nil
            active = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        endTask()
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
    static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000, samples: UInt32 = 8000, bytesPerSample: UInt16 = 2
        let dataSize = samples * UInt32(bytesPerSample)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate)
        u32(sampleRate * UInt32(bytesPerSample)); u16(bytesPerSample); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }()
}
