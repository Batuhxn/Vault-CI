import AVFoundation
import Observation

/// Records a voice message: AAC, mono, 22 kHz, 32 kbps (about 4 KB a second,
/// so the two-minute limit stays well under the 900 KB sealed-blob ceiling).
/// While recording it samples the input level ~20 times a second; those levels
/// draw the live bars and, downsampled, become the message's waveform.
@MainActor @Observable
final class VoiceRecorder {
    static let maxSeconds: TimeInterval = 120
    static let minSeconds: TimeInterval = 0.6

    struct Recording {
        let data: Data
        let seconds: Double
        /// 40 bars, 0...255, sealed with the message so the bubble draws without downloading.
        let wave: [UInt8]
    }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Live input levels, 0...1, oldest first.
    private(set) var levels: [Float] = []
    /// Called when the two-minute limit stops the recording on its own.
    @ObservationIgnored var onLimit: (() -> Void)?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var meter: Task<Void, Never>?

    /// Asks for the microphone once (iOS remembers), then starts. False if refused or failed.
    func start() async -> Bool {
        guard !isRecording else { return true }
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.maxSeconds) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            self.url = url
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
        isRecording = true
        elapsed = 0
        levels = []
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let recorder = self.recorder else { return }
                guard recorder.isRecording else { self.onLimit?(); return }
                recorder.updateMeters()
                // -50 dB and below reads as silence; 0 dB is full scale.
                let level = (recorder.averagePower(forChannel: 0) + 50) / 50
                self.levels.append(min(max(level, 0), 1))
                self.elapsed = recorder.currentTime
            }
        }
        return true
    }

    /// Stops and returns the recording, or nil if it was too short to be meant.
    func stop() -> Recording? {
        guard isRecording, let recorder, let url else { cancel(); return nil }
        let seconds = max(recorder.currentTime, elapsed)
        recorder.stop()
        let wave = Self.wave(levels, bars: 40)
        teardown()
        defer { try? FileManager.default.removeItem(at: url) }
        guard seconds >= Self.minSeconds, let data = try? Data(contentsOf: url) else { return nil }
        return Recording(data: data, seconds: seconds, wave: wave)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        teardown()
    }

    private func teardown() {
        meter?.cancel()
        meter = nil
        recorder = nil
        url = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Averages the live levels into `bars` buckets, scaled to 0...255.
    static func wave(_ levels: [Float], bars: Int) -> [UInt8] {
        guard !levels.isEmpty else { return Array(repeating: 20, count: bars) }
        return (0..<bars).map { bar in
            let lo = bar * levels.count / bars
            let hi = max(lo + 1, (bar + 1) * levels.count / bars)
            let slice = levels[min(lo, levels.count - 1)..<min(hi, levels.count)]
            let mean = slice.reduce(0, +) / Float(max(slice.count, 1))
            return UInt8(min(max(mean, 0.06), 1) * 255)
        }
    }
}

/// Plays one voice message at a time (starting another stops the first).
/// Plays through the speaker even with the ring switch on silent, like other messengers.
@MainActor @Observable
final class VoicePlayer {
    static let shared = VoicePlayer()

    private(set) var playingID: String?
    /// 0...1 through the current message.
    private(set) var progress: Double = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func toggle(id: String, data: Data) {
        if playingID == id { stop(); return }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: data)
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            self.player = player
            playingID = id
            progress = 0
        } catch {
            stop()
            return
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { return }
                guard player.isPlaying else { self.stop(); return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
