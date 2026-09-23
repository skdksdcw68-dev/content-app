import Foundation
import Supabase

/// Saving the account: Google, or an emailed code. (Apple lives in
/// AppSession+Profile, next to the token handling it needs.)
///
/// Every path links to the account already in use when that account is still
/// the anonymous one, so nothing somebody made before signing up is lost. Only
/// when the identity already belongs to someone else does it sign in as them
/// instead, and then everything on screen is reloaded for that person.
extension AppSession {
    enum SignUpOutcome {
        /// This account is now saved. Nothing moved.
        case linked
        /// That identity already had an account; the app is now that one.
        case switched
        case failed(String)
        /// A code is on its way to the address.
        case codeSent
    }

    private var callbackURL: URL { URL(string: "autocast://auth")! }

    // MARK: - Google

    func signInWithGoogle() async -> SignUpOutcome {
        // Google's own sheet when the app was built with a client id: it names
        // Autocast, where the browser round trip names the Supabase project.
        if GoogleAuth.isConfigured { return await signInWithGoogleNatively() }
        return await signInWithGoogleInBrowser()
    }

    private func signInWithGoogleNatively() async -> SignUpOutcome {
        let nonce = AppSession.appleNonce()
        var linkFailure: Error?
        do {
            let result = try await GoogleAuth.signIn(hashedNonce: nonce.hashed)
            let credentials = OpenIDConnectCredentials(provider: .google, idToken: result.idToken, nonce: nonce.raw)
            if isAnonymous {
                do {
                    let linked = try await client.auth.linkIdentityWithIdToken(credentials: credentials)
                    readAccount(linked.user)
                    await adoptName(result.name)
                    await refreshSubscription()
                    return .linked
                } catch {
                    // Signing in as that Google account is tried next whatever
                    // the reason was; only its failure is worth showing. See
                    // the same note in `signInWithApple`.
                    linkFailure = error
                }
            }
            _ = try await client.auth.signInWithIdToken(credentials: credentials)
            await restart(signingIn: true)
            await adoptName(result.name)
            return .switched
        } catch GoogleAuth.Failure.cancelled {
            return .failed("")
        } catch {
            return .failed(readableMessage(linkFailure ?? error))
        }
    }

    private func signInWithGoogleInBrowser() async -> SignUpOutcome {
        var linkFailure: Error?
        do {
            if isAnonymous {
                do {
                    try await linkGoogle()
                    await refreshAccount()
                    return .linked
                } catch {
                    // Already somebody's account, or something else entirely:
                    // either way, become that account and report only if that
                    // fails too.
                    linkFailure = error
                }
            }
            _ = try await client.auth.signInWithOAuth(provider: .google, redirectTo: callbackURL) { session in
                session.prefersEphemeralWebBrowserSession = false
            }
            await restart(signingIn: true)
            return .switched
        } catch is CancellationError {
            return .failed("")
        } catch let error as WebAuth.Failure where error == .cancelled {
            return .failed("")
        } catch {
            return .failed(readableMessage(linkFailure ?? error))
        }
    }

    /// The linking round trip, run through our own browser sheet so the
    /// callback comes back here rather than through a deep link the app has to
    /// catch later.
    private func linkGoogle() async throws {
        var opened: Task<Void, Never>?
        try await client.auth.linkIdentity(provider: .google, redirectTo: callbackURL) { url in
            opened = Task { @MainActor in
                guard let callback = try? await WebAuth.run(url: url, scheme: Config.callbackScheme) else { return }
                _ = try? await self.client.auth.session(from: callback)
            }
        }
        await opened?.value
    }

    // MARK: - Email

    /// Sends the six-digit code. An anonymous account is asked to add the
    /// address (which keeps its rows); anyone signed out is sent a sign-in
    /// code that also creates the account if it is new.
    func sendEmailCode(to address: String) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count > 4 else { return .failed("That email doesn’t look right.") }
        do {
            if isAnonymous {
                _ = try await client.auth.update(user: UserAttributes(email: email))
            } else {
                try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
            }
            return .codeSent
        } catch {
            // An address already in use cannot be added to this account; sign
            // in to it instead, which the next code does.
            if Self.identityTaken(error) {
                do {
                    try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
                    return .codeSent
                } catch {
                    return .failed(readableMessage(error))
                }
            }
            return .failed(readableMessage(error))
        }
    }

    /// Checks the code. Which kind it is depends on how it was sent.
    func confirmEmailCode(_ code: String, for address: String, wasAnonymous: Bool) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 6 else { return .failed("Enter the six-digit code.") }
        do {
            if wasAnonymous {
                _ = try await client.auth.verifyOTP(email: email, token: token, type: .emailChange)
                await refreshAccount()
                return .linked
            }
            _ = try await client.auth.verifyOTP(email: email, token: token, type: .email)
            await restart(signingIn: true)
            return .switched
        } catch {
            // The address turned out to belong to an existing account, so the
            // code that arrived was a sign-in code.
            if wasAnonymous,
               let result = try? await client.auth.verifyOTP(email: email, token: token, type: .email) {
                _ = result
                await restart(signingIn: true)
                return .switched
            }
            return .failed(readableMessage(error))
        }
    }

    // MARK: - Shared

    /// Re-reads who is signed in after linking, without reloading the app.
    func refreshAccount() async {
        if let user = try? await client.auth.session.user { readAccount(user) }
        await refreshSubscription()
    }

    /// Supabase's way of saying "that identity already has an account".
    private static func identityTaken(_ error: Error) -> Bool {
        let text = "\(error)".lowercased()
        return text.contains("already") || text.contains("exists") || text.contains("registered")
    }
}
