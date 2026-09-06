import AuthenticationServices
import UIKit

/// Runs an OAuth round trip in a sheet over the app.
///
/// `ASWebAuthenticationSession` is what makes a Web-registered integration feel
/// native: it watches for the callback scheme itself, closes the sheet, and
/// hands the URL back. Nothing leaves the app, no Universal Link is needed, and
/// no App Store URL has to exist yet -- which is exactly why TikTok is
/// registered as a Web platform rather than an iOS one.
@MainActor
enum WebAuth {
    enum Failure: Error, Equatable {
        case cancelled
        case noCallback
        case presentationUnavailable
    }

    static func run(url: URL, scheme: String) async throws -> URL {
        let anchor = AnchorProvider()

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { callback, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: Failure.cancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: Failure.noCallback)
                    return
                }
                continuation.resume(returning: callback)
            }

            session.presentationContextProvider = anchor
            // Uses the shared cookie jar, so somebody already signed in to
            // TikTok in Safari is not made to sign in again. The alternative
            // looks broken to anyone who is already logged in.
            session.prefersEphemeralWebBrowserSession = false

            // Held for the duration; without a strong reference the session is
            // deallocated the moment this scope ends and the sheet never opens.
            anchor.session = session

            if !session.start() {
                continuation.resume(throwing: Failure.presentationUnavailable)
            }
        }
    }
}

/// Tells iOS which window to hang the sheet on.
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = scene?.windows.first { $0.isKeyWindow }
            ?? scene?.windows.first

        return window ?? ASPresentationAnchor()
    }
}
