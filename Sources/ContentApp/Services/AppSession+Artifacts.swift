import Foundation
import Photos
import Supabase
import UIKit

/// What the agent made, and the work still making it.
///
/// Everything here reads. The agent writes artefacts and run events on the
/// server; the app follows along and shows them. The one write is an upload
/// into the person's own `uploads/` folder, which the storage policy in 0033
/// allows and nothing else does.
extension AppSession {

    /// One artefact, if it is this person's. Read once: what was made does not
    /// change, and a row scrolled back into view should not ask again.
    func artifact(_ id: UUID) async -> Artifact? {
        if let known = MediaCache.shared.artifact(id) { return known }
        do {
            let rows: [Artifact] = try await client
                .rpc("artifact", params: ["p_id": id.uuidString])
                .execute()
                .value
            if let row = rows.first { MediaCache.shared.keep(row) }
            return rows.first
        } catch {
            return nil
        }
    }

    /// What happened on a run after the last event already drawn.
    func runEvents(_ run: UUID, after seq: Int) async -> [RunEvent] {
        struct Params: Encodable {
            let p_run: String
            let p_after: Int
        }
        do {
            return try await client
                .rpc("run_events", params: Params(p_run: run.uuidString, p_after: seq))
                .execute()
                .value
        } catch {
            return []
        }
    }

    /// A short-lived link to a file of this person's. Issued per request, so a
    /// link that leaks expires rather than exposing somebody's work for good.
    func signedURL(for path: String, expiresIn seconds: Int = 3600) async -> URL? {
        try? await client.storage.from("artifacts").createSignedURL(path: path, expiresIn: seconds)
    }

    /// The file, on the phone under the name somebody would expect -- fetched
    /// the first time and kept (see `MediaCache`). Quick Look, the share sheet
    /// and the players all need a real file with a real extension; a signed
    /// URL is neither, and is a new download every time it is issued.
    func localCopy(of artifact: Artifact) async -> URL? {
        guard let path = artifact.storagePath else { return nil }
        let storage = client.storage.from("artifacts")
        return await MediaCache.shared.file(artifact.id.uuidString, name: Self.fileName(of: artifact, path: path)) {
            try? await storage.download(path: path)
        }
    }

    /// The file if it is already on the phone -- asked synchronously, so a row
    /// coming back on screen draws what is there without a round trip.
    func cachedCopy(of artifact: Artifact) -> URL? {
        guard let path = artifact.storagePath else { return nil }
        return MediaCache.shared.onDisk(artifact.id.uuidString, name: Self.fileName(of: artifact, path: path))
    }

    /// A picture somebody attached, small, kept like the results are -- it
    /// was a new signed link and a new download every time it scrolled by.
    func attachmentThumbnail(_ path: String, longest pixels: CGFloat) async -> UIImage? {
        let key = MediaCache.key(path, "\(Int(pixels))")
        if let known = MediaCache.shared.image(key) { return known }
        let storage = client.storage.from("artifacts")
        let name = (path as NSString).lastPathComponent
        guard let file = await MediaCache.shared.file(path, name: name, fetch: {
            try? await storage.download(path: path)
        }) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            MediaCache.downsample(file, longest: pixels)
        }.value
        if let image { MediaCache.shared.keep(image, key) }
        return image
    }

    private static func fileName(of artifact: Artifact, path: String) -> String {
        artifact.body.filename ?? (path as NSString).lastPathComponent
    }

    /// A generated picture no bigger than it is drawn: from memory if it has
    /// been drawn before, from the phone if it was fetched before, and from the
    /// server only the first time.
    func picture(of artifact: Artifact, longest pixels: CGFloat) async -> UIImage? {
        let key = MediaCache.key(artifact.id, "\(Int(pixels))")
        if let known = MediaCache.shared.image(key) { return known }
        guard let file = await localCopy(of: artifact) else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            MediaCache.downsample(file, longest: pixels)
        }.value
        if let image { MediaCache.shared.keep(image, key) }
        return image
    }

    /// A video's first frame, kept the same way.
    func poster(of artifact: Artifact, longest pixels: CGFloat) async -> UIImage? {
        let key = MediaCache.key(artifact.id, "poster\(Int(pixels))")
        if let known = MediaCache.shared.image(key) { return known }
        guard let file = await localCopy(of: artifact) else { return nil }
        let image = await MediaCache.poster(file, longest: pixels)
        if let image { MediaCache.shared.keep(image, key) }
        return image
    }

    /// Puts a picture or video in the person's photo library. Add-only access:
    /// the app can put things in and can never read what is there.
    func saveToPhotos(_ artifact: Artifact) async -> SaveOutcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .notAllowed }
        guard let file = await localCopy(of: artifact) else { return .failed }
        let isVideo = artifact.kind == "video"
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
                } else {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
                }
            }
            return .saved
        } catch {
            return .failed
        }
    }

    enum SaveOutcome {
        case saved, notAllowed, failed
    }

    /// The provider's own price for one image or video with exactly these
    /// settings -- its dry run, which submits nothing. Nil when it will not say.
    func quote(capability: String, model: String, prompt: String, settings: GenerationSettings) async -> ModelCost? {
        await quote(capability: capability, models: [model], prompt: prompt, settings: settings)[model]
    }

    /// The same question for several models at once -- what a family costs,
    /// asked when somebody opens it. Pricing a whole catalogue to draw a list
    /// would spend a provider request per row scrolled past.
    func quote(
        capability: String,
        models: [String],
        prompt: String,
        settings: GenerationSettings
    ) async -> [String: ModelCost] {
        struct Request: Encodable, Sendable {
            let capability: String
            let models: [String]
            let prompt: String
            let settings: Settings
            struct Settings: Encodable, Sendable {
                let resolution: String?
                let duration: Int?
                let quality: String?
            }
        }
        struct Response: Decodable { let costs: [String: ModelCost]? }
        guard !models.isEmpty else { return [:] }
        do {
            let response: Response = try await client.functions.invoke(
                "quote",
                options: FunctionInvokeOptions(body: Request(
                    capability: capability,
                    models: models,
                    prompt: prompt,
                    settings: .init(
                        resolution: settings.resolution,
                        duration: settings.duration.map { Int($0.rounded()) },
                        quality: settings.quality
                    )
                ))
            )
            return (response.costs ?? [:]).filter { $0.value.amount != nil }
        } catch {
            return [:]
        }
    }

    /// Every model of one kind on this person's connections, grouped by family
    /// -- what "All 34 models" opens. Unpriced: the browser prices a family
    /// when it is opened.
    func models(capability: String, withPicture: Bool) async -> [ModelChoice] {
        struct Request: Encodable, Sendable {
            let capability: String
            let withPicture: Bool
        }
        struct Response: Decodable { let options: [ModelChoice] }
        do {
            let response: Response = try await client.functions.invoke(
                "models",
                options: FunctionInvokeOptions(body: Request(capability: capability, withPicture: withPicture))
            )
            return response.options
        } catch {
            return []
        }
    }

    /// The person approves a strategy. Through `approve_strategy`, which
    /// refuses anyone but the owner -- the agent cannot approve its own plan.
    func approveStrategy(_ id: UUID) async -> Bool {
        do {
            _ = try await client
                .rpc("approve_strategy", params: ["p_strategy": id.uuidString])
                .execute()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Where a strategy stands: approved, still a draft, or replaced by a
    /// newer one. Read from the server, so a reopened card tells the truth.
    func strategyStanding(_ id: UUID) async -> StrategyStanding {
        struct Row: Decodable {
            let id: UUID
            /// Text, not a date: only whether it is there matters, and a
            /// timestamp format mismatch should not read as "not approved".
            let approvedAt: String?
            private enum CodingKeys: String, CodingKey {
                case id
                case approvedAt = "approved_at"
            }
        }
        guard let brandID = brand?.id else { return .draft }
        do {
            let rows: [Row] = try await client
                .rpc("current_strategy", params: ["p_brand": brandID.uuidString])
                .execute()
                .value
            guard let live = rows.first else { return .replaced }
            guard live.id == id else { return .replaced }
            return live.approvedAt == nil ? .draft : .approved
        } catch {
            return .draft
        }
    }

    enum StrategyStanding {
        case draft, approved, replaced
    }

    /// Puts a picture in this person's uploads folder and returns its path.
    ///
    /// Always JPEG and never larger than it needs to be: a phone photo is
    /// twelve megapixels, the models that read it want far less, and every byte
    /// is uploaded on somebody's data plan.
    func uploadAttachment(_ jpeg: Data) async -> String? {
        guard let userID else { return nil }
        let path = "\(userID.uuidString.lowercased())/uploads/\(UUID().uuidString.lowercased()).jpg"
        do {
            _ = try await client.storage
                .from("artifacts")
                .upload(path, data: jpeg, options: FileOptions(contentType: "image/jpeg"))
            return path
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }
}
