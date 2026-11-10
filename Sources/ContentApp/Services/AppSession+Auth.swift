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

    /// Passwords are at least this long. The server enforces the same number
    /// (password_min_length), so this only keeps the button honest.
    static let minPasswordLength = 8

    /// What the server knows about an address, from the `check-email`
    /// function: is there an account, can a password log into it, and which
    /// providers it uses. Rate limited per caller on the server.
    struct EmailCheck: Decodable {
        let exists: Bool
        let hasPassword: Bool
        let providers: [String]
    }

    /// nil when the check could not run (offline, throttled). Callers then
    /// carry on as if nothing were known: the real sign-up and log-in calls
    /// below are the source of truth either way, this only gives better words
    /// earlier.
    func checkEmail(_ address: String) async -> EmailCheck? {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try? await client.functions.invoke(
            "check-email",
            options: FunctionInvokeOptions(body: ["email": email])
        )
    }

    /// Step one of signing up with a password. An anonymous account is asked
    /// to add the address (which keeps its rows) and gets the password once the
    /// code is right; anyone signed out is signed up with it at once, and the
    /// account stays unconfirmed until the code is typed.
    func signUpWithPassword(email address: String, password: String) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count > 4 else { return .failed("That email doesn’t look right.") }
        guard password.count >= Self.minPasswordLength else {
            return .failed("Use at least \(Self.minPasswordLength) characters.")
        }
        do {
            if isAnonymous {
                _ = try await client.auth.update(user: UserAttributes(email: email))
            } else {
                let response = try await client.auth.signUp(email: email, password: password)
                // Supabase does not fail when the address already has an
                // account (that would let anyone list who is registered): it
                // answers as if it worked, with a user that has no identities.
                if response.user.identities?.isEmpty ?? false {
                    return .failed("That email already has an account. Go back and log in.")
                }
            }
            pendingPassword = password
            return .codeSent
        } catch {
            if Self.identityTaken(error) {
                return .failed("That email already has an account. Go back and log in.")
            }
            return .failed(readableMessage(error))
        }
    }

    /// Logs in with the password. No code: the address was confirmed when the
    /// account was made.
    func signInWithPassword(email address: String, password: String) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            _ = try await client.auth.signIn(email: email, password: password)
            return .switched
        } catch {
            let raw = "\(error)".lowercased()
            if raw.contains("not confirmed") || raw.contains("confirm your email") {
                return .failed("Check your inbox and confirm your email first.")
            }
            if raw.contains("network") || raw.contains("offline") || raw.contains("timed out") {
                return .failed("Couldn’t reach Postpilot. Check your connection and try again.")
            }
            return .failed("That password doesn’t match.")
        }
    }

    /// Forgot password: emails a six-digit code. The answer is the same
    /// whether or not the address has an account.
    func sendRecoveryCode(to address: String) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count > 4 else { return .failed("That email doesn’t look right.") }
        do {
            try await client.auth.resetPasswordForEmail(email)
            return .codeSent
        } catch {
            return .failed(readableMessage(error))
        }
    }

    /// Re-sends whichever code the page is waiting for.
    func resendCode(to address: String, mode: OnboardingStep.Mode) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mode == .recovery { return await sendRecoveryCode(to: email) }
        do {
            if isAnonymous {
                _ = try await client.auth.update(user: UserAttributes(email: email))
            } else {
                try await client.auth.resend(email: email, type: .signup)
            }
            return .codeSent
        } catch {
            return .failed(readableMessage(error))
        }
    }

    /// Checks the sign-up code, and for a guest saves the password chosen
    /// before it.
    func confirmEmailCode(_ code: String, for address: String, wasAnonymous: Bool) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 6 else { return .failed("Enter the six-digit code.") }
        do {
            if wasAnonymous {
                _ = try await client.auth.verifyOTP(email: email, token: token, type: .emailChange)
                if !pendingPassword.isEmpty {
                    _ = try await client.auth.update(user: UserAttributes(password: pendingPassword))
                }
                pendingPassword = ""
                return .linked
            }
            _ = try await client.auth.verifyOTP(email: email, token: token, type: .signup)
            pendingPassword = ""
            return .switched
        } catch {
            return .failed(readableMessage(error))
        }
    }

    /// Checks the forgot-password code. A right one signs this person in, so
    /// the next page can set the new password; the app reloads for them once
    /// that is saved.
    func confirmRecoveryCode(_ code: String, for address: String) async -> SignUpOutcome {
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 6 else { return .failed("Enter the six-digit code.") }
        do {
            _ = try await client.auth.verifyOTP(email: email, token: token, type: .recovery)
            return .switched
        } catch {
            return .failed(readableMessage(error))
        }
    }

    /// Saves the new password after a right recovery code, then loads the
    /// account.
    func saveNewPassword(_ password: String) async -> SignUpOutcome {
        guard password.count >= Self.minPasswordLength else {
            return .failed("Use at least \(Self.minPasswordLength) characters.")
        }
        do {
            _ = try await client.auth.update(user: UserAttributes(password: password))
            return .switched
        } catch {
            return .failed(readableMessage(error))
        }
    }

    /// What follows an accepted code. Kept apart from the check so the code
    /// page can show its green button first: restarting swaps the whole screen
    /// for the splash, which hid the button before anyone saw it.
    func settleAfterCode(_ outcome: SignUpOutcome) async {
        switch outcome {
        case .linked: await refreshAccount()
        case .switched: await restart(signingIn: true)
        default: break
        }
    }

    // MARK: - Shared

    /// Re-reads who is signed in after linking, without reloading the app.
    func refreshAccount() async {
        if let user = try? await client.auth.session.user { readAccount(user) }
        await refreshSubscription()
        // A purchase made before signing in is stamped with the anonymous id
        // it was bought under. Claimed here, while the person is present.
        if !isAnonymous { await claimPurchasesAfterSignIn() }
    }

    /// Supabase's way of saying "that identity already has an account".
    private static func identityTaken(_ error: Error) -> Bool {
        let text = "\(error)".lowercased()
        return text.contains("already") || text.contains("exists") || text.contains("registered")
    }
}
