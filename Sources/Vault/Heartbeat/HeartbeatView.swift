import SwiftUI

/// "Us" tab centerpiece: a heart that beats visually and on the Taptic Engine
/// at the partner's recorded BPM while it is held / after it is tapped.
struct HeartbeatView: View {
    /// Recorded BPM of the partner. MVP: stored with the pair, set once.
    let bpm: Double
    var caption: String = "Zorlandığında bas."

    @State private var player = HeartbeatPlayer()
    @State private var playing = false
    @State private var pulse = false

    private var period: Double { 60.0 / min(max(bpm, 40), 180) }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Button(action: toggle) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(WatchlinkStyle.tint)
                    .scaleEffect(pulse ? 1.12 : 1.0)
                    .frame(width: 240, height: 240)
                    .background(WatchlinkStyle.soft, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Kalp atışını durdur" : "Kalp atışını hisset")

            VStack(spacing: 6) {
                Text(caption).font(.system(size: 17, weight: .semibold))
                Text("\(Int(bpm.rounded())) bpm")
                    .font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(WatchlinkStyle.background.ignoresSafeArea())
        .foregroundStyle(WatchlinkStyle.text)
        .onDisappear(perform: stop)
    }

    private func toggle() { playing ? stop() : start() }

    private func start() {
        try? player.play(bpm: bpm, duration: 20)
        playing = true
        withAnimation(.easeOut(duration: period * 0.35).repeatForever(autoreverses: true)) { pulse = true }
        Task {
            try? await Task.sleep(for: .seconds(20))
            if playing { stop() }
        }
    }

    private func stop() {
        player.stop()
        playing = false
        withAnimation(.easeOut(duration: 0.2)) { pulse = false }
    }
}

#Preview { HeartbeatView(bpm: 72) }
