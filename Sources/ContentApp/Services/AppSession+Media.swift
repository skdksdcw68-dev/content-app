import Foundation

/// Videos kept on the phone once they have been watched.
///
/// Abel, 25 Sep 2026: *"save locally the videos they edited, so next time they
/// open they don't have to download again the video."*
///
/// Until now the review screen deleted and re-downloaded the whole file on
/// every open, into `temporaryDirectory`, with no progress. Opening the same
/// post twice cost the same tens of megabytes twice.
///
/// Keyed on `media.path` rather than the post id: a post's media can be
/// replaced by a re-generation, and one asset can back more than one post.
/// Keyed by post the old file would be served forever with no way to notice.
/// It is also the convention already -- `attachmentThumbnail(_ path:)` does
/// the same.
///
/// 🔴 The local URL is always DERIVED from the path and never stored. A
/// `file://` written into a row is a path that cannot resolve on another
/// device or after a reinstall.
extension AppSession {
    /// The file name a piece of media takes on disk. The extension matters:
    /// `AVURLAsset`, `VideoPlayer` and the share sheet all read it.
    private func fileName(for media: BoardPost.Media) -> String {
        let ext = (media.mime ?? "").contains("quicktime") ? "mov" : "mp4"
        return "video.\(ext)"
    }

    /// The video if it is already here, with no network and no waiting.
    /// Read inside `body`, before any `await`, so a second open is instant.
    func cachedVideo(of media: BoardPost.Media) -> URL? {
        MediaCache.shared.onDisk(media.path, name: fileName(for: media), shelf: .kept)
    }

    /// The video, fetched once, reporting as it comes.
    func videoStream(of media: BoardPost.Media) -> AsyncStream<MediaCache.Fetching> {
        MediaCache.shared.stream(media.path, name: fileName(for: media), shelf: .kept) {
            await self.mediaURL(media)
        }
    }

    /// The video, waited for. For callers with nothing to show meanwhile.
    func localVideo(of media: BoardPost.Media) async -> URL? {
        for await step in videoStream(of: media) {
            if case .done(let url) = step { return url }
            if case .failed = step { return nil }
        }
        return nil
    }

    /// Forgets a post's video, so deleting a post does not leave it behind.
    func forgetVideo(of media: BoardPost.Media) {
        MediaCache.shared.forget(media.path, shelf: .kept)
    }
}
