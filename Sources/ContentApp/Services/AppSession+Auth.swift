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
        do {
            if isAnonymous {
                do {
                    try await linkGoogle()
                    await refreshAccount()
                    return .linked
                } catch {
                    guard Self.identityTaken(error) else { throw error }
                    // Already somebody's account: become it.
                }
            }
            _ = try await client.auth.signInWithOAuth(provider: .google, redirectTo: callbackURL) { session in
                session.prefersEphemeralWebBrowserSession = false
            }
            await restart()
            return .switched
        } catch is CancellationError {
            return .failed("")
        } catch let error as WebAuth.Failure where error == .cancelled {
            return .failed("")
        } catch {
            return .failed(readableMessage(error))
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
            await restart()
            return .switched
        } catch {
            // The address turned out to belong to an existing account, so the
            // code that arrived was a sign-in code.
            if wasAnonymous,
               let result = try? await client.auth.verifyOTP(email: email, token: token, type: .email) {
                _ = result
                await restart()
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
