import SwiftUI
import UIKit

/// The account screens, ported from Remi: `CreateAccountView`, `EmailView`,
/// `CodeView` and `VerifiedView`.
///
/// None of them reads the flow's own state -- each takes what it needs and
/// calls back -- so the same four screens serve first run and the sheet that
/// Profile and the setup nudge open.

// MARK: - Account

/// The account page, Fuse's way in Postpilot purple (Abel, 7 Nov 2026): words
/// rolling at the top, a purple glow rising from the bottom, Apple as the big
/// button, email as the small one.
struct AccountScreen: View {
    let onEmail: () -> Void
    let onLogin: () -> Void
    let onDone: (OnboardingStep.Arrival) -> Void

    @State private var pending: SignInProvider?
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            RollingWords()
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 70)

            LinearGradient(
                colors: [.clear, Color("LaunchPurple").opacity(0.55), Color("LaunchPurple"), Color(red: 0.24, green: 0.18, blue: 0.82)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 430)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                Image("app-mark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("Your videos,\non autopilot")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)

                Text("Save your setup and make your first video.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 8)

                SocialSignInButtons(mode: .signup, onGlow: true, pending: $pending, error: $error, done: onDone)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                }

                Button(action: onEmail) {
                    Text("Use email instead")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .disabled(pending != nil)

                Button(action: onLogin) {
                    Text("Already have an account? **Log in**")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                }
                .disabled(pending != nil)

                Text("By continuing you agree to our [Terms](https://netrocast.com/terms) & [Privacy Policy](https://netrocast.com/privacy)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .tint(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}

/// Write, Voice, Edit, Post, Grow: the word in the middle full strength, the
/// rest faint, rolling up. Still when Reduce Motion is on.
private struct RollingWords: View {
    private static let words: [(String, String)] = [
        ("Write", "text.alignleft"), ("Voice", "waveform"), ("Edit", "film"),
        ("Post", "paperplane.fill"), ("Grow", "chart.line.uptrend.xyaxis"),
    ]
    private let rowHeight: CGFloat = 54

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let words = Self.words
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<(words.count * 3), id: \.self) { position in
                row(words[position % words.count], active: position == index + 2)
            }
        }
        .offset(y: -rowHeight * CGFloat(index))
        .frame(height: rowHeight * 5, alignment: .top)
        .clipped()
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1100))
                if index + 1 >= words.count * 2 {
                    index = 0
                } else {
                    withAnimation(.spring(duration: 0.55, bounce: 0.15)) { index += 1 }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ word: (String, String), active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: word.1)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .opacity(active ? 1 : 0)
            Text(word.0)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.35))
        }
        .frame(height: rowHeight, alignment: .leading)
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    Text(mode == .signup ? "What is your email address?" : "Welcome back")
                        .font(.system(size: 17, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 70)

                    if mode == .login {
                        Text("Log in with the email you signed up with and we’ll send you a code")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CenteredAuthField(placeholder: "you@example.com", text: $email, focus: $focus, field: .email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(mode == .signup ? .next : .send)
                        .onSubmit { if mode == .signup { focus = .name } else { send() } }

                    if mode == .signup {
                        CenteredAuthField(placeholder: "Your first name", text: $name, focus: $focus, field: .name)
                            .textContentType(.givenName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.send)
                            .onSubmit { send() }
                    }

                    Text(error ?? "We’ll never share your email with anyone")
                        .font(.footnote)
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                        .multilineTextAlignment(.center)

                    if mode == .login {
                        SocialSignInButtons(mode: .login, pending: $pending, error: $error, done: onDone)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)

            AuthTerms().padding(.bottom, 12)

            OnboardingButton(title: "Continue", isBusy: sending, action: send)
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
            return "You’re signed in. Your brand, plans and videos are where you left them\(named)."
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

            OnboardingButton(title: "Go to Postpilot", action: onContinue)
        }
        .onAppear { celebrated = true }
        .sensoryFeedback(.success, trigger: celebrated)
    }
}
