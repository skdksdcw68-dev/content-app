import SwiftUI

/// Signing up (or back in) from inside the app: Profile's account row and the
/// setup nudge both open this.
///
/// The same four screens first run uses, driven by a phase of its own instead
/// of the session's -- so the flow reads identically wherever it is met, and
/// closing it never leaves onboarding half-done.
struct AuthSheet: View {
    var mode: OnboardingStep.Mode = .signup
    var onDone: (() -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case account
        case email(OnboardingStep.Mode)
        case password(OnboardingStep.Purpose)
        case code(OnboardingStep.Mode)
        case verified(OnboardingStep.Arrival)
    }

    /// The first-run flow's steps and this sheet's phases are the same pages.
    private func phaseFor(_ step: OnboardingStep) -> Phase {
        switch step {
        case .email(let mode): return .email(mode)
        case .password(let purpose): return .password(purpose)
        case .code(let mode): return .code(mode)
        case .verified(let arrival): return .verified(arrival)
        default: return .account
        }
    }

    @State private var phase: Phase = .account
    @State private var email = ""
    @State private var name = ""
    @State private var wasAnonymous = true

    var body: some View {
        NavigationStack {
            content
                .background(Theme.canvas.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if canGoBack {
                            Button { back() } label: {
                                Image(systemName: "chevron.left").fontWeight(.semibold)
                            }
                            .accessibilityLabel("Back")
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        if !canGoBack {
                            Button("Not now") { finish() }
                        }
                    }
                }
                .animation(.snappy(duration: 0.25), value: phase)
        }
        .onAppear {
            wasAnonymous = session.isAnonymous
            if mode == .login { phase = .email(.login) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .account:
            AccountScreen(
                onEmail: { phase = .email(.signup) },
                onLogin: { phase = .email(.login) },
                onDone: { phase = .verified($0) }
            )

        case .email(let mode):
            EmailScreen(
                mode: mode,
                onNext: { address, next in
                    email = address
                    session.pendingEmail = address
                    wasAnonymous = session.isAnonymous
                    phase = phaseFor(next)
                },
                onSwitch: { phase = .email($0) },
                onDone: { phase = .verified($0) }
            )

        case .password(let purpose):
            PasswordScreen(
                purpose: purpose,
                email: email,
                onNext: { next in
                    // "Forgot password?" from the log-in page, or the code
                    // page after choosing a password.
                    phase = phaseFor(next)
                },
                onDone: { phase = .verified($0) }
            )

        case .code(let mode):
            CodeScreen(
                mode: mode,
                email: email,
                name: name,
                wasAnonymous: wasAnonymous,
                onRecovered: { phase = .password(.reset) },
                onDone: { phase = .verified($0) }
            )

        case .verified(let arrival):
            VerifiedScreen(arrival: arrival) { finish() }
        }
    }

    private var canGoBack: Bool {
        switch phase {
        case .email, .password, .code: return true
        case .account, .verified: return false
        }
    }

    private func back() {
        switch phase {
        case .email(let mode): phase = mode == .recovery ? .password(.signIn) : .account
        case .password(let purpose): phase = purpose == .create ? .email(.signup) : .email(.login)
        case .code(let mode):
            switch mode {
            case .signup: phase = .password(.create)
            case .login: phase = .email(.login)
            case .recovery: phase = .email(.recovery)
            }
        case .account, .verified: break
        }
    }

    private func finish() {
        session.lastError = nil
        if let onDone { onDone() } else { dismiss() }
    }
}
