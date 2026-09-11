import Foundation
import Supabase

/// What the agent made, and the work still making it.
///
/// Everything here reads. The agent writes artefacts and run events on the
/// server; the app follows along and shows them. The one write is an upload
/// into the person's own `uploads/` folder, which the storage policy in 0033
/// allows and nothing else does.
extension AppSession {

    /// One artefact, if it is this person's.
    func artifact(_ id: UUID) async -> Artifact? {
        do {
            let rows: [Artifact] = try await client
                .rpc("artifact", params: ["p_id": id.uuidString])
                .execute()
                .value
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

    /// The file, on disk under the name somebody would expect, for Quick Look
    /// and the share sheet. Both need a real file with a real extension; a
    /// signed URL is neither.
    func localCopy(of artifact: Artifact) async -> URL? {
        guard let path = artifact.storagePath else { return nil }
        let name = artifact.body.filename ?? (path as NSString).lastPathComponent
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(artifact.id.uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: target.path) { return target }

        do {
            let data = try await client.storage.from("artifacts").download(path: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }

    /// The provider's own price for one image or video with exactly these
    /// settings -- its dry run, which submits nothing. Nil when it will not say.
    func quote(capability: String, model: String, prompt: String, settings: GenerationSettings) async -> ModelCost? {
        struct Request: Encodable, Sendable {
            let capability: String
            let model: String
            let prompt: String
            let settings: Settings
            struct Settings: Encodable, Sendable {
                let resolution: String?
                let duration: Int?
                let quality: String?
            }
        }
        struct Response: Decodable { let cost: ModelCost }
        do {
            let response: Response = try await client.functions.invoke(
                "quote",
                options: FunctionInvokeOptions(body: Request(
                    capability: capability,
                    model: model,
                    prompt: prompt,
                    settings: .init(
                        resolution: settings.resolution,
                        duration: settings.duration.map { Int($0.rounded()) },
                        quality: settings.quality
                    )
                ))
            )
            return response.cost
        } catch {
            return nil
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
