import AVFoundation
import Observation
import SwiftUI

/// A voice or a track, played the way Telegram plays a voice message.
///
/// Abel, 4 Nov 2026: "match the way it downloads the voice first, saves it
/// locally, and whenever the user opens it, it plays." So the file comes down
/// once with a ring on the button, is kept on the phone (MediaCache), and the
/// tap plays the phone's copy at once. The waveform is measured from that
/// copy: until it is here the bars are flat, never invented.
@MainActor
@Observable
final class VoicePlayback {
    enum Stage: Equatable {
        case absent
        case downloading(Double?)
        case ready
        case failed
    }

    static let barCount = 28
    static let flat: [Float] = Array(repeating: 0.22, count: barCount)

    private(set) var stage: Stage = .absent
    private(set) var bars: [Float] = VoicePlayback.flat
    private(set) var hasWave = false
    private(set) var playing = false
    private(set) var elapsed: Double = 0
    private(set) var length: Double?
    private(set) var received: Int64 = 0
    private(set) var expected: Int64?
    private(set) var rate: Float = 1

    private var file: URL?
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    private var loading: Task<Void, Never>?

    var progress: Double {
        guard let length, length > 0 else { return 0 }
        return min(1, elapsed / length)
    }

    var rateLabel: String { rate == 1 ? "1×" : rate == 1.5 ? "1.5×" : "2×" }

    /// What the line under the waveform says.
    var caption: String {
        switch stage {
        case .downloading:
            return "\(Self.size(received)) of \(expected.map(Self.size) ?? "…")"
        case .failed:
            return "Couldn't download · tap to try again"
        case .absent, .ready:
            if playing || elapsed > 0 {
                return "\(Self.clock(elapsed)) / \(Self.clock(length ?? 0))"
            }
            return [length.map(Self.clock), expected.map(Self.size)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Already on the phone: ready at once, with no round trip.
    func look(_ artifact: Artifact, in session: AppSession) {
        guard file == nil else { return }
        if length == nil, let seconds = artifact.body.seconds, seconds > 0 { length = seconds }
        if expected == nil, let bytes = artifact.byteSize { expected = Int64(bytes) }
        if let here = session.cachedCopy(of: artifact) { arrived(here) }
    }

    /// Brings it down and keeps it on the phone, then plays if asked to.
    func fetch(_ artifact: Artifact, in session: AppSession, thenPlay: Bool = false) {
        if file != nil {
            if thenPlay, !playing { toggle() }
            return
        }
        guard loading == nil else { return }
        stage = .downloading(nil)
        loading = Task { [weak self] in
            for await step in session.fileStream(of: artifact) {
                guard let self else { return }
                switch step {
                case .progress(let got, let total):
                    self.received = got
                    if let total, total > 0 {
                        self.expected = total
                        self.stage = .downloading(Double(got) / Double(total))
                    }
                case .done(let url):
                    self.arrived(url)
                    if thenPlay { self.toggle() }
                case .failed:
                    self.stage = .failed
                }
            }
            self?.loading = nil
        }
    }

    func toggle() {
        if playing {
            player?.pause()
            playing = false
            ticker?.cancel()
            return
        }
        guard let file else { return }
        if player == nil {
            let made = try? AVAudioPlayer(contentsOf: file)
            made?.enableRate = true
            made?.prepareToPlay()
            player = made
        }
        guard let player else { return }
        PlaybackAudio.sound(true)
        player.rate = rate
        if player.duration > 0 { length = player.duration }
        player.play()
        playing = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.tick()
            }
        }
    }

    func cycleRate() {
        rate = rate == 1 ? 1.5 : rate == 1.5 ? 2 : 1
        player?.rate = rate
    }

    func stop() {
        player?.pause()
        if playing { PlaybackAudio.sound(false) }
        playing = false
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        elapsed = player.currentTime
        if playing, !player.isPlaying {
            // It reached the end.
            playing = false
            elapsed = 0
            player.currentTime = 0
            ticker?.cancel()
            PlaybackAudio.sound(false)
        }
    }

    private func arrived(_ url: URL) {
        file = url
        stage = .ready
        Task.detached(priority: .utility) { [weak self] in
            let wave = VoicePlayback.wave(of: url, bars: VoicePlayback.barCount)
            let seconds = (try? AVAudioPlayer(contentsOf: url))?.duration
            await self?.show(wave: wave, seconds: seconds)
        }
    }

    private func show(wave: [Float], seconds: Double?) {
        if let seconds, seconds > 0 { length = seconds }
        guard wave.count == Self.barCount else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            bars = wave
            hasWave = true
        }
    }

    /// The loudness of each slice of the file, read in chunks so a long track
    /// never sits in memory whole.
    nonisolated static func wave(of url: URL, bars: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let total = file.length
        let perBar = max(1, total / Int64(bars))
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        var sums = [Float](repeating: 0, count: bars)
        var counts = [Int](repeating: 0, count: bars)
        var position: Int64 = 0
        while position < total {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let samples = buffer.floatChannelData?[0] else { break }
            var index = 0
            while index < frames {
                let bar = min(bars - 1, Int((position + Int64(index)) / perBar))
                let value = samples[index]
                sums[bar] += value * value
                counts[bar] += 1
                index += 16
            }
            position += Int64(frames)
        }
        let levels = (0..<bars).map { counts[$0] > 0 ? (sums[$0] / Float(counts[$0])).squareRoot() : 0 }
        guard let peak = levels.max(), peak > 0 else { return [] }
        return levels.map { max(0.12, $0 / peak) }
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    nonisolated static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The round button: a download arrow, the ring while it comes down, then
/// play and pause.
struct VoiceButton: View {
    let playback: VoicePlayback
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent)
            switch playback.stage {
            case .downloading(let fraction):
                Circle()
                    .stroke(Theme.onAccent.opacity(0.25), lineWidth: 2.5)
                    .padding(4)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                        .animation(.linear(duration: 0.2), value: fraction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.onAccent)
                }
            case .absent, .failed:
                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
            case .ready:
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Bars for how loud each part is; the played part in the accent.
struct VoiceWaveform: View {
    let bars: [Float]
    let played: Double
    let live: Bool
    var height: CGFloat = 26

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(Double(index) / Double(max(1, bars.count)) < played
                          ? Theme.accent
                          : Color.secondary.opacity(live ? 0.55 : 0.3))
                    .frame(width: 3, height: max(3, CGFloat(level) * height))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One sound in the Library's Audio list: Telegram's shared-voices row.
struct VoiceListRow: View {
    let artifact: Artifact

    @Environment(AppSession.self) private var session
    @State private var playback = VoicePlayback()

    var body: some View {
        HStack(spacing: 12) {
            Button(action: tap) {
                VoiceButton(playback: playback, size: 38)
            }
            .buttonStyle(PressButtonStyle())
            .accessibilityLabel(playback.stage == .ready ? (playback.playing ? "Pause" : "Play") : "Download and play")

            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.body.prompt ?? artifact.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if playback.playing || playback.elapsed > 0 {
                    VoiceWaveform(bars: playback.bars, played: playback.progress, live: playback.hasWave, height: 16)
                } else {
                    Text(artifact.body.modelLabel ?? "Voice")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(playback.length.map(VoicePlayback.clock) ?? "")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .task(id: artifact.id) { playback.look(artifact, in: session) }
        .onDisappear { playback.stop() }
    }

    private func tap() {
        switch playback.stage {
        case .ready: playback.toggle()
        case .downloading: break
        case .absent, .failed: playback.fetch(artifact, in: session, thenPlay: true)
        }
    }
}
