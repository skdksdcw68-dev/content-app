import AVFoundation
import SwiftUI

/// Plays one voice sample at a time.
@MainActor
@Observable
final class VoiceSamplePlayer {
    static let shared = VoiceSamplePlayer()

    /// The voice playing now, nil when quiet.
    private(set) var playing: String?
    private var player: AVPlayer?
    private var finished: NSObjectProtocol?

    func toggle(_ sample: VoiceSample) {
        if playing == sample.id {
            stop()
            return
        }
        stop()
        guard let url = URL(string: sample.preview) else { return }

        // Plays over the silent switch, as a sample somebody asked to hear.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playing = sample.id
        finished = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playing = nil
        if let finished { NotificationCenter.default.removeObserver(finished) }
        finished = nil
    }
}

/// "Show me some voices": each with a play button and what it sounds like.
/// Abel, 2 Nov 2026: "the user can say show me some voices and does this show?"
struct VoicesCard: View {
    let voices: [VoiceSample]
    private let player = VoiceSamplePlayer.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(voices.enumerated()), id: \.element.id) { index, voice in
                if index > 0 { Divider().padding(.leading, 58) }
                row(voice)
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onDisappear { player.stop() }
    }

    private func row(_ voice: VoiceSample) -> some View {
        let isPlaying = player.playing == voice.id
        return Button {
            player.toggle(voice)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !voice.about.isEmpty {
                        Text(voice.about)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isPlaying ? "Stop" : "Play") \(voice.name)")
    }
}
