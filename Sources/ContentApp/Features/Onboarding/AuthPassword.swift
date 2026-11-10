import SwiftUI

/// The password page, as the sign-up mockup draws it: one question, the
/// password as big dots in the middle, a Show pill top right, a plain line
/// saying how far it is from long enough, and (once it is long enough) a
/// second field to type it again. No segments, no boxes.
///
/// Three jobs, told apart by `purpose`:
///   - `.create`: a new password (twice) while signing up; Continue emails the
///     six-digit code.
///   - `.signIn`: the password of an account that already exists. No code
///     here -- the address was confirmed when the account was made. A wrong
///     one says so plainly and "Forgot password?" is always there.
///   - `.reset`: the new password after the forgot-password code was right.
///
/// The same rules as Drobe's sign-in: at least eight characters, typed twice
/// when it is new, and the server (not this page) is what actually refuses a
/// weak one, an unconfirmed address, or too many tries.
struct PasswordScreen: View {
    let purpose: OnboardingStep.Purpose
    let email: String
    /// Where to go next: the code page after a sign-up, or the email page for
    /// "Forgot password?".
    let onNext: (OnboardingStep) -> Void
    let onDone: (OnboardingStep.Arrival) -> Void

    @Environment(AppSession.self) private var session

    @State private var password = ""
    @State private var confirm = ""
    @State private var show = false
    /// Which field has the keyboard: 1 or 2.
    @State private var active = 1
    @State private var busy = false
    @State private var error: String?

    private var asksTwice: Bool { purpose != .signIn }
    private var minimum: Int { AppSession.minPasswordLength }
    private var longEnough: Bool { password.count >= minimum }
    private var matches: Bool { longEnough && !confirm.isEmpty && confirm == password }
    /// Typed so far, and already different from the start of the password.
    private var notTheSame: Bool { !confirm.isEmpty && !password.hasPrefix(confirm) }

    private var canSubmit: Bool {
        guard !busy else { return false }
        return purpose == .signIn ? !password.isEmpty : matches
    }

    private var title: String {
        switch purpose {
        case .create: return "Create a password"
        case .signIn: return "Welcome back"
        case .reset: return "Set a new password"
        }
    }

    private var subtitle: String {
        switch purpose {
        case .create: return "You’ll use it to log back in."
        case .signIn: return "\(email) has an account. Enter your password to log in."
        case .reset: return "Make it something you’ll remember."
        }
    }

    private var pillTitle: String {
        switch purpose {
        case .create: return "Continue"
        case .signIn: return "Log in"
        case .reset: return "Save password"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.26)
                .multilineTextAlignment(.center)
                .padding(.top, 130)
                .padding(.horizontal, 24)

            Text(subtitle)
                .font(.system(size: 17))
                .foregroundStyle(OB.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.top, 8)

            BigPasswordField(
                prompt: "Password",
                text: $password,
                show: show,
                compareTo: nil,
                isNewPassword: asksTwice,
                wantsFocus: active == 1,
                onFocus: { active = 1 },
                onSubmit: { if asksTwice { if longEnough { active = 2 } } else { submit() } },
                submitLabel: asksTwice ? .next : .go
            )
            .padding(.horizontal, 12)
            .padding(.top, 22)

            if asksTwice {
                Label {
                    Text(rule)
                } icon: {
                    if longEnough { Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)) }
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(longEnough ? Color(.systemGreen) : OB.text2)
                .padding(.top, 2)
                .animation(.easeOut(duration: 0.2), value: longEnough)
            }

            if asksTwice, longEnough {
                VStack(spacing: 2) {
                    BigPasswordField(
                        prompt: "Type it again",
                        text: $confirm,
                        show: show,
                        compareTo: password,
                        isNewPassword: true,
                        wantsFocus: active == 2,
                        onFocus: { active = 2 },
                        onSubmit: { submit() },
                        submitLabel: .go
                    )

                    Label {
                        Text(matches ? "They match" : "Not the same yet")
                    } icon: {
                        if matches { Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)) }
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(matches ? Color(.systemGreen) : Color(.systemRed))
                    .opacity(notTheSame || matches ? 1 : 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .transition(.opacity.combined(with: .offset(y: 10)))
            }

            if let error {
                Text(error)
                    .font(.system(size: 15))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 10)
            }

            if purpose == .signIn {
                Button { onNext(.email(.recovery)) } label: {
                    Text("Forgot password?")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OB.accent)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.28), value: longEnough)
        .background(QuestionHazeBackground())
        .overlay(alignment: .topTrailing) {
            ShowPasswordPill(show: $show)
                .padding(.trailing, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BevelPill(title: pillTitle, on: canSubmit, busy: busy, width: nil) { submit() }
                .disabled(!canSubmit)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .onChange(of: password) { _, _ in error = nil }
        .onChange(of: confirm) { _, _ in error = nil }
    }

    private var rule: String {
        if longEnough { return "Long enough" }
        if password.isEmpty { return "At least \(minimum) characters" }
        return "\(password.count) of \(minimum) characters"
    }

    private func submit() {
        guard canSubmit else { return }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            switch purpose {
            case .create:
                let outcome = await session.signUpWithPassword(email: email, password: password)
                switch outcome {
                case .failed(let reason): if !reason.isEmpty { error = reason }
                default: onNext(.code(.signup))
                }

            case .signIn:
                let outcome = await session.signInWithPassword(email: email, password: password)
                if case .failed(let reason) = outcome {
                    if !reason.isEmpty { error = reason }
                } else {
                    await session.settleAfterCode(outcome)
                    onDone(.returning)
                }

            case .reset:
                let outcome = await session.saveNewPassword(password)
                if case .failed(let reason) = outcome {
                    if !reason.isEmpty { error = reason }
                } else {
                    await session.settleAfterCode(outcome)
                    onDone(.returning)
                }
            }
        }
    }
}
