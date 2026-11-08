import SwiftUI

/// The quiet steps of first run, in Bevel's soft way: one thing on the page,
/// centred, lots of room (Abel, 8 Nov 2026): their first name, what is never
/// done with their information, and the ask for pings with a reason.

extension View {
    /// A faint purple haze top right and grey bottom left, behind a page.
    func softGlassBackground() -> some View {
        background {
            ZStack {
                RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: UnitPoint(x: 0.9, y: 0.12), startRadius: 0, endRadius: 340)
                RadialGradient(colors: [Color.secondary.opacity(0.18), .clear], center: UnitPoint(x: 0.05, y: 0.92), startRadius: 0, endRadius: 340)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - First name

/// "What's your first name?", then a beat of "Nice to meet you". Skippable:
/// a name is never required before the app has been used.
struct OnboardingNameView: View {
    @Environment(AppSession.self) private var session
    @FocusState private var focused: Bool
    @State private var name = ""
    @State private var greeting = false

    private var clean: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if greeting {
                VStack(spacing: 12) {
                    Image(systemName: "hand.wave.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.bounce, value: greeting)
                    Text("Nice to meet you, \(clean)!")
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text("Postpilot makes and posts videos for you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                VStack(spacing: 18) {
                    Text("What’s your first name?")
                        .font(.system(size: 20, weight: .semibold))
                    TextField("e.g. Sam", text: $name)
                        .font(.system(size: 30, weight: .medium))
                        .multilineTextAlignment(.center)
                        .textContentType(.givenName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.continue)
                        .focused($focused)
                        .onSubmit(next)
                }
                .padding(.horizontal, 24)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            if !greeting {
                Button("Skip") { session.onboardingNext(from: .name) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                OnboardingButton(title: "Continue", action: next)
                    .disabled(clean.isEmpty)
            }
        }
        .softGlassBackground()
        .animation(.snappy(duration: 0.3), value: greeting)
        .onAppear { focused = true }
    }

    private func next() {
        guard !clean.isEmpty, !greeting else { return }
        session.pendingName = clean
        focused = false
        greeting = true
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            session.onboardingNext(from: .name)
        }
    }
}

// MARK: - Privacy

/// Said calmly, before anyone is asked to sign up.
struct OnboardingPrivacyView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 124, height: 124)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.18), radius: 24, y: 12)

            Text("Privacy by design")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 28)

            Text("We never sell or share your information with anyone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 36)

            Spacer(minLength: 0)

            AuthTerms().padding(.bottom, 12)

            OnboardingButton(title: "Continue") { session.onboardingNext(from: .privacy) }
        }
        .softGlassBackground()
    }
}

// MARK: - Pings

/// Asks for notifications with the reason, and only brings up the system's
/// question if the person says yes here first.
struct OnboardingPingsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 54, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.red, Theme.accent)
                .frame(width: 124, height: 124)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.18), radius: 24, y: 12)

            Text("Get a ping when your video is ready")
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)
                .padding(.horizontal, 28)

            Text("Videos take a few minutes to make. We tell you the moment yours is done. Nothing else.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 36)

            Spacer(minLength: 0)

            OnboardingButton(title: "Turn on pings") {
                Task {
                    await session.askForPushOnce()
                    session.onboardingNext(from: .pings)
                }
            }

            Button("Not now") { session.onboardingNext(from: .pings) }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .softGlassBackground()
    }
}
