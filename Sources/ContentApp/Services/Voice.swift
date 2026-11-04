import AVFoundation
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Recording a voice note in the chat bar.
///
/// Abel, 2 Nov 2026: "make sure it can also send voices ... like when I send it
/// a video, it extracts and transcribes it." A voice note is recorded here as
/// AAC in an .m4a file -- small enough to upload on a phone connection -- and
/// the words come back from the `transcribe` function and land in the field.
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var seconds = 0
    /// How loud the last moments were, 0 to 1, newest last: the waveform the
    /// bar draws while you talk, the way ChatGPT shows it.
    private(set) var levels: [Float] = Array(repeating: 0, count: VoiceRecorder.bars)
    static let bars = 40

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private(set) var fileURL: URL?

    /// Starts recording. False when the microphone was refused, so the caller
    /// can say so rather than sit silent.
    func start() async -> Bool {
        guard !isRecording else { return true }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { return false }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return false }

            self.recorder = recorder
            fileURL = url
            seconds = 0
            levels = Array(repeating: 0, count: Self.bars)
            isRecording = true
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard let self, self.isRecording, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    // -50 dB is silence enough; 0 dB is as loud as it gets.
                    let level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
                    self.levels = Array(self.levels.dropFirst()) + [level]
                }
            }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isRecording else { return }
                    self.seconds += 1
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Stops, and hands back the file -- nil when nothing worth sending was
    /// said (under a second).
    func stop() -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        recorder = nil
        ticker?.cancel()
        ticker = nil
        meter?.cancel()
        meter = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let kept = seconds >= 1 ? fileURL : nil
        if kept == nil, let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        return kept
    }

    /// Stops and throws the recording away.
    func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
    }

    var clock: String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A video picked from the library, copied somewhere we can read it.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

enum VideoAudio {
    /// What a video says, as a small .m4a: the sound track on its own. A video
    /// is hundreds of megabytes; its audio is a few, and that is all a
    /// transcript needs. Nil when the video has no sound.
    static func extract(from video: URL) async -> (audio: URL, seconds: Int, poster: UIImage?)? {
        let asset = AVURLAsset(url: video)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return nil }
        guard let duration = try? await asset.load(.duration) else { return nil }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        do {
            try await export.export(to: out, as: .m4a)
        } catch {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let poster = try? await generator.image(at: .zero).image
        return (out, Int(duration.seconds.rounded()), poster.map { UIImage(cgImage: $0) })
    }
}

/// How a transcript rides inside a message, so the conversation reads back
/// whole on any device and the model, which only ever sees text, can answer
/// questions about it a message later. The bubble splits on this line and draws
/// the transcript as a quiet block instead of a wall of words.
enum Transcript {
    static let marker = "\n\nTranscript of the video I sent:\n"

    static func compose(typed: String, transcripts: [String]) -> String {
        guard !transcripts.isEmpty else { return typed }
        let joined = transcripts.enumerated()
            .map { transcripts.count > 1 ? "Video \($0.offset + 1): \($0.element)" : $0.element }
            .joined(separator: "\n\n")
        return typed + marker + joined
    }

    /// What they typed, and the transcript if there was one.
    static func split(_ text: String) -> (typed: String, transcript: String?) {
        guard let range = text.range(of: marker) else { return (text, nil) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
}
