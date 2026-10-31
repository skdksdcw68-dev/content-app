import AVFoundation
import Observation

/// Plays a voice's sample on the voiceover step. One at a time: starting a
/// second stops the first, and tapping the one that is playing stops it.
///
/// Streams ElevenLabs' public sample rather than shipping it, so a voice can
/// be swapped in `SeriesVoice.all` without a new asset.
@MainActor
@Observable
final class VoiceSampler {
    /// The voice whose sample is playing, if any.
    private(set) var playing: String?

    private var player: AVPlayer?
    private var finished: NSObjectProtocol?

    func toggle(_ voice: SeriesVoice) {
        if playing == voice.id {
            stop()
            return
        }
        stop()
        guard let url = voice.sample else { return }

        PlaybackAudio.sound(true)
        // 🔴 Some of ElevenLabs' samples are served as `text/plain` although
        // they are MP3s (checked 31 Oct 2026: they start with an ID3 tag), and
        // AVPlayer believes the header over the file name.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "audio/mpeg"])
        let item = AVPlayerItem(asset: asset)
        let next = AVPlayer(playerItem: item)
        finished = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player = next
        playing = voice.id
        next.play()
    }

    func stop() {
        player?.pause()
        player = nil
        if let finished { NotificationCenter.default.removeObserver(finished) }
        finished = nil
        playing = nil
    }
}
