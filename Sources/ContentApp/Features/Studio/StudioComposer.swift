import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Turns a `StudioProject` into something AVFoundation can play and export.
///
/// One composition drives both the preview and the export, and every frame
/// goes through `StudioCompositor` -- so what plays in the editor is exactly
/// what gets posted. (AVVideoCompositionCoreAnimationTool was not used: it
/// renders nothing in AVPlayer, so text would appear only after export.)
enum StudioComposer {
    static let renderSize = CGSize(width: 1080, height: 1920)
    static let frameRate: Int32 = 30

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix
    }

    enum Failure: LocalizedError {
        case noVideo
        var errorDescription: String? { "That clip has no picture to use." }
    }

    static func build(_ project: StudioProject) async throws -> Built {
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.noVideo }

        var cursor = CMTime.zero
        var segments: [StudioInstruction.Segment] = []
        let originalParams = AVMutableAudioMixInputParameters(track: audioTrack)

        for clip in project.clips {
            let sourceURL = clip.kind == .photo ? try await PhotoClips.video(for: clip.url) : clip.url
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }

            let range = CMTimeRange(start: seconds(clip.trimStart), duration: seconds(clip.trimmedLength))
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            var hasAudio = false
            if clip.kind == .video, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                hasAudio = true
            }

            let onTimeline = seconds(clip.duration)
            if clip.speed != 1 {
                let inserted = CMTimeRange(start: cursor, duration: range.duration)
                videoTrack.scaleTimeRange(inserted, toDuration: onTimeline)
                if hasAudio { audioTrack.scaleTimeRange(inserted, toDuration: onTimeline) }
            }

            segments.append(StudioInstruction.Segment(
                range: CMTimeRange(start: cursor, duration: onTimeline),
                transform: try await sourceVideo.load(.preferredTransform),
                naturalSize: try await sourceVideo.load(.naturalSize)
            ))
            originalParams.setVolume(project.originalVolume * clip.volume, at: cursor)
            cursor = cursor + onTimeline
        }

        var mixParams = [originalParams]

        if let music = project.music,
           let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
           let source = try await AVURLAsset(url: music.fileURL).loadTracks(withMediaType: .audio).first {
            let available = max(0, music.trackDuration - music.startOffset)
            let length = min(available, cursor.seconds)
            if length > 0 {
                try musicTrack.insertTimeRange(
                    CMTimeRange(start: seconds(music.startOffset), duration: seconds(length)),
                    of: source, at: .zero
                )
                let params = AVMutableAudioMixInputParameters(track: musicTrack)
                params.setVolume(music.volume, at: .zero)
                // A short fade at the end instead of a cut.
                let fade = min(1.0, length / 4)
                params.setVolumeRamp(fromStartVolume: music.volume, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: seconds(length - fade), duration: seconds(fade)))
                mixParams.append(params)
            }
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams

        let overlays = TextRenderer.overlays(for: project.texts, size: renderSize)
        let look = StudioLook(filter: project.filter, intensity: project.filterIntensity, adjust: project.adjust)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRate)
        videoComposition.instructions = segments.map { segment in
            StudioInstruction(segment: segment, trackID: videoTrack.trackID, look: look, overlays: overlays)
        }

        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    static func playerItem(_ built: Built) -> AVPlayerItem {
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        return item
    }

    /// Renders the finished video, highest quality, as MP4.
    static func export(_ built: Built, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autocast-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.noVideo
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true

        let watcher = Task {
            for await state in session.states(updateInterval: 0.15) {
                if case .exporting(let fraction) = state { progress(fraction.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
        return url
    }

    static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }
}

// MARK: - The look

struct StudioLook: Sendable {
    let filter: StudioFilter
    let intensity: Double
    let adjust: StudioAdjust

    func apply(to image: CIImage) -> CIImage {
        var output = image
        if !adjust.isNeutral {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.brightness = Float(adjust.brightness)
            controls.contrast = Float(adjust.contrast)
            controls.saturation = Float(adjust.saturation)
            output = controls.outputImage ?? output
            if adjust.warmth != 0 {
                let temp = CIFilter.temperatureAndTint()
                temp.inputImage = output
                temp.neutral = CIVector(x: 6500, y: 0)
                temp.targetNeutral = CIVector(x: CGFloat(6500 - adjust.warmth * 1500), y: 0)
                output = temp.outputImage ?? output
            }
        }
        guard filter != .none, let filtered = Self.preset(filter, output) else { return output }
        if intensity >= 0.999 { return filtered }
        // Blend the preset over the original by its intensity.
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = output
        blend.targetImage = filtered
        blend.time = Float(intensity)
        return blend.outputImage ?? filtered
    }

    private static func preset(_ filter: StudioFilter, _ image: CIImage) -> CIImage? {
        switch filter {
        case .none:
            return image
        case .vivid:
            let f = CIFilter.vibrance(); f.inputImage = image; f.amount = 0.8
            return f.outputImage
        case .warm:
            let f = CIFilter.temperatureAndTint(); f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 5000, y: 10)
            return f.outputImage
        case .cool:
            let f = CIFilter.temperatureAndTint(); f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 8200, y: -5)
            return f.outputImage
        case .mono:
            let f = CIFilter.photoEffectMono(); f.inputImage = image
            return f.outputImage
        case .fade:
            let f = CIFilter.photoEffectFade(); f.inputImage = image
            return f.outputImage
        case .noir:
            let f = CIFilter.photoEffectNoir(); f.inputImage = image
            return f.outputImage
        case .film:
            let f = CIFilter.photoEffectChrome(); f.inputImage = image
            return f.outputImage
        }
    }
}

// MARK: - The compositor

/// One clip's stretch of the timeline, and how to draw it.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    struct Segment {
        let range: CMTimeRange
        let transform: CGAffineTransform
        let naturalSize: CGSize
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let naturalSize: CGSize
    let look: StudioLook
    let overlays: [TextRenderer.Overlay]

    init(segment: Segment, trackID: CMPersistentTrackID, look: StudioLook, overlays: [TextRenderer.Overlay]) {
        timeRange = segment.range
        self.trackID = trackID
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
        transform = segment.transform
        naturalSize = segment.naturalSize
        self.look = look
        self.overlays = overlays
    }
}

/// Draws every frame: upright, filling 9:16, with the look and the text.
final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "autocast.compositor")

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard
                let instruction = request.videoCompositionInstruction as? StudioInstruction,
                let source = request.sourceFrame(byTrackID: instruction.trackID),
                let output = request.renderContext.newPixelBuffer()
            else {
                request.finish(with: NSError(domain: "Autocast.Compositor", code: 1))
                return
            }

            let size = request.renderContext.size
            var image = CIImage(cvPixelBuffer: source)
                .oriented(Self.orientation(of: instruction.transform))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

            // Fill the frame, centred, cropping what spills over.
            let scale = max(size.width / image.extent.width, size.height / image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            image = image.transformed(by: CGAffineTransform(
                translationX: (size.width - image.extent.width) / 2,
                y: (size.height - image.extent.height) / 2
            ))
            image = instruction.look.apply(to: image).cropped(to: CGRect(origin: .zero, size: size))

            let time = request.compositionTime.seconds
            for overlay in instruction.overlays where overlay.isVisible(at: time) {
                image = overlay.image.composited(over: image)
            }

            let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
            Self.context.render(image.composited(over: background), to: output,
                                bounds: CGRect(origin: .zero, size: size),
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// A track's preferredTransform as the EXIF orientation Core Image wants.
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (Int(t.a.rounded()), Int(t.b.rounded()), Int(t.c.rounded()), Int(t.d.rounded())) {
        case (0, 1, -1, 0):  return .right
        case (0, -1, 1, 0):  return .left
        case (-1, 0, 0, -1): return .down
        default:             return .up
        }
    }
}

// MARK: - Text

enum TextRenderer {
    struct Overlay: Sendable {
        let image: CIImage
        let start: Double
        let end: Double?

        func isVisible(at time: Double) -> Bool { time >= start && time < (end ?? .infinity) }
    }

    /// Each text drawn once, full frame, transparent around it.
    static func overlays(for texts: [StudioText], size: CGSize) -> [Overlay] {
        texts.compactMap { text in
            guard !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cg = draw(text, size: size) else { return nil }
            return Overlay(image: CIImage(cgImage: cg), start: text.start, end: text.end)
        }
    }

    static func draw(_ text: StudioText, size: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            let fontSize = size.height * text.size
            let color = UIColor(hex: text.color) ?? .white
            let font: UIFont = switch text.style {
            case .classic: .systemFont(ofSize: fontSize, weight: .medium)
            case .bold, .label: .systemFont(ofSize: fontSize, weight: .heavy)
            case .outline: .systemFont(ofSize: fontSize, weight: .black)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            switch text.style {
            case .outline:
                attributes[.foregroundColor] = color
                attributes[.strokeColor] = UIColor.black
                attributes[.strokeWidth] = -4
            case .label:
                attributes[.foregroundColor] = color.isLight ? UIColor.black : UIColor.white
            default:
                attributes[.foregroundColor] = color
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = fontSize * 0.12
                shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.04)
                attributes[.shadow] = shadow
            }
            let string = NSAttributedString(string: text.text, attributes: attributes)
            let maxWidth = size.width * 0.86
            let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let rect = CGRect(
                x: size.width * text.x - bounds.width / 2,
                y: size.height * text.y - bounds.height / 2,
                width: bounds.width, height: bounds.height
            ).integral
            if text.style == .label {
                let pad = fontSize * 0.3
                color.setFill()
                UIBezierPath(roundedRect: rect.insetBy(dx: -pad, dy: -pad * 0.6), cornerRadius: pad).fill()
            }
            string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        return image.cgImage
    }
}

// MARK: - Photos as clips

/// A photo becomes a short 1080×1920 video once, so it can sit on the same
/// timeline as video. Fitted over a blurred fill of itself, like TikTok.
enum PhotoClips {
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var cache: [URL: URL] = [:]
    private static let lock = NSLock()

    static func video(for photo: URL) async throws -> URL {
        if let hit = lock.withLock({ cache[photo] }) { return hit }
        let url = try await render(photo)
        lock.withLock { cache[photo] = url }
        return url
    }

    private static func render(_ photo: URL) async throws -> URL {
        let size = StudioComposer.renderSize
        guard let source = CIImage(contentsOf: photo, options: [.applyOrientationProperty: true]) else {
            throw StudioComposer.Failure.noVideo
        }
        let fillScale = max(size.width / source.extent.width, size.height / source.extent.height)
        let fitScale = min(size.width / source.extent.width, size.height / source.extent.height)
        let fill = source.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        let blurred = fill.clampedToExtent().applyingGaussianBlur(sigma: 40)
            .transformed(by: CGAffineTransform(translationX: (size.width - fill.extent.width) / 2, y: (size.height - fill.extent.height) / 2))
            .cropped(to: CGRect(origin: .zero, size: size))
        let fit = source.transformed(by: CGAffineTransform(scaleX: fitScale, y: fitScale))
        let placed = fit.transformed(by: CGAffineTransform(
            translationX: (size.width - fit.extent.width) / 2 - fit.extent.minX,
            y: (size.height - fit.extent.height) / 2 - fit.extent.minY
        ))
        let frame = placed.composited(over: blurred.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12]))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw StudioComposer.Failure.noVideo }
        CIContext().render(frame, to: buffer)

        let end = StudioComposer.seconds(StudioProject.photoMaxSeconds)
        for time in [CMTime.zero, CMTimeSubtract(end, CMTime(value: 1, timescale: 30))] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? StudioComposer.Failure.noVideo }
        return url
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var value: UInt64 = 0
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, Scanner(string: clean).scanHexInt64(&value) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}
