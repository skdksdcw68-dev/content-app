import Foundation
import Supabase
import UIKit

/// The brand's own mark: uploading it, reading it back, removing it.
///
/// Abel, 25 Sep 2026: *"on the same page 'your name or your logo' -- so when
/// the user hits that, the user goes and again goes, but the user is never
/// asked to upload his logo... this is what makes the app terrible."*
///
/// He was describing a promise the app could not keep. "Your name or logo" was
/// offered when starting a series and there was no field to hold one, no picker
/// to choose one, and no bucket to put it in — so picking it appended a
/// sentence to a text brief and was forgotten.
///
/// 🔴 What is stored is the PATH, never a URL. A signed link expires in an
/// hour; one written into a row is a link that cannot resolve tomorrow, or on
/// another phone, or after a reinstall. Links are minted per read.
extension AppSession {
    /// The biggest a logo is ever drawn, times a 3x screen. Anything larger is
    /// somebody's 4000px export being carried around for no reason.
    private static let logoPixels: CGFloat = 512

    /// Puts a logo on the brand and remembers where it went.
    ///
    /// - Returns: true when it is stored and the brand knows about it.
    @discardableResult
    func uploadLogo(_ image: UIImage) async -> Bool {
        guard let userID, let brandID = brand?.id else { return false }
        isWorking = true
        defer { isWorking = false }

        // Shrunk before it leaves the phone: the generator needs a mark, not a
        // photograph, and a 12MB PNG helps nobody on a slow connection.
        let scaled = Self.fit(image, longest: Self.logoPixels)
        // PNG, because a logo is the one image in this app that genuinely
        // needs transparency — a white box behind a mark ruins the shot.
        guard let data = scaled.pngData() else {
            lastError = "That picture could not be read."
            return false
        }

        // Namespaced by user first: the storage policy reads folder one and
        // compares it to auth.uid(), exactly as `artifacts` does.
        let path = "\(userID.uuidString)/\(brandID.uuidString)/logo.png"

        do {
            _ = try await client.storage
                .from("brand")
                .upload(
                    path,
                    data: data,
                    options: FileOptions(contentType: "image/png", upsert: true)
                )
            struct Params: Encodable, Sendable { let p_brand: String; let p_path: String }
            try await client
                .rpc("set_brand_logo", params: Params(p_brand: brandID.uuidString, p_path: path))
                .execute()

            brand?.logoPath = path
            // Drawn straight away rather than after a round trip.
            MediaCache.shared.keep(scaled, MediaCache.key(path, "logo"))
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Takes the logo off the brand. The file goes too -- a mark somebody
    /// removed should not sit in a bucket they have forgotten about.
    @discardableResult
    func removeLogo() async -> Bool {
        guard let brandID = brand?.id, let path = brand?.logoPath else { return true }
        do {
            struct Params: Encodable, Sendable { let p_brand: String; let p_path: String }
            try await client
                .rpc("set_brand_logo", params: Params(p_brand: brandID.uuidString, p_path: ""))
                .execute()
            _ = try? await client.storage.from("brand").remove(paths: [path])
            brand?.logoPath = nil
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// The logo to draw, from memory when it is there.
    func logoImage() async -> UIImage? {
        guard let path = brand?.logoPath else { return nil }
        if let cached = MediaCache.shared.image(MediaCache.key(path, "logo")) { return cached }

        guard let data = try? await client.storage.from("brand").download(path: path),
              let image = UIImage(data: data) else { return nil }
        MediaCache.shared.keep(image, MediaCache.key(path, "logo"))
        return image
    }

    /// A signed link, for handing to a generator that fetches it itself.
    /// Minted per use and short-lived, like every other link in the app.
    func logoURL() async -> URL? {
        guard let path = brand?.logoPath else { return nil }
        return try? await client.storage.from("brand").createSignedURL(path: path, expiresIn: 3600)
    }

    /// Scaled to fit a box, keeping its shape. Never enlarged: blowing up a
    /// small mark only makes a soft one.
    private static func fit(_ image: UIImage, longest: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > longest else { return image }
        let scale = longest / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
