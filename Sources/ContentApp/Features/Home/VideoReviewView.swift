import AVFoundation
import AVKit
import SwiftUI

/// A video from Home, opened to be looked at and then worked on: the frames
/// along the top with two handles, the video with rounded corners, and
/// Cancel · play · Next along the bottom. Next takes the chosen range into
/// the editor, and from there to posting.
///
/// Abel, 23 Sep 2026, against the Posh "Choose Video" screen: "opening a
/// video should be as the 3rd screenshot with a next button so he can
/// manage things; the current has no option, just watch it; make it curved
/// and beautiful."
///
/// The file is the post's own video from storage, brought to the phone
/// once; the editor works on local files.
struct VideoReviewView: View {
    let post: BoardPost

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var file: URL?
    @State private var missing = false
    @State private var duration: Double = 0
    @State private var frames: [UIImage] = []
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var position: Double = 0
    @State private var editing: EditSession?

    struct EditSession: Identifiable, Hashable {
        let id = UUID()
        let clip: StudioClip
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TrimStrip(
                    frames: frames,
                    duration: duration,
                    start: $trimStart,
                    end: $trimEnd,
                    position: position
                )
                // Google Photos' size: a strip you can actually hold.
                .frame(height: 92)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .onChange(of: trimStart) { _, at in seek(to: at) }
                .onChange(of: trimEnd) { _, at in seek(to: at) }

                ZStack {
                    if let player {
                        VideoPlayer(player: player)
                            .disabled(true)
                    } else if missing {
                        VStack(spacing: 10) {
                            Image(systemName: "film")
                                .font(.system(size: 30, weight: .light))
                            Text("No video yet")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                    } else {
                        ProgressView("Getting the video…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onTapGesture { togglePlay() }

                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.body)
                        .foregroundStyle(.white)

                    Spacer()

                    Button { togglePlay() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                    }
                    .disabled(player == nil)
                    .accessibilityLabel(playing ? "Pause" : "Play")

                    Spacer()

                    Button("Next") { next() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .disabled(file == nil)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 8)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(post.hook.isEmpty ? "Video" : post.hook)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .navigationDestination(item: $editing) { session in
                EditorView(clips: [session.clip])
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    // MARK: - The file

    private func load() async {
        guard let media = post.media, let signed = await session.mediaURL(media) else {
            missing = true
            return
        }
        do {
            let (downloaded, _) = try await URLSession.shared.download(from: signed)
            let ext = (media.mime ?? "").contains("quicktime") ? "mov" : "mp4"
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("review-\(post.id.uuidString).\(ext)")
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: downloaded, to: local)
            file = local

            let asset = AVURLAsset(url: local)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            duration = seconds.isFinite ? seconds : 0
            trimStart = 0
            trimEnd = duration

            let made = AVPlayer(url: local)
            made.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
                MainActor.assumeIsolated {
                    position = time.seconds
                    // Loop inside the chosen range, so what is being trimmed
                    // is what plays.
                    if time.seconds >= trimEnd, trimEnd > trimStart {
                        made.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))
                    }
                }
            }
            player = made
            frames = await Self.frames(of: asset, count: 10)
        } catch {
            missing = true
        }
    }

    private static func frames(of asset: AVURLAsset, count: Int) async -> [UIImage] {
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [UIImage] = []
        for index in 0..<count {
            let at = seconds * (Double(index) + 0.5) / Double(count)
            if let cg = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }

    // MARK: - Playing

    private func togglePlay() {
        guard let player else { return }
        if playing {
            player.pause()
        } else {
            if position < trimStart || position >= trimEnd {
                player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))
            }
            player.play()
        }
        playing.toggle()
    }

    private func seek(to seconds: Double) {
        player?.pause()
        playing = false
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func next() {
        guard let file else { return }
        player?.pause()
        playing = false
        editing = EditSession(clip: StudioClip(
            kind: .video,
            url: file,
            sourceDuration: duration,
            trimStart: trimStart,
            trimEnd: trimEnd > trimStart ? trimEnd : duration
        ))
    }
}

// MARK: - The strip

/// The video's frames in a row, a bracket around the chosen part with a
/// handle at each end, and a line where playback is. Polarsteps' trim,
/// Google Photos' handles.
private struct TrimStrip: View {
    let frames: [UIImage]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let position: Double

    private let handleWidth: CGFloat = 22
    private let minimumSeconds: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let scale = duration > 0 ? width / duration : 0
            let left = CGFloat(start) * scale
            let right = CGFloat(end) * scale
            let pill = RoundedRectangle(cornerRadius: height / 2, style: .continuous)

            ZStack(alignment: .leading) {
                // Frames, dimmed outside the chosen part.
                HStack(spacing: 0) {
                    if frames.isEmpty {
                        Rectangle().fill(Color(white: 0.2))
                    } else {
                        ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(frames.count), height: height)
                                .clipped()
                        }
                    }
                }
                .clipShape(pill)

                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, left))
                    .clipShape(pill)
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, width - right))
                    .offset(x: right)
                    .clipShape(pill)

                // The bracket: a thick white frame with rounded ends, the
                // handles being its two ends.
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: max(handleWidth * 2, right - left))
                    .offset(x: left)

                handle(height: height, leading: true)
                    .offset(x: left)
                    .gesture(drag(scale: scale, width: width, leading: true))
                handle(height: height, leading: false)
                    .offset(x: right - handleWidth)
                    .gesture(drag(scale: scale, width: width, leading: false))

                // Playhead.
                if duration > 0 {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white)
                        .frame(width: 3, height: height + 8)
                        .offset(x: min(max(CGFloat(position) * scale, left + handleWidth), right - handleWidth) - 1.5)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trim, from \(Int(start)) to \(Int(end)) seconds")
    }

    private func handle(height: CGFloat, leading: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: leading ? height / 2 : 0,
            bottomLeadingRadius: leading ? height / 2 : 0,
            bottomTrailingRadius: leading ? 0 : height / 2,
            topTrailingRadius: leading ? 0 : height / 2,
            style: .continuous
        )
        .fill(.white)
        .frame(width: handleWidth)
        .overlay {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 3, height: 26)
        }
        .contentShape(Rectangle().inset(by: -12))
    }

    private func drag(scale: CGFloat, width: CGFloat, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard scale > 0 else { return }
                let seconds = Double(min(max(value.location.x, 0), width) / scale)
                if leading {
                    start = min(seconds, end - minimumSeconds)
                } else {
                    end = max(seconds, start + minimumSeconds)
                }
                start = max(0, start)
                end = min(duration, end)
            }
    }
}
