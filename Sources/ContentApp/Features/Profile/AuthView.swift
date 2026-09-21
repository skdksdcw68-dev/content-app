import SwiftUI
import AuthenticationServices

/// Saving the account, or signing back into one.
///
/// Three ways in, in the order people reach for them on an iPhone: Apple,
/// Google, then an emailed six-digit code. A code rather than a link, because
/// a link opens a browser and leaves the app behind.
///
/// Whatever was made before signing up is kept: each path links to the account
/// in use when it can, and only becomes an existing account when that identity
/// already belongs to one.
struct AuthView: View {
    /// What the screen is for, which only changes the words.
    enum Purpose { case save, signIn }

    let purpose: Purpose
    var onDone: (() -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var wasAnonymous = true
    @State private var working = false
    @State private var message: String?
    @State private var appleNonce = ""
    @FocusState private var typing: Bool

    private var title: String { purpose == .save ? "Save your account" : "Welcome back" }
    private var blurb: String {
        purpose == .save
            ? "So your brand, plans and videos come back on any iPhone."
            : "Sign in and everything you made is here again."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        InitialAvatar(initial: session.initial, size: 64)
                            .padding(.bottom, 4)
                        Text(title).font(.title2.weight(.bold))
                        Text(blurb)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    SignInWithAppleButton(.continue) { request in
                        let nonce = AppSession.appleNonce()
                        appleNonce = nonce.raw
                        request.requestedScopes = [.email]
                        request.nonce = nonce.hashed
                    } onCompletion: { result in
                        guard case .success(let authorization) = result else { return }
                        let nonce = appleNonce
                        Task {
                            working = true
                            let outcome = await session.signInWithApple(authorization, nonce: nonce)
                            working = false
                            switch outcome {
                            case .linked, .switched: finish()
                            case .failed: message = session.lastError ?? "That didn’t work. Try again."
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 50)

                    Button {
                        Task {
                            working = true
                            let outcome = await session.signInWithGoogle()
                            working = false
                            handle(outcome)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "g.circle.fill")
                            Text("Continue with Google").fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .tint(.primary)

                    HStack(spacing: 10) {
                        line; Text("or").font(.footnote).foregroundStyle(.secondary); line
                    }
                    .padding(.vertical, 2)

                    emailPart

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(message.hasPrefix("Code sent") ? Color.secondary : Color.red)
                            .multilineTextAlignment(.center)
                    }

                    Text("By continuing you agree to the Terms and Privacy Policy.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)

                    HStack(spacing: 16) {
                        Button("Terms") { openURL(AutocastLinks.terms) }
                        Button("Privacy") { openURL(AutocastLinks.privacy) }
                    }
                    .font(.caption)
                    .tint(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { finish() }
                }
            }
            .overlay {
                if working {
                    ProgressView()
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .onAppear { wasAnonymous = session.isAnonymous }
    }

    private var line: some View {
        Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
    }

    @ViewBuilder
    private var emailPart: some View {
        VStack(spacing: 10) {
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(codeSent)

            if codeSent {
                TextField("Six-digit code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                Task { await emailStep() }
            } label: {
                Text(codeSent ? "Confirm code" : "Email me a code")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .disabled(working || (codeSent ? code.count < 6 : !email.contains("@")))

            if codeSent {
                Button("Use a different email") {
                    codeSent = false
                    code = ""
                    message = nil
                }
                .font(.footnote)
                .tint(.secondary)
            }
        }
    }

    private func emailStep() async {
        working = true
        defer { working = false }
        if codeSent {
            handle(await session.confirmEmailCode(code, for: email, wasAnonymous: wasAnonymous))
        } else {
            wasAnonymous = session.isAnonymous
            handle(await session.sendEmailCode(to: email))
        }
    }

    private func handle(_ outcome: AppSession.SignUpOutcome) {
        switch outcome {
        case .codeSent:
            withAnimation(.snappy) { codeSent = true }
            message = "Code sent to \(email). It expires in 15 minutes."
        case .linked, .switched:
            finish()
        case .failed(let reason):
            // An empty reason is somebody closing the browser sheet.
            message = reason.isEmpty ? nil : reason
        }
    }

    private func finish() {
        session.lastError = nil
        if let onDone { onDone() } else { dismiss() }
    }
}
