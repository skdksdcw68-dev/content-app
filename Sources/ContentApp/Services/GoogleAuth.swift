import Foundation
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// Google's own sheet, rather than a browser round trip.
///
/// The browser flow shows the Supabase project URL -- "continue to
/// dosszkllkassvyprkhrg.supabase.co" -- which is what Abel saw (21 Sep 2026).
/// Google's SDK shows the app: its name, its icon, and the account picker the
/// person already knows. Remi's `AuthService` does the same thing.
///
/// The client id lives in Info.plist as `GIDClientID`; where it is missing the
/// caller falls back to the browser flow, so a build without it still works.
@MainActor
enum GoogleAuth {
    struct Result: Sendable {
        let idToken: String
        /// Google returns the name every time, so nobody has to be asked for it.
        let name: String?
    }

    enum Failure: Error, Equatable {
        case notConfigured
        case noPresenter
        case missingIDToken
        case cancelled
    }

    /// Whether the app was built with a client id to use.
    static var isConfigured: Bool {
        #if canImport(GoogleSignIn)
        return clientID != nil
        #else
        return false
        #endif
    }

    static var clientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
        return value?.isEmpty == false ? value : nil
    }

    /// `nonce` is the SHA-256 of the raw nonce; Supabase checks the raw one
    /// against the token Google signs, the same handshake Apple uses.
    static func signIn(hashedNonce: String) async throws -> Result {
        #if canImport(GoogleSignIn)
        guard clientID != nil else { throw Failure.notConfigured }
        guard let presenter = topViewController else { throw Failure.noPresenter }
        do {
            let signIn = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: nil,
                nonce: hashedNonce
            )
            guard let idToken = signIn.user.idToken?.tokenString else { throw Failure.missingIDToken }
            let full: String? = signIn.user.profile?.name
            let name = full?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return Result(idToken: idToken, name: (name?.isEmpty == false) ? name : nil)
        } catch {
            // -5 is the SDK's "they closed the sheet", which is not a failure
            // worth showing anybody.
            if (error as NSError).code == -5 { throw Failure.cancelled }
            throw error
        }
        #else
        throw Failure.notConfigured
        #endif
    }

    static func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }

    /// Google hands the result back through the reversed-client-id scheme.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        return GIDSignIn.sharedInstance.handle(url)
        #else
        return false
        #endif
    }

    /// Whatever is frontmost -- the sheet is presented from the top, or it
    /// silently fails to appear over one that is already up.
    private static var topViewController: UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
