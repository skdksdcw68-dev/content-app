import Foundation
import Supabase
import AVFoundation
import UIKit

/// The operating loop from the app's side: the plan board, one post in full,
/// the Autopilot overview, pausing, rescheduling, and taking a video from the
/// phone through understand → prepare → validate. Every answer comes from the
/// server; nothing here guesses a stage.
extension AppSession {
    private static let operateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct BoardParams: Encodable, Sendable {
        let p_brand: String
        let p_plan: String?
        let p_post: String?
    }

    func board(plan: UUID) async throws -> [BoardPost] {
        guard let brand else { throw AnalyticsError.noBrand }
        let response = try await client
            .rpc("post_board", params: BoardParams(p_brand: brand.id.uuidString, p_plan: plan.uuidString, p_post: nil))
            .execute()
        return try Self.operateDecoder.decode([BoardPost].self, from: response.data)
    }

    func boardPost(_ id: UUID) async throws -> BoardPost? {
        guard let brand else { throw AnalyticsError.noBrand }
        let response = try await client
            .rpc("post_board", params: BoardParams(p_brand: brand.id.uuidString, p_plan: nil, p_post: id.uuidString))
            .execute()
        return try Self.operateDecoder.decode([BoardPost].self, from: response.data).first
    }

    func autopilotOverview() async throws -> AutopilotOverview {
        guard let brand else { throw AnalyticsError.noBrand }
        let response = try await client
            .rpc("autopilot_overview", params: ["p_brand": brand.id.uuidString])
            .execute()
        return try Self.operateDecoder.decode(AutopilotOverview.self, from: response.data)
    }

    /// Autopilot on or paused. Paused means the scheduler skips this brand.
    @discardableResult
    func setPublishing(_ on: Bool) async -> Bool {
        guard let brand else { return false }
        struct Change: Encodable, Sendable { let publishing_on: Bool }
        do {
            try await client
                .from("brand_settings")
                .update(Change(publishing_on: on))
                .eq("brand_id", value: brand.id.uuidString)
                .execute()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    @discardableResult
    func reschedule(post: UUID, to date: Date) async -> Bool {
        struct Params: Encodable, Sendable {
            let p_post: String
            let p_at: String
        }
        do {
            try await client
                .rpc("reschedule_post", params: Params(
                    p_post: post.uuidString,
                    p_at: ISO8601DateFormatter().string(from: date)
                ))
                .execute()
            await refreshPlan()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// A short-lived link to play a post's own video.
    func mediaURL(_ media: BoardPost.Media) async -> URL? {
        try? await client.storage
            .from(media.bucket ?? "media")
            .createSignedURL(path: media.path, expiresIn: 3600)
    }

    // MARK: - Upload flow

    /// Sends the file to the person's own media folder and returns its path.
    func uploadVideo(at url: URL) async throws -> String {
        guard let userID else { throw AnalyticsError.noBrand }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
        let path = "\(userID.uuidString.lowercased())/uploads/\(UUID().uuidString.lowercased()).\(ext)"
        do {
            try await retryingDroppedConnection {
                _ = try await client.storage
                    .from("media")
                    .upload(path, data: data, options: FileOptions(contentType: ext == "mov" ? "video/quicktime" : "video/mp4"))
            }
        } catch {
            // The first try landed and only its answer was lost: the retry is
            // refused because the file is already there, which is success.
            let text = String(describing: error).lowercased()
            guard text.contains("duplicate") || text.contains("already exists") || text.contains("409") else { throw error }
        }
        return path
    }

    /// One quiet retry when the network drops the request.
    ///
    /// Abel, 18 Sep: "every first try it says connection issue". iOS reuses a
    /// keep-alive connection the server has already closed, the first request
    /// after a pause fails with networkConnectionLost, and the second works.
    func retryingDroppedConnection<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
            try await Task.sleep(for: .milliseconds(800))
            return try await work()
        }
    }

    private struct ItemRequest: Encodable, Sendable {
        let step: String
        let brand_id: String
        var post_id: String? = nil
        var storage_path: String? = nil
        var frames: [String]? = nil
        var duration_s: Double? = nil
        var width: Int? = nil
        var height: Int? = nil
        var file_name: String? = nil
        var note: String? = nil
        var caption: String? = nil
        var hashtags: [String]? = nil
        var cover_ms: Int? = nil
        var mode: String? = nil
    }

    private func contentItem<T: Decodable>(_ request: ItemRequest) async throws -> T {
        try await retryingDroppedConnection {
            try await client.functions.invoke(
                "content-item",
                options: FunctionInvokeOptions(body: request),
                decoder: Self.operateDecoder
            )
        }
    }

    func understand(video: VideoFacts, path: String, note: String?) async throws -> UnderstoodVideo {
        guard let brand else { throw AnalyticsError.noBrand }
        return try await contentItem(ItemRequest(
            step: "understand",
            brand_id: brand.id.uuidString,
            storage_path: path,
            frames: video.frames,
            duration_s: video.duration,
            width: video.width,
            height: video.height,
            file_name: video.fileName,
            note: note
        ))
    }

    func prepare(post: UUID, path: String, video: VideoFacts) async throws -> PreparedItem {
        guard let brand else { throw AnalyticsError.noBrand }
        return try await contentItem(ItemRequest(
            step: "prepare",
            brand_id: brand.id.uuidString,
            post_id: post.uuidString,
            storage_path: path,
            duration_s: video.duration,
            width: video.width,
            height: video.height
        ))
    }

    /// The person's own post: their words, tags and cover, attached and
    /// checked in one call. Needs a connected account, nothing else.
    func compose(path: String, video: VideoFacts, caption: String, hashtags: [String], coverMs: Int?, toDrafts: Bool) async throws -> ComposedPost {
        guard let brand else { throw AnalyticsError.noBrand }
        return try await contentItem(ItemRequest(
            step: "compose",
            brand_id: brand.id.uuidString,
            storage_path: path,
            duration_s: video.duration,
            width: video.width,
            height: video.height,
            file_name: video.fileName,
            caption: caption,
            hashtags: hashtags,
            cover_ms: coverMs,
            mode: toDrafts ? "UPLOAD_TO_DRAFT" : "DIRECT_POST"
        ))
    }

    /// "Write with AI": their caption made better, plus hashtags.
    func writeCaption(_ caption: String, hashtags: [String], frames: [String]) async throws -> WrittenCaption {
        guard let brand else { throw AnalyticsError.noBrand }
        return try await contentItem(ItemRequest(
            step: "write",
            brand_id: brand.id.uuidString,
            frames: frames.isEmpty ? nil : Array(frames.prefix(3)),
            caption: caption,
            hashtags: hashtags
        ))
    }

    func validate(post: UUID, toDrafts: Bool = false) async throws -> ValidationReport {
        guard let brand else { throw AnalyticsError.noBrand }
        return try await contentItem(ItemRequest(
            step: "validate",
            brand_id: brand.id.uuidString,
            post_id: post.uuidString,
            mode: toDrafts ? "UPLOAD_TO_DRAFT" : nil
        ))
    }
}

/// What the phone measures about a video before sending it: length, size and
/// four frames for Autocast to look at.
struct VideoFacts: Sendable {
    let fileName: String
    let duration: Double
    let width: Int
    let height: Int
    let frames: [String]
    let poster: UIImage?

    static func read(_ url: URL) async throws -> VideoFacts {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var width = 0
        var height = 0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(rect.width).rounded())
            height = Int(abs(rect.height).rounded())
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)

        var frames: [String] = []
        var poster: UIImage?
        for fraction in [0.1, 0.4, 0.7, 0.95] {
            let time = CMTime(seconds: max(0, duration * fraction), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            let ui = UIImage(cgImage: image)
            if poster == nil { poster = ui }
            if let jpeg = ui.jpegData(compressionQuality: 0.6) {
                frames.append(jpeg.base64EncodedString())
            }
        }

        return VideoFacts(
            fileName: url.lastPathComponent,
            duration: duration.isFinite ? duration : 0,
            width: width,
            height: height,
            frames: frames,
            poster: poster
        )
    }
}
