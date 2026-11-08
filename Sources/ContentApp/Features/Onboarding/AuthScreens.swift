import SwiftUI
import UIKit

/// The account screens, ported from Remi: `CreateAccountView`, `EmailView`,
/// `CodeView` and `VerifiedView`.
///
/// None of them reads the flow's own state -- each takes what it needs and
/// calls back -- so the same four screens serve first run and the sheet that
/// Profile and the setup nudge open.

// MARK: - Account

/// The account page, Fuse's way in Postpilot purple, as the mockup draws it:
/// words rolling at the top, a purple glow rising from the very bottom, the
/// white mark, Apple as the big white pill, Google as the frosted one.
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
                .padding(.top, 66)

            VStack(alignment: .leading, spacing: 10) {
                MarkTile(size: 44, inverted: true)

                Text("Your videos,\non autopilot")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.48)
                    .lineSpacing(-1)
                    .foregroundStyle(.white)

                Text("Save your setup and make your first video.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 6)

                SocialSignInButtons(mode: .signup, onGlow: true, pending: $pending, error: $error, done: onDone)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white)
                }

                Button(action: onEmail) {
                    Text("Use email instead")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(ObPressStyle())
                .disabled(pending != nil)

                Button(action: onLogin) {
                    Text("Already have an account? **Log in**")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(pending != nil)

                Text("By continuing you agree to our [Terms](https://netrocast.com/terms) & [Privacy Policy](https://netrocast.com/privacy)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .tint(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background { AccountGlow() }
    }
}

/// `.glow`: the purple rising 520 pt from the bottom edge of the SCREEN, under
/// the home indicator too, so no strip is left under the last line. Deeper in
/// dark mode.
private struct AccountGlow: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(stops: [
                .init(color: OB.glow1.opacity(0), location: 0),
                .init(color: OB.glow1, location: 0.26),
                .init(color: OB.glow2, location: 0.58),
                .init(color: OB.glow3, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 520)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Write, Voice, Edit, Post, Grow: the word in the middle full strength with
/// its mark, the rest faint, rolling up every 1.1 s on the mockup's curve (no
/// spring). Still when Reduce Motion is on.
private struct RollingWords: View {
    private static let words: [(String, String)] = [
        ("Write", "list.clipboard"), ("Voice", "waveform"), ("Edit", "photo.stack"),
        ("Post", "arrow.up"), ("Grow", "sparkles"),
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
        .frame(height: 270, alignment: .top)
        .clipped()
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.3),
            .init(color: .black, location: 0.7),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1100))
                if index + 1 >= words.count * 2 {
                    index = 0
                } else {
                    withAnimation(.timingCurve(0.3, 0.9, 0.3, 1, duration: 0.55)) { index += 1 }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ word: (String, String), active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: word.1)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(OB.accent)
                .frame(width: 28, height: 28)
                .opacity(active ? 1 : 0)
            Text(word.0)
                .font(.system(size: 40, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(active ? Color.primary : OB.text3)
        }
        .frame(height: rowHeight, alignment: .leading)
        .animation(.easeOut(duration: 0.4), value: active)
    }
}

// MARK: - Email

/// Bevel's page, as the mockup draws it: one question in the middle, a big
/// field with no line or box, a small quiet example, and the dark pill that
/// wakes once the address looks right, sitting just above the keyboard. Log
/// in says "Welcome back" and offers Apple and Google too.
struct EmailScreen: View {
    let mode: OnboardingStep.Mode
    /// Called once the code is on its way, with the address and the name.
    let onSent: (String, String) -> Void
    let onDone: (OnboardingStep.Arrival) -> Void

    @Environment(AppSession.self) private var session

    private enum Field: Hashable { case email }

    @State private var email = ""
    @State private var sending = false
    @State private var pending: SignInProvider?
    @State private var error: String?
    @FocusState private var focus: Field?

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The server's own test, so the button never promises a send it will refuse.
    private var looksLikeEmail: Bool {
        cleanEmail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#, options: .regularExpression) != nil
    }

    private var canSend: Bool {
        looksLikeEmail && !sending && pending == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(mode == .signup ? "What is your email address?" : "Welcome back")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.22)
                .multilineTextAlignment(.center)
                .padding(.top, 160)
                .padding(.horizontal, 24)

            if mode == .login {
                Text("Log in with the email you signed up with and we’ll send you a code")
                    .font(.system(size: 15))
                    .foregroundStyle(OB.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
                    .padding(.top, 8)
            }

            TextField("", text: $email, prompt: Text("name@example.com").font(.system(size: 17)).foregroundStyle(OB.text3))
                .font(.system(size: 28, weight: .medium))
                .tracking(-0.28)
                .multilineTextAlignment(.center)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($focus, equals: .email)
                .onSubmit { send() }
                .frame(height: 48)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 6)
            }

            if mode == .login {
                SocialSignInButtons(mode: .login, pending: $pending, error: $error, done: onDone)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(QuestionHazeBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BevelPill(title: "Continue", on: looksLikeEmail, busy: sending, width: nil) { send() }
                .disabled(!canSend)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
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
            case .codeSent: onSent(cleanEmail, session.pendingName)
            case .linked: onDone(.created)
            case .switched: onDone(mode == .login ? .returning : .alreadyRegistered)
            case .failed(let reason): if !reason.isEmpty { error = reason }
            }
        }
    }
}

/// The calm pages' haze behind a screen laid out natively (email, code).
private struct QuestionHazeBackground: View {
    var body: some View {
        MockupCanvas { QuestionHaze() }
            .allowsHitTesting(false)
    }
}

// MARK: - Code

/// Bevel's "Check your inbox", as the mockup draws it: the envelope, the
/// address, six boxes over one invisible field (one field is what makes the
/// system's autofill land in a single tap), and the dark pill. The sixth digit
/// checks itself; the pill spins, then turns green with a tick when the code
/// is right, or red with a cross when it is not (Abel, 8 Nov 2026).
struct CodeScreen: View {
    let mode: OnboardingStep.Mode
    let email: String
    /// The name typed on the sign-up screen, saved once the code is accepted.
    let name: String
    let wasAnonymous: Bool
    let onDone: (OnboardingStep.Arrival) -> Void

    @Environment(AppSession.self) private var session

    @State private var code = ""
    @State private var state: CodeButtonState = .wait(42)
    @State private var error: String?
    @State private var resendIn = 0
    @State private var countdown: Task<Void, Never>?
    @State private var shake = 0
    @FocusState private var focused: Bool

    /// Remi's cooldown.
    private let resendDelay = 42

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "envelope")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(OB.text2)
                .padding(.top, 64)

            Text("Check your inbox")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.24)
                .padding(.top, 14)

            Text("We sent a 6-digit code to\n**\(email.isEmpty ? "your email" : email)**")
                .font(.system(size: 15))
                .foregroundStyle(OB.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)
                .padding(.horizontal, 36)

            boxes
                .padding(.top, 26)
                .modifier(Shake(amount: CGFloat(shake)))

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(QuestionHazeBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CodeButton(state: state) { resend() }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .sensoryFeedback(.success, trigger: state == .verified)
        .sensoryFeedback(.error, trigger: state == .wrong)
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

    private var checking: Bool { state == .checking || state == .verified }

    private var boxes: some View {
        ZStack {
            // The real field, invisible and underneath: autofill needs one.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($focused)
                .disabled(checking)
                .accessibilityLabel("Six-digit code")

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let digit = index < code.count ? String(Array(code)[index]) : ""
                    let isNext = index == code.count && focused
                    ZStack {
                        if !digit.isEmpty {
                            Text(digit)
                                .font(.system(size: 28, weight: .semibold))
                                .monospacedDigit()
                                .transition(.asymmetric(
                                    insertion: .offset(y: 8).combined(with: .scale(scale: 0.7)).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .frame(width: 46, height: 58)
                    .background(OB.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(boxTint, lineWidth: 1.5)
                            .opacity(isNext || state == .verified || state == .wrong ? 1 : 0)
                    }
                    .animation(.timingCurve(0.2, 0.9, 0.3, 1.4, duration: 0.25), value: digit)
                    .animation(.easeOut(duration: 0.15), value: isNext)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(width: 316, height: 58)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var boxTint: Color {
        switch state {
        case .verified: return Color(.systemGreen)
        case .wrong: return Color(.systemRed)
        default: return OB.accent
        }
    }

    private func verify() {
        guard !checking, code.count == 6 else { return }
        error = nil
        withAnimation(.easeOut(duration: 0.25)) { state = .checking }
        Task {
            let outcome = await session.confirmEmailCode(code, for: email, wasAnonymous: wasAnonymous)
            switch outcome {
            case .linked:
                await succeed()
                if !name.isEmpty { await session.saveName(name, promoting: "") }
                onDone(.created)
            case .switched:
                await succeed()
                onDone(mode == .login ? .returning : .alreadyRegistered)
            case .failed(let reason):
                withAnimation(.easeOut(duration: 0.3)) { state = .wrong }
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
                error = reason.isEmpty ? "That code didn’t work. Check it and try again." : reason
                try? await Task.sleep(for: .milliseconds(1300))
                code = ""
                focused = true
                withAnimation(.easeOut(duration: 0.3)) { state = resendIn > 0 ? .wait(resendIn) : .resend }
            case .codeSent:
                withAnimation(.easeOut(duration: 0.3)) { state = resendIn > 0 ? .wait(resendIn) : .resend }
            }
        }
    }

    /// Green, with a tick, held long enough to be seen.
    private func succeed() async {
        withAnimation(.easeOut(duration: 0.3)) { state = .verified }
        try? await Task.sleep(for: .milliseconds(750))
    }

    private func resend() {
        guard state == .resend else { return }
        error = nil
        withAnimation(.easeOut(duration: 0.25)) { state = .checking }
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
        state = .wait(resendDelay)
        countdown = Task {
            while resendIn > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                resendIn -= 1
                if case .wait = state {
                    withAnimation(.easeOut(duration: 0.2)) { state = resendIn > 0 ? .wait(resendIn) : .resend }
                }
            }
        }
    }
}

/// What the code page's pill is saying.
private enum CodeButtonState: Equatable {
    case wait(Int)
    case resend
    case checking
    case verified
    case wrong
}

/// The code page's pill: asleep while the resend countdown runs, dark with a
/// spinner while it checks, then green with a tick or red with a cross.
private struct CodeButton: View {
    let state: CodeButtonState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .wait(let seconds):
                    Text("Resend code in 0:\(String(format: "%02d", seconds))")
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                case .resend:
                    Text("Resend code")
                case .checking:
                    ProgressView().tint(OB.pillText)
                case .verified:
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                case .wrong:
                    HStack(spacing: 6) {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                        Text("Wrong code")
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(background, in: Capsule())
        }
        .buttonStyle(ObPressStyle())
        .allowsHitTesting(state == .resend)
        .animation(.easeOut(duration: 0.3), value: state)
        .accessibilityLabel(label)
    }

    private var background: Color {
        switch state {
        case .wait: return OB.pillOff
        case .resend, .checking: return OB.pill
        case .verified: return Color(.systemGreen)
        case .wrong: return Color(.systemRed)
        }
    }

    private var foreground: Color {
        switch state {
        case .wait: return OB.pillOffText
        case .resend, .checking: return OB.pillText
        case .verified, .wrong: return .white
        }
    }

    private var label: String {
        switch state {
        case .wait(let seconds): return "Resend code in \(seconds) seconds"
        case .resend: return "Resend code"
        case .checking: return "Checking the code"
        case .verified: return "Code accepted"
        case .wrong: return "Wrong code"
        }
    }
}

/// A short side-to-side shake when the code is wrong.
private struct Shake: GeometryEffect {
    var amount: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 6), y: 0))
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
