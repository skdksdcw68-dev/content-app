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

    /// Grok's profile card (Abel, 1 Nov 2026: "Grok still wins"): the
    /// picture, the name, and one quiet line -- the plan and the brand -- with
    /// a chevron, on a card of its own at the top of the list. The whole card
    /// opens Edit profile. The plan itself is the first row under it.
    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 14) {
                ProfileAvatar(size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(session.displayName == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    if let line {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit profile, \(name)")
        .accessibilityHint("Change your picture, name and account details")
        .sheet(isPresented: $editing) { EditProfileView() }
    }

    /// "Postpilot Pro · Drobe": the plan, when it has been read, and the brand
    /// or the email.
    private var line: String? {
        var parts: [String] = []
        if let plan = session.subscription {
            parts.append(plan.isPro ? "Postpilot \(plan.title)" : "Free plan")
        }
        if let subtitle { parts.append(subtitle) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
