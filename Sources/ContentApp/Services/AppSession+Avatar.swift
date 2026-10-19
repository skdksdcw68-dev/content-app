import Foundation
import Supabase
import UIKit

/// The person's profile picture (0084): choosing it, reading it, removing it.
///
/// Stored like the brand logo (`AppSession+Logo`): a PATH in the private
/// `brand` bucket under the person's own folder, never a URL, and drawn from
/// memory once read.
extension AppSession {
    /// A circle at most 120pt across on a 3x screen.
    private static let avatarPixels: CGFloat = 400

    /// Account facts for the Edit profile screen, from the signed-in session.
    struct AccountFacts: Equatable {
        let email: String?
        /// "Apple", "Google", "Email".
        let signInMethod: String?
        let memberSince: Date?
        let id: String?
    }

    var accountFacts: AccountFacts {
        let user = client.auth.currentUser
        let provider = user?.appMetadata["provider"].flatMap { value -> String? in
            if case let .string(name) = value { return name }
            return nil
        }
        let method: String? = switch provider {
        case "apple": "Apple"
        case "google": "Google"
        case "email": "Email"
        case let other?: other.capitalized
        case nil: nil
        }
        return AccountFacts(
            email: accountEmail ?? user?.email,
            signInMethod: user?.isAnonymous == true ? "Not signed in yet" : method,
            memberSince: user?.createdAt,
            id: user?.id.uuidString
        )
    }

    /// Puts a picture on the profile.
    @discardableResult
    func uploadAvatar(_ image: UIImage) async -> Bool {
        guard let userID else { return false }
        let scaled = Self.squareCrop(image, side: Self.avatarPixels)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else {
            lastError = "That picture could not be read."
            return false
        }
        // A new name each time, so no cache anywhere serves yesterday's face.
        // Lowercase: Postgres compares the folder to auth.uid()::text, which is
        // lowercase, while uuidString is UPPERCASE (the "violates row-level
        // security" error on every upload, 19 Oct).
        let path = "\(userID.uuidString.lowercased())/avatar-\(Int(Date().timeIntervalSince1970)).jpg"
        do {
            _ = try await client.storage.from("brand")
                .upload(path, data: data, options: FileOptions(contentType: "image/jpeg", upsert: true))
            try await client.rpc("set_my_avatar", params: ["p_path": path]).execute()
            if let old = avatarPath, old != path {
                _ = try? await client.storage.from("brand").remove(paths: [old])
            }
            avatarPath = path
            avatarImage = scaled
            MediaCache.shared.keep(scaled, MediaCache.key(path, "avatar"))
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    @discardableResult
    func removeAvatar() async -> Bool {
        guard let path = avatarPath else { return true }
        do {
            try await client.rpc("set_my_avatar", params: ["p_path": ""]).execute()
            _ = try? await client.storage.from("brand").remove(paths: [path])
            avatarPath = nil
            avatarImage = nil
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// The picture, from memory when it is there.
    func loadAvatar() async -> UIImage? {
        guard let path = avatarPath else { return nil }
        if let cached = MediaCache.shared.image(MediaCache.key(path, "avatar")) { return cached }
        guard let data = try? await client.storage.from("brand").download(path: path),
              let image = UIImage(data: data) else { return nil }
        MediaCache.shared.keep(image, MediaCache.key(path, "avatar"))
        return image
    }

    /// The middle square, scaled to `side`: a profile picture is a circle.
    private static func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let edge = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - edge) / 2, y: (image.size.height - edge) / 2)
        let target = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = side / edge
            image.draw(in: CGRect(
                x: -origin.x * scale,
                y: -origin.y * scale,
                width: image.size.width * scale,
                height: image.size.height * scale
            ))
        }
    }
}
