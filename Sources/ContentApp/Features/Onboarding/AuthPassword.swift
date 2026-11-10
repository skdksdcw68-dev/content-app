import SwiftUI

/// The password page, in the email page's calm look: one question, big quiet
/// fields, the dark pill above the keyboard.
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

    private enum Field: Hashable { case password, confirm }

    @State private var password = ""
    @State private var confirm = ""
    @State private var show = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private var asksTwice: Bool { purpose != .signIn }

    private var canSubmit: Bool {
        guard !busy else { return false }
        if purpose == .signIn { return !password.isEmpty }
        return password.count >= AppSession.minPasswordLength && password == confirm
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
        case .create: return "You’ll use it to log back in. At least \(AppSession.minPasswordLength) characters."
        case .signIn: return "\(email) has an account. Enter your password to log in."
        case .reset: return "Make it something you’ll remember. At least \(AppSession.minPasswordLength) characters."
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
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.22)
                .multilineTextAlignment(.center)
                .padding(.top, 160)
                .padding(.horizontal, 24)

            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(OB.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.top, 8)

            VStack(spacing: 4) {
                field("Password", text: $password, field: .password)
                    .submitLabel(asksTwice ? .next : .go)
                    .onSubmit {
                        if asksTwice { focus = .confirm } else { submit() }
                    }
                    .textContentType(purpose == .signIn ? .password : .newPassword)

                if asksTwice {
                    field("Confirm password", text: $confirm, field: .confirm)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                        .textContentType(.newPassword)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            if asksTwice, !confirm.isEmpty, password != confirm {
                Text("The two passwords don’t match.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 6)
            }

            if purpose == .signIn {
                Button { onNext(.email(.recovery)) } label: {
                    Text("Forgot password?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OB.accent)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(QuestionHazeBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BevelPill(title: pillTitle, on: canSubmit, busy: busy, width: nil) { submit() }
                .disabled(!canSubmit)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .onAppear { focus = .password }
        .onChange(of: password) { _, _ in error = nil }
        .onChange(of: confirm) { _, _ in error = nil }
    }

    /// One big, quiet field with an eye to show what was typed.
    private func field(_ prompt: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 8) {
            Group {
                if show {
                    TextField("", text: text, prompt: promptText(prompt))
                } else {
                    SecureField("", text: text, prompt: promptText(prompt))
                }
            }
            .font(.system(size: 22, weight: .medium))
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: field)

            Button { show.toggle() } label: {
                Image(systemName: show ? "eye.slash" : "eye")
                    .font(.system(size: 17))
                    .foregroundStyle(OB.text3)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(show ? "Hide password" : "Show password")
        }
        .padding(.leading, 32)
        .padding(.trailing, 4)
        .frame(height: 52)
    }

    private func promptText(_ text: String) -> Text {
        Text(text).font(.system(size: 17)).foregroundStyle(OB.text3)
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
