import SwiftUI
import AuthenticationServices

/// The pieces every way in shares, ported from Remi's `SignInParts`
/// (remi/native/Sources/Remi/Views/Onboarding/SignInParts.swift) so signing up
/// here looks and behaves exactly like signing up there.

/// What is signing in right now, so every button can stand down while one
/// sheet is up.
enum SignInProvider: Equatable { case apple, google, email }

/// Apple and Google -- the two ways in that need no typing.
///
/// 🔴 Nobody who uses either is asked their name. Apple hands it over on the
/// first authorization ever, Google on every one. Asking anyway, before the app
/// has been used, is what App Review rejects (5.1.1(v)).
struct SocialSignInButtons: View {
    let mode: OnboardingStep.Mode
    @Binding var pending: SignInProvider?
    @Binding var error: String?
    /// Called with how they arrived, so Verified can say the right thing.
    let done: (OnboardingStep.Arrival) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    /// Kept here rather than on the session: it belongs to one button press.
    @State private var nonce = ""

    var body: some View {
        VStack(spacing: 11) {
            appleButton

            OutlinedAuthButton(
                title: mode == .signup ? "Continue with Google" : "Log in with Google",
                isBusy: pending == .google,
                isDisabled: pending != nil
            ) {
                error = nil
                pending = .google
                Task {
                    let outcome = await session.signInWithGoogle()
                    pending = nil
                    finish(outcome)
                }
            } glyph: {
                Image("GoogleG")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Apple's own control, which their guidelines require -- black on a light
    /// screen, white on a dark one.
    private var appleButton: some View {
        SignInWithAppleButton(mode == .signup ? .continue : .signIn) { request in
            let fresh = AppSession.appleNonce()
            nonce = fresh.raw
            // The name matters as much as the email: Apple returns it only when
            // asked, and only on the first authorization ever.
            request.requestedScopes = [.fullName, .email]
            request.nonce = fresh.hashed
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                error = nil
                pending = .apple
                let used = nonce
                Task {
                    let outcome = await session.signInWithApple(authorization, nonce: used)
                    pending = nil
                    finish(outcome)
                }
            case .failure(let failure):
                // Closing the sheet is not an error worth showing.
                if (failure as NSError).code == ASAuthorizationError.canceled.rawValue { return }
                error = failure.localizedDescription
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(pending != nil)
        // Rebuilt when the appearance flips, so the button's style follows.
        .id(colorScheme)
    }

    private func finish(_ outcome: AppSession.SignUpOutcome) {
        switch outcome {
        case .linked:
            done(mode == .login ? .returning : .created)
        case .switched:
            done(mode == .login ? .returning : .alreadyRegistered)
        case .codeSent:
            break
        case .failed(let reason):
            if !reason.isEmpty { error = reason }
        }
        session.lastError = nil
    }
}

/// A quiet outlined row for a way in -- Remi's provider button.
struct OutlinedAuthButton<Glyph: View>: View {
    let title: String
    var isBusy = false
    var isDisabled = false
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    HStack(spacing: 11) {
                        glyph()
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

/// A field on the email page: the system's text field in the app's card shape,
/// outlined in the accent while it is being typed in.
struct AuthTextField<Field: Hashable>: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String?
    let focus: FocusState<Field?>.Binding
    let field: Field

    private var isFocused: Bool { focus.wrappedValue == field }

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                    .frame(width: 20)
            }
            TextField(placeholder, text: $text)
                .focused(focus, equals: field)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? Theme.accent : .clear, lineWidth: 1.5)
        }
        .animation(.snappy(duration: 0.18), value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = field }
    }
}

/// The line every way in carries, with the documents one tap away.
struct AuthTerms: View {
    var body: some View {
        Text("By continuing you agree to our [Terms](https://netrocast.com/terms) & [Privacy Policy](https://netrocast.com/privacy)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(Color.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
    }
}

/// The big button at the bottom of an onboarding screen.
struct OnboardingButton: View {
    let title: String
    var tint: Color = Theme.accent
    /// Working: the system's spinner takes the button's place, rather than the
    /// word "Sending" (Abel, 21 Sep 2026).
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .tint(Theme.onAccent)
                } else {
                    Text(title)
                        .fontWeight(.semibold)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(RemiFilledButtonStyle())
        .tint(tint)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
