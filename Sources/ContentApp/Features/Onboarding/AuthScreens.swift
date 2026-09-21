import SwiftUI
import UIKit

/// The account screens, ported from Remi: `CreateAccountView`, `EmailView`,
/// `CodeView` and `VerifiedView`.
///
/// None of them reads the flow's own state -- each takes what it needs and
/// calls back -- so the same four screens serve first run and the sheet that
/// Profile and the setup nudge open.

// MARK: - Account

/// "Save your progress": Apple and Google first, email third, then the guest
/// door and the way back for somebody who already has an account.
struct AccountScreen: View {
    let onEmail: () -> Void
    let onLogin: () -> Void
    let onDone: (OnboardingStep.Arrival) -> Void

    @State private var pending: SignInProvider?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("app-mark")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .padding(.bottom, 14)

            Text("Save your progress")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Create an account to keep your brand, your plans and your videos")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 11) {
                SocialSignInButtons(mode: .signup, pending: $pending, error: $error, done: onDone)

                OutlinedAuthButton(title: "Continue with Email", isDisabled: pending != nil, action: onEmail) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.primary)
                        .frame(width: 20)
                }
            }
            .padding(.horizontal, 24)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 32)
            }

            Button(action: onLogin) {
                Text("Already have an account? **Log in**")
                    .font(.subheadline)
            }
            .tint(.primary)
            .padding(.top, 18)
            .disabled(pending != nil)

            AuthTerms()
                .padding(.top, 16)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - Email

/// Sign up: "Enter your email", plus the only name field in Autocast -- an
/// email address says nothing about who somebody is, where Apple and Google
/// already do. Log in: "Welcome back", with the two social buttons under it.
struct EmailScreen: View {
    let mode: OnboardingStep.Mode
    /// Called once the code is on its way, with the address and the name.
    let onSent: (String, String) -> Void
    let onDone: (OnboardingStep.Arrival) -> Void

    @Environment(AppSession.self) private var session

    private enum Field: Hashable { case email, name }

    @State private var email = ""
    @State private var name = ""
    @State private var sending = false
    @State private var pending: SignInProvider?
    @State private var error: String?
    @FocusState private var focus: Field?

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The server's own test, so the button never promises a send it will refuse.
    private var looksLikeEmail: Bool {
        cleanEmail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private var canSend: Bool {
        looksLikeEmail && !sending && pending == nil
            && (mode == .login || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(mode == .signup ? "Enter your email" : "Welcome back")
                    .font(.title2.bold())
                Text(mode == .signup
                     ? "We’ll send you a six-digit code"
                     : "Log in with the email you signed up with — we’ll send you a code")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    AuthTextField(placeholder: "you@example.com", text: $email, symbol: "envelope", focus: $focus, field: .email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(mode == .signup ? .next : .send)
                        .onSubmit { if mode == .signup { focus = .name } else { send() } }

                    if mode == .signup {
                        AuthTextField(placeholder: "Your name", text: $name, symbol: "person", focus: $focus, field: .name)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.send)
                            .onSubmit { send() }
                    }

                    Text(error ?? "We’ll never share your email with anyone")
                        .font(.footnote)
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                        .padding(.horizontal, 4)

                    if mode == .login {
                        SocialSignInButtons(mode: .login, pending: $pending, error: $error, done: onDone)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)

            AuthTerms().padding(.bottom, 12)

            OnboardingButton(title: "Send Code", isBusy: sending, action: send)
                .disabled(!canSend)
        }
        .onAppear { focus = .email }
    }

    private func send() {
        guard canSend else { return }
        error = nil
        sending = true
        Task {
            let outcome = await session.sendEmailCode(to: cleanEmail)
            sending = false
            switch outcome {
            case .codeSent: onSent(cleanEmail, name.trimmingCharacters(in: .whitespacesAndNewlines))
            case .linked: onDone(.created)
            case .switched: onDone(mode == .login ? .returning : .alreadyRegistered)
            case .failed(let reason): if !reason.isEmpty { error = reason }
            }
        }
    }
}

// MARK: - Code

/// Six boxes drawn over one invisible field: one field, not six, is what makes
/// the system's autofill land in a single tap. The sixth digit checks itself.
struct CodeScreen: View {
    let mode: OnboardingStep.Mode
    let email: String
    /// The name typed on the sign-up screen, saved once the code is accepted.
    let name: String
    let wasAnonymous: Bool
    let onDone: (OnboardingStep.Arrival) -> Void

    @Environment(AppSession.self) private var session

    @State private var code = ""
    @State private var checking = false
    @State private var error: String?
    @State private var resendIn = 0
    @State private var countdown: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// Remi's cooldown.
    private let resendDelay = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check your email").font(.title2.bold())
                Text("We sent a six-digit code to \(email.isEmpty ? "your email" : email)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)

            boxes
                .padding(.horizontal, 20)

            Group {
                if resendIn > 0 {
                    Text("Resend available in 0:\(String(format: "%02d", resendIn))")
                        .contentTransition(.numericText(countsDown: true))
                } else {
                    Button("Didn’t receive it? **Resend code**") { resend() }
                        .disabled(checking)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 18)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            OnboardingButton(title: "Verify Code", isBusy: checking) { verify() }
                .disabled(code.count < 6 || checking)
        }
        .onAppear {
            focused = true
            startCountdown()
        }
        .onDisappear { countdown?.cancel() }
        .onChange(of: code) { _, value in
            let digits = String(value.filter(\.isNumber).prefix(6))
            if digits != value { code = digits }
            if digits.count == 6 { verify() }
        }
    }

    private var boxes: some View {
        ZStack {
            // The real field, invisible and underneath: autofill needs one.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focused)
                .accessibilityLabel("Six-digit code")

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    let digit = index < code.count ? String(Array(code)[index]) : ""
                    let isNext = index == code.count && focused
                    Text(digit)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isNext ? Theme.accent : .clear, lineWidth: 1.5)
                        }
                        .animation(.snappy(duration: 0.15), value: isNext)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func verify() {
        guard !checking, code.count == 6 else { return }
        checking = true
        error = nil
        Task {
            let outcome = await session.confirmEmailCode(code, for: email, wasAnonymous: wasAnonymous)
            checking = false
            switch outcome {
            case .linked:
                if !name.isEmpty { await session.saveName(name, promoting: "") }
                onDone(.created)
            case .switched:
                onDone(mode == .login ? .returning : .alreadyRegistered)
            case .failed(let reason):
                error = reason.isEmpty ? "That code didn’t work. Check it and try again." : reason
                code = ""
                focused = true
            case .codeSent:
                break
            }
        }
    }

    private func resend() {
        error = nil
        Task {
            let outcome = await session.sendEmailCode(to: email)
            if case .failed(let reason) = outcome, !reason.isEmpty { error = reason }
            startCountdown()
        }
    }

    /// Cancels any running countdown first, or two would tick the same number
    /// down twice as fast.
    private func startCountdown() {
        countdown?.cancel()
        resendIn = resendDelay
        countdown = Task {
            while resendIn > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                withAnimation(.snappy(duration: 0.2)) { resendIn -= 1 }
            }
        }
    }
}

// MARK: - Verified

/// The one screen that says it worked. Never advances itself: it is the last
/// thing somebody reads before the app opens.
struct VerifiedScreen: View {
    let arrival: OnboardingStep.Arrival
    let onContinue: () -> Void

    @Environment(AppSession.self) private var session
    @State private var celebrated = false

    private var title: String {
        arrival == .returning ? "Welcome back!" : "You’re all set!"
    }

    private var message: String {
        let named = session.displayName.map { ", \($0)" } ?? ""
        switch arrival {
        case .created:
            return "Your account is saved. Everything you make stays with it\(named) 🎉"
        case .alreadyRegistered:
            return "That email already had an account, so we loaded it. To start fresh, delete the account in Profile first."
        case .returning:
            return "You’re signed in — your brand, plans and videos are where you left them\(named)."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: celebrated)

            Text(title)
                .font(.largeTitle.bold())
                .padding(.top, 22)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 32)

            Spacer()

            OnboardingButton(title: "Go to Autocast", action: onContinue)
        }
        .onAppear { celebrated = true }
        .sensoryFeedback(.success, trigger: celebrated)
    }
}
