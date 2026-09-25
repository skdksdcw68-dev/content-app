import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Makes a picture the shape of the video it is going to become.
///
/// 🔴 Abel's first real video came back 1328 x 694. Landscape, on an app whose
/// entire output is for a phone.
///
/// The cause is not a setting anybody got wrong. A picture attached to a video
/// request routes to fal's IMAGE-to-video endpoint, and that endpoint has no
/// `aspect_ratio` field at all -- the video takes the shape of the picture. He
/// attached a landscape photo, so he got a landscape video, and no amount of
/// asking for 9:16 in the composer would have changed it.
///
/// So the shape has to be decided before the picture is uploaded, which is
/// here, on the phone, where there is a real image library.
///
/// PADDED, NOT CROPPED. A centre crop of a landscape photo throws away most of
/// it and usually the half somebody cared about. This keeps the whole picture,
/// centred, over a blurred blow-up of itself -- the treatment every reels app
/// uses for the same problem, and the one that makes a wide shot look
/// deliberate rather than mangled.
enum VerticalFit {
    /// 9:16 at a sensible size for a model to read. Taller than it is wide by
    /// the same ratio the video will be.
    static let size = CGSize(width: 1080, height: 1920)

    /// Whether this picture is already close enough to vertical to leave
    /// alone. Padding an image that is already 9:16 would only soften it.
    static func isVertical(_ image: UIImage) -> Bool {
        guard image.size.width > 0, image.size.height > 0 else { return false }
        let ratio = image.size.width / image.size.height
        let wanted = size.width / size.height
        return abs(ratio - wanted) < 0.04
    }

    /// The picture at 9:16, whole, over a blurred fill. Returns the original
    /// when it is already vertical, and when anything goes wrong -- a picture
    /// that could not be padded is still a picture worth sending.
    static func padded(_ image: UIImage) -> UIImage {
        guard !isVertical(image), image.size.width > 0, image.size.height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            // The fill: the same picture, blown up to cover, blurred, and
            // darkened a little so the real one in front of it reads first.
            let cover = fittingRect(image.size, in: size, mode: .fill)
            if let blurred = blur(image) {
                blurred.draw(in: cover)
            } else {
                image.draw(in: cover)
            }
            UIColor.black.withAlphaComponent(0.28).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // The picture itself, whole, centred.
            image.draw(in: fittingRect(image.size, in: size, mode: .fit))
        }
    }

    // MARK: - Working out

    private enum Mode { case fit, fill }

    /// Where a picture of this size sits inside the frame, centred, either
    /// contained by it or covering it.
    private static func fittingRect(_ source: CGSize, in frame: CGSize, mode: Mode) -> CGRect {
        let scaleX = frame.width / source.width
        let scaleY = frame.height / source.height
        let scale = mode == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let drawn = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (frame.width - drawn.width) / 2,
            y: (frame.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// One Core Image pass. `clampedToExtent` before the blur is what stops
    /// the edges fading to transparent and leaving a pale border down each
    /// side of the finished picture.
    private static func blur(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = 40
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let made = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: made)
    }
}
