import AVFoundation
import CoreTransferable
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Talking into the chat bar.
///
/// Abel, 5 Nov 2026: the old bar recorded a file, sent it to a server and sat on
/// "Listening..." until the words came back. Now the phone writes the words down
/// while you talk (Apple's speech recognition, on the phone when it can), shows
/// them above the waveform, and the check puts them in the field the moment you
/// tap it. The sound is also kept in a small file: if speech recognition is
/// refused or unavailable, that file goes to the server the old way.
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var seconds = 0
    /// How loud the last moments were, 0 to 1, newest last: the waveform the
    /// bar draws while you talk, the way ChatGPT shows it.
    private(set) var levels: [Float] = Array(repeating: 0, count: VoiceRecorder.bars)
    /// The words heard so far. Empty while nothing has been heard, or for good
    /// when speech recognition is not available.
    private(set) var liveText = ""
    static let bars = 40

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var ticker: Task<Void, Never>?
    private var finalHeard = false
    private(set) var fileURL: URL?

    /// Starts listening. False when the microphone was refused, so the caller
    /// can say so rather than sit silent. Speech recognition being refused is
    /// not a failure: the sound is still recorded.
    func start() async -> Bool {
        guard !isRecording else { return true }
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let speech = await Self.speechAllowed()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-\(UUID().uuidString).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)

            var listening: SFSpeechAudioBufferRecognitionRequest?
            if speech, let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(), recognizer.isAvailable {
                let made = SFSpeechAudioBufferRecognitionRequest()
                made.shouldReportPartialResults = true
                if recognizer.supportsOnDeviceRecognition { made.requiresOnDeviceRecognition = true }
                listening = made
                finalHeard = false
                task = recognizer.recognitionTask(with: made) { [weak self] result, _ in
                    let words = result?.bestTranscription.formattedString
                    let done = result?.isFinal ?? false
                    Task { @MainActor in
                        guard let self else { return }
                        if let words { self.liveText = words }
                        if done { self.finalHeard = true }
                    }
                }
            }
            request = listening
            let sink = listening

            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                try? file.write(from: buffer)
                sink?.append(buffer)
                let level = Self.level(of: buffer)
                Task { @MainActor in self?.push(level) }
            }
            engine.prepare()
            try engine.start()

            self.engine = engine
            fileURL = url
            seconds = 0
            liveText = ""
            levels = Array(repeating: 0, count: Self.bars)
            isRecording = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isRecording else { return }
                    self.seconds += 1
                }
            }
            return true
        } catch {
            teardown()
            return false
        }
    }

    /// Stops, and hands back what was said: the words when they were heard, else
    /// the sound file for the server -- nil when nothing worth keeping (under a
    /// second) was said.
    func finish() async -> (words: String, file: URL?) {
        guard isRecording else { return ("", nil) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        // The last few words arrive just after the audio ends.
        if request != nil {
            for _ in 0..<14 where !finalHeard {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let words = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = seconds >= 1 ? fileURL : nil
        let url = fileURL
        teardown()
        if let url, !words.isEmpty || kept == nil { try? FileManager.default.removeItem(at: url) }
        return (words, words.isEmpty ? kept : nil)
    }

    /// Stops and throws the recording away.
    func cancel() {
        let url = fileURL
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        teardown()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    var clock: String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func push(_ level: Float) {
        guard isRecording else { return }
        levels = Array(levels.dropFirst()) + [level]
    }

    private func teardown() {
        task?.cancel()
        task = nil
        request = nil
        engine = nil
        ticker?.cancel()
        ticker = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }

    /// Loudness of one buffer, 0 to 1: -50 dB is silence enough, 0 dB is as loud
    /// as it gets.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 50))
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
