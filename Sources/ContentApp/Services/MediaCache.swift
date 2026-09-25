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

    /// Downloads that report as they go, keyed by shelf AND name -- `downloads`
    /// above is keyed by id alone and so cannot tell two files of one thing
    /// apart.
    private var streams: [String: Streaming] = [:]

    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Generated", isDirectory: true)

    /// Which shelf a file belongs on.
    ///
    /// Abel, 25 Sep 2026: "save locally the videos they edited, so next time
    /// they open they don't have to download again the video."
    ///
    /// The comment at the top of this file argues for Caches, and it is still
    /// right for chat results: they live on the server and nothing is lost if
    /// iOS clears them. It is wrong for a video somebody opened, trimmed and
    /// is about to post -- having that deleted under storage pressure, halfway
    /// through, is the thing being complained about. So: a second shelf, not a
    /// move.
    enum Shelf {
        /// Caches. Fetched again if iOS clears it: chat results, posters.
        case fetchedAgain
        /// Application Support, kept out of iCloud. Videos somebody is working
        /// on. Evicted by `sweepKept()`, on our terms, never mid-trim.
        case kept
    }

    /// The durable shelf. Excluded from backup at creation: tens of megabytes
    /// of re-downloadable video in somebody's iCloud backup is a rejection.
    private lazy var keptFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Autocast/Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var url = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return base
    }()

    private func root(_ shelf: Shelf) -> URL {
        switch shelf {
        case .fetchedAgain: folder
        case .kept:         keptFolder
        }
    }

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
    /// `shelf` sits after `name` and before `fetch`, with a default, so every
    /// existing caller keeps working unchanged.
    func onDisk(_ id: String, name: String, shelf: Shelf = .fetchedAgain) -> URL? {
        let target = place(id, name, shelf)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    /// The file on the phone, fetched the first time only.
    func file(
        _ id: String,
        name: String,
        shelf: Shelf = .fetchedAgain,
        fetch: @escaping @MainActor () async -> Data?
    ) async -> URL? {
        if let there = onDisk(id, name: name, shelf: shelf) { return there }
        if let running = downloads[id] { return await running.value }

        let target = place(id, name, shelf)
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

    private func place(_ id: String, _ name: String, _ shelf: Shelf = .fetchedAgain) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        return root(shelf).appendingPathComponent(safe, isDirectory: true).appendingPathComponent(name)
    }

    // MARK: Files that say how they are going

    /// How a download is getting on.
    ///
    /// `expected` is optional because a server sending chunked transfer does
    /// not say how big the file is, and nothing downstream is allowed to
    /// invent a percentage out of that -- see the rule at the top of
    /// `Loaders.swift`.
    enum Fetching: Sendable, Equatable {
        case progress(received: Int64, expected: Int64?)
        case done(URL)
        case failed
    }

    /// What is true this instant, with no round trip. A view reads this inside
    /// `body`, before any `await`, so a screen that already has the file draws
    /// it on the first frame instead of flashing a spinner.
    enum Standing: Equatable {
        case here(URL)
        case coming(received: Int64, expected: Int64?)
        case absent
    }

    /// One download, and everyone watching it.
    private final class Streaming {
        var received: Int64 = 0
        var expected: Int64?
        var watchers: [UUID: AsyncStream<Fetching>.Continuation] = [:]
        var task: Task<Void, Never>?
    }

    func standing(_ id: String, name: String, shelf: Shelf = .kept) -> Standing {
        if let there = onDisk(id, name: name, shelf: shelf) { return .here(there) }
        if let running = streams[Self.slot(id, name, shelf)] {
            return .coming(received: running.received, expected: running.expected)
        }
        return .absent
    }

    private static func slot(_ id: String, _ name: String, _ shelf: Shelf) -> String {
        "\(shelf)/\(id)/\(name)"
    }

    /// The file, fetched once however many ask, reporting as it comes.
    ///
    /// The link is minted INSIDE the download, not before it: a signed URL
    /// asked for on every appearance is what made the old grid re-sign on
    /// every scroll.
    func stream(
        _ id: String,
        name: String,
        shelf: Shelf = .kept,
        from link: @escaping @MainActor () async -> URL?
    ) -> AsyncStream<Fetching> {
        AsyncStream { continuation in
            if let there = onDisk(id, name: name, shelf: shelf) {
                continuation.yield(.done(there))
                continuation.finish()
                return
            }

            let slot = Self.slot(id, name, shelf)
            let running = streams[slot] ?? Streaming()
            streams[slot] = running

            let watcher = UUID()
            running.watchers[watcher] = continuation
            continuation.yield(.progress(received: running.received, expected: running.expected))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.streams[slot]?.watchers[watcher] = nil }
            }

            guard running.task == nil else { return }
            running.task = Task { @MainActor in
                let result = await self.fetch(id, name: name, shelf: shelf, link: link, into: running)
                for (_, watcher) in running.watchers {
                    watcher.yield(result)
                    watcher.finish()
                }
                self.streams[slot] = nil
            }
        }
    }

    /// Downloads to `<name>.part`, then moves it into place.
    ///
    /// The durable shelf never evicts, so a half-written file saved under its
    /// real name is a permanently broken video with no way out. It is only
    /// given its name once it is whole.
    private func fetch(
        _ id: String,
        name: String,
        shelf: Shelf,
        link: @MainActor () async -> URL?,
        into running: Streaming
    ) async -> Fetching {
        guard let url = await link() else { return .failed }
        let target = place(id, name, shelf)
        let part = target.appendingPathExtension("part")

        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            running.expected = expected

            FileManager.default.createFile(atPath: part.path, contents: nil)
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }

            // Written in blocks, not byte by byte, and reported no more often
            // than a screen can use -- `didReceive` per byte would rebuild the
            // view hundreds of times a second.
            var buffer = Data(capacity: 1 << 16)
            var received: Int64 = 0
            var lastTold: Int64 = 0

            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if received - lastTold > 262_144 {
                        lastTold = received
                        running.received = received
                        for (_, watcher) in running.watchers {
                            watcher.yield(.progress(received: received, expected: expected))
                        }
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
            try handle.close()

            // A truncated file is worse than no file, because nothing will
            // ever fetch it again.
            if let expected, received != expected {
                try? FileManager.default.removeItem(at: part)
                return .failed
            }

            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: part, to: target)
            return .done(target)
        } catch {
            try? FileManager.default.removeItem(at: part)
            return .failed
        }
    }

    // MARK: Keeping the kept shelf honest

    /// Throws away everything filed under `id`, so deleting a post does not
    /// leave its video on the phone forever.
    func forget(_ id: String, shelf: Shelf = .kept) {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        try? FileManager.default.removeItem(at: root(shelf).appendingPathComponent(safe, isDirectory: true))
    }

    /// Holds the durable shelf under a ceiling, oldest first.
    ///
    /// Run at launch. Without it, "save every video forever" is exactly what
    /// happens, and the phone fills up.
    func sweepKept(limit: Int64 = 1_500_000_000) {
        let root = keptFolder
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let walk = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            ) else { return }

            var files: [(url: URL, date: Date, size: Int64)] = []
            var total: Int64 = 0
            for case let url as URL in walk {
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                )
                guard values?.isRegularFile == true else { continue }
                let size = Int64(values?.fileSize ?? 0)
                files.append((url, values?.contentModificationDate ?? .distantPast, size))
                total += size
            }
            guard total > limit else { return }

            // Oldest touched goes first. `contentAccessDate` is unreliable on
            // iOS, so opening a video stamps its modification date instead.
            for file in files.sorted(by: { $0.date < $1.date }) {
                guard total > limit else { break }
                try? manager.removeItem(at: file.url)
                total -= file.size
            }
        }
    }

    /// Marks a file as used now, so a sweep keeps what is being watched.
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
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
