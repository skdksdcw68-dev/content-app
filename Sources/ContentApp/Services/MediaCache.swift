import AVFoundation
import Foundation
import ImageIO
import UIKit

/// Generated pictures and videos, kept on the phone once they have been fetched.
///
/// Scrolling back up a conversation used to download every result again. The
/// list recycles rows that leave the screen; each came back asking for a fresh
/// signed link, and a fresh link is a new URL to every cache there is -- so a
/// 9.6 MB picture was fetched each time it scrolled into view, and flashed a
/// spinner while it was. Now the file is fetched once into Caches, filed under
/// what it is rather than where it was linked from, and the decoded picture is
/// kept in memory while the app is open.
///
/// Caches rather than Documents on purpose: these are copies of files that live
/// on the server, and if the phone runs short of space iOS may clear them and
/// they are fetched again. Nothing is lost that way.
@MainActor
final class MediaCache {
    static let shared = MediaCache()

    /// Decoded, screen-sized pictures and video posters -- the slow part to redo.
    private let images = NSCache<NSString, UIImage>()
    /// Artefacts already read. What was made does not change once it exists.
    private var artifacts: [UUID: Artifact] = [:]
    /// Downloads in flight, so a card and the viewer asking at once fetch once.
    private var downloads: [String: Task<URL?, Never>] = [:]

    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Generated", isDirectory: true)

    private init() {
        // Pixels, roughly: a 750-pixel thumbnail is about 2 MB decoded.
        images.totalCostLimit = 120 * 1024 * 1024
    }

    // MARK: Artefacts

    func artifact(_ id: UUID) -> Artifact? { artifacts[id] }

    /// Kept only once it is final. An export is written first and its file
    /// attached after, so one read before the file is there must not stick.
    func keep(_ artifact: Artifact) {
        let hasFile = artifact.storagePath != nil
        let noFileExpected = ["research", "campaign", "plan"].contains(artifact.kind)
        if hasFile || noFileExpected { artifacts[artifact.id] = artifact }
    }

    // MARK: Pictures

    static func key(_ id: UUID, _ variant: String) -> NSString {
        key(id.uuidString, variant)
    }

    static func key(_ name: String, _ variant: String) -> NSString {
        "\(name)#\(variant)" as NSString
    }

    func image(_ key: NSString) -> UIImage? { images.object(forKey: key) }

    func keep(_ image: UIImage, _ key: NSString) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        images.setObject(image, forKey: key, cost: Int(pixels * 4))
    }

    // MARK: Files

    /// Where a file lives on the phone, if it is there yet. `id` is what the
    /// file is -- an artefact's id, or the path of a picture somebody attached.
    func onDisk(_ id: String, name: String) -> URL? {
        let target = place(id, name)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    /// The file on the phone, fetched the first time only.
    func file(_ id: String, name: String, fetch: @escaping @MainActor () async -> Data?) async -> URL? {
        if let there = onDisk(id, name: name) { return there }
        if let running = downloads[id] { return await running.value }

        let target = place(id, name)
        let task = Task { @MainActor () -> URL? in
            guard let data = await fetch() else { return nil }
            // Off the main thread: a video is tens of megabytes to write.
            return await Task.detached(priority: .utility) { () -> URL? in
                do {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try data.write(to: target, options: .atomic)
                    return target
                } catch {
                    return nil
                }
            }.value
        }
        downloads[id] = task
        let url = await task.value
        downloads[id] = nil
        return url
    }

    private func place(_ id: String, _ name: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return folder.appendingPathComponent(safe, isDirectory: true).appendingPathComponent(name)
    }

    // MARK: Decoding, off the main thread

    /// A picture no bigger than it is drawn. A 1536x2752 PNG decoded whole is
    /// 17 MB of memory for a card 250 points wide.
    nonisolated static func downsample(_ url: URL, longest pixels: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    /// A video's first frame, drawn under the player so a row coming back on
    /// screen shows the video at once instead of an empty box.
    nonisolated static func poster(_ url: URL, longest pixels: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: frame.image)
    }
}
