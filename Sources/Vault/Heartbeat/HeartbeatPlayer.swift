import CoreHaptics
import Foundation

/// Plays a "lub-dub" heartbeat on the iPhone's Taptic Engine at a given BPM.
///
/// MVP: the BPM is a recorded value (no live stream). Each beat is two
/// transients: a strong "lub" and a softer "dub" ~140 ms later. The pattern
/// loops until `stop()` or until `duration` runs out.
@MainActor
final class HeartbeatPlayer {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var stopTask: Task<Void, Never>?

    var isSupported: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    /// - Parameters:
    ///   - bpm: Beats per minute, clamped to 40...180.
    ///   - duration: Seconds to play; `nil` loops until `stop()`.
    func play(bpm: Double, duration: TimeInterval? = 20) throws {
        stop()
        guard isSupported else { return }

        let engine = try self.engine ?? CHHapticEngine()
        engine.isAutoShutdownEnabled = true
        engine.resetHandler = { [weak engine] in try? engine?.start() }
        try engine.start()
        self.engine = engine

        let period = 60.0 / min(max(bpm, 40), 180)
        let pattern = try CHHapticPattern(events: Self.beat(), parameters: [])
        let player = try engine.makeAdvancedPlayer(with: pattern)
        player.loopEnabled = true
        player.loopEnd = period
        try player.start(atTime: CHHapticTimeImmediate)
        self.player = player

        if let duration {
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    private static func beat() -> [CHHapticEvent] {
        func tap(_ time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time)
        }
        return [
            tap(0.00, intensity: 1.0, sharpness: 0.25), // lub
            tap(0.14, intensity: 0.6, sharpness: 0.15), // dub
        ]
    }
}
