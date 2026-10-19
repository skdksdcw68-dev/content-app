import SwiftUI

/// The top of You: who you are, and what you are on.
///
/// Abel, 29 Sep 2026: "on the profile page, just try to make it better." It was
/// an initial, a name and a line of grey, above a settings list -- a page that
/// told you nothing you did not already know.
///
/// Netro, 13 Oct 2026: the credit tiles and the strip of account chips read as
/// boring, and a row of figures is something he has rejected before. Both moved
/// into the list below as ordinary sections -- Credits, and Accounts -- so
/// this is only the person again: name, brand, plan.
///
/// Not a TikTok or YouTube identity: those are accounts you connect, listed
/// under Accounts (Abel, 19 Sep 2026: "do not set the user account with its
/// tiktok or youtube, just ask for a name").
struct ProfileHeader: View {
    @Environment(AppSession.self) private var session

    /// Edit profile is a page of its own (Netro, 19 Oct 2026), not an alert.
    @State private var editing = false
    private var name: String { session.displayName ?? "Add your name" }

    /// The brand line, unless it is still the placeholder name.
    private var subtitle: String? {
        guard let brand = session.brand?.name, brand != "My brand", !brand.isEmpty else {
            return session.accountEmail
        }
        return brand
    }

    var body: some View {
        identity
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .sheet(isPresented: $editing) { EditProfileView() }
    }

    // MARK: - Who

    private var identity: some View {
        VStack(spacing: 0) {
            Button { editing = true } label: {
                ProfileAvatar(size: 88)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 28, height: 28)
                            .background(Theme.accent, in: Circle())
                            .overlay(Circle().stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 3))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile picture")
            .accessibilityHint("Edit your profile")

            Text(name)
                .font(.title2.weight(.bold))
                .foregroundStyle(session.displayName == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .padding(.top, 12)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            planPill
                .padding(.top, 10)

            Button("Edit profile") { editing = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(.top, 12)
        }
    }

    /// The plan as a word to tap: Free opens the upgrade, Pro says when it
    /// renews. Nothing when the plan has not been read yet.
    @ViewBuilder
    private var planPill: some View {
        if let plan = session.subscription {
            if plan.isPro {
                Label(proLine(plan), systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.proGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.proGreenSoft, in: Capsule())
            } else {
                Button { session.showingPaywall = true } label: {
                    Label("Free plan · Get Pro", systemImage: "sparkles")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func proLine(_ plan: MyPlan) -> String {
        guard let date = plan.expires else { return "Autocast \(plan.title)" }
        let when = date.formatted(date: .abbreviated, time: .omitted)
        if plan.isTrial { return "Trial ends \(when)" }
        return plan.autoRenew == false ? "\(plan.title) · ends \(when)" : "\(plan.title) · renews \(when)"
    }
}
