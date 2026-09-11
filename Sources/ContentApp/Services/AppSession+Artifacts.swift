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
