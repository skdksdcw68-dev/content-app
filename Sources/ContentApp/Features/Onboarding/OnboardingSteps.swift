import SwiftUI

/// The quiet steps of first run, in Bevel's soft way: one thing on the page,
/// centred, lots of room (Abel, 8 Nov 2026): what is never done with their
/// information, and the ask for pings with a reason. No name is asked before
/// sign-up: App Review rejects it (5.1.1(v)), and Apple hands the name over.

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
