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

    /// Which handle is under a finger right now, so it can say so.
    @State private var holding: Bool?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let scale = duration > 0 ? width / duration : 0
            let left = CGFloat(start) * scale
            let right = CGFloat(end) * scale
            // 🔴 A card corner, not a lozenge.
            //
            // This was `height / 2` -- 46pt on a 92pt strip -- which sliced
            // the first and last frames into half-moons and rounded the dim
            // rectangles into blobs whenever a trim offset was only a few
            // points wide. Theme.mediaRadius is what every other piece of
            // media in the app is cut to.
            let corner = Theme.mediaRadius
            let pill = RoundedRectangle(cornerRadius: corner, style: .continuous)

            ZStack(alignment: .leading) {
                FrameRow(frames: frames, width: width, height: height)
                    .clipShape(pill)
                    // The playhead: a drag anywhere on the frames scrubs.
                    .gesture(scrub(scale: scale, width: width))

                if dimsOutside {
                    // Clipped ONCE, by the strip, rather than each rectangle
                    // being given the strip's radius of its own -- which
                    // rounded a four-point-wide dim into a blob.
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(.black.opacity(0.55))
                            .frame(width: max(0, left))
                        Rectangle()
                            .fill(.black.opacity(0.55))
                            .frame(width: max(0, width - right))
                            .offset(x: right)
                    }
                    .frame(width: width, height: height, alignment: .leading)
                    .clipShape(pill)
                    .allowsHitTesting(false)
                }

                // The bracket: a thick white frame with rounded ends, the
                // handles being its two ends.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: max(handleWidth * 2, right - left))
                    .offset(x: left)
                    .allowsHitTesting(false)

                handle(height: height, leading: true, held: holding == true)
                    .offset(x: left)
                    .gesture(drag(scale: scale, width: width, leading: true))
                handle(height: height, leading: false, held: holding == false)
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

    /// A handle, and whether it is being held.
    ///
    /// iOS Photos turns its trim markers a different colour the moment one is
    /// dragged, so a finger covering the handle can still tell it has hold of
    /// it. Borrowed here, in the app's accent rather than yellow.
    private func handle(height: CGFloat, leading: Bool, held: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: leading ? height / 2 : 0,
            bottomLeadingRadius: leading ? height / 2 : 0,
            bottomTrailingRadius: leading ? 0 : height / 2,
            topTrailingRadius: leading ? 0 : height / 2,
            style: .continuous
        )
        .fill(held ? Theme.accent : .white)
        .frame(width: handleWidth)
        .overlay {
            Capsule()
                .fill(held ? Theme.onAccent.opacity(0.9) : Color(white: 0.3))
                .frame(width: 3, height: 26)
        }
        .animation(.snappy(duration: 0.15), value: held)
        // Reachable: the grip is 22pt but a thumb is not, so the touch area
        // runs 12pt past it on every side.
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
        // 🔴 Big enough for the pixels it lands on.
        //
        // This was 160 on the long edge, and a frame is drawn into a cell
        // about 36 x 92 POINTS -- 108 x 276 pixels on a 3x screen. A 9:16
        // thumbnail capped at 160 is roughly 90 x 160, so every frame was
        // blown up about 1.7x and then cropped by a third by scaledToFill.
        // That upscale is the whole reason the strip looked soft (Abel,
        // 25 Sep 2026: "looks bad and the shape is bad too").
        //
        // 92pt tall at 3x is 276px; 360 gives headroom for a taller strip and
        // for the crop, without making the generator do real work.
        generator.maximumSize = CGSize(width: 360, height: 360)
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
