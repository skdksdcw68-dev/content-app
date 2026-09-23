import AVFoundation
import SwiftUI

/// The video's frames in one row that always fits the whole video, a white
/// bracket around the chosen part with a chunky handle at each end, and a
/// thin line where playback is that can be dragged. Google Photos' trim,
/// Polarsteps' playhead (Abel, 23 Sep 2026: "no matter how long the video
/// is, it fits the width; and the moving line too, the native one looks a
/// little weird").
///
/// Shared by the video review screen and the Studio editor.
struct TrimStrip: View {
    let frames: [UIImage]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// Where playback is, in seconds.
    let position: Double
    /// The person dragged the playhead: seek here. Nil makes it read-only.
    var onScrub: ((Double) -> Void)? = nil
    var onScrubEnded: (() -> Void)? = nil
    /// Dims the frames outside the chosen part. Off when the strip is one
    /// clip of several and the whole row is "the video".
    var dimsOutside = true

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
                FrameRow(frames: frames, width: width, height: height)
                    .clipShape(pill)
                    // The playhead: a drag anywhere on the frames scrubs.
                    .gesture(scrub(scale: scale, width: width))

                if dimsOutside {
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: max(0, left))
                        .clipShape(pill)
                        .allowsHitTesting(false)
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: max(0, width - right))
                        .offset(x: right)
                        .clipShape(pill)
                        .allowsHitTesting(false)
                }

                // The bracket: a thick white frame with rounded ends, the
                // handles being its two ends.
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: max(handleWidth * 2, right - left))
                    .offset(x: left)
                    .allowsHitTesting(false)

                handle(height: height, leading: true)
                    .offset(x: left)
                    .gesture(drag(scale: scale, width: width, leading: true))
                handle(height: height, leading: false)
                    .offset(x: right - handleWidth)
                    .gesture(drag(scale: scale, width: width, leading: false))

                if duration > 0 {
                    Playhead(height: height + 8)
                        .offset(x: min(max(CGFloat(position) * scale, left + handleWidth), right - handleWidth) - 1.5)
                        .allowsHitTesting(false)
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

    private func scrub(scale: CGFloat, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard scale > 0, let onScrub else { return }
                let seconds = Double(min(max(value.location.x, 0), width) / scale)
                onScrub(min(max(seconds, start), end))
            }
            .onEnded { _ in onScrubEnded?() }
    }

    // MARK: - Frames

    /// `count` frames spread across the asset, small enough for a strip.
    static func frames(of asset: AVURLAsset, count: Int, from: Double? = nil, to: Double? = nil) async -> [UIImage] {
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds > 0, count > 0 else { return [] }
        let lower = max(0, from ?? 0)
        let upper = min(seconds, to ?? seconds)
        guard upper > lower else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [UIImage] = []
        for index in 0..<count {
            let at = lower + (upper - lower) * (Double(index) + 0.5) / Double(count)
            if let cg = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }
}

/// Frames side by side, each the same width, filling the row.
struct FrameRow: View {
    let frames: [UIImage]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
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
        .frame(width: width, height: height)
        .contentShape(Rectangle())
    }
}

/// The line where playback is: thin, white, with a shadow so it reads on
/// any frame.
struct Playhead: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white)
            .frame(width: 3, height: height)
            .shadow(color: .black.opacity(0.6), radius: 2)
    }
}
