import SwiftUI

/// The top of You: who you are, what you are on, how far this month has got,
/// and where you post.
///
/// Abel, 29 Sep 2026: "on the profile page, just try to make it better." It was
/// an initial, a name and a line of grey, above a settings list -- a page that
/// told you nothing you did not already know. Now the first screen of it is
/// the state of the whole account:
///
///  - your name and brand, as before;
///  - your plan, as a word you can tap (Free opens the upgrade, Pro says when
///    it renews);
///  - three numbers that are read, not made up -- accounts connected, things
///    made this month, videos left -- from the same counters that refuse a
///    request when they run out;
///  - the accounts themselves, each in its own mark, with a dot when one needs
///    signing in again.
///
/// Not a TikTok or YouTube identity: those are accounts you connect, listed
/// here and under Accounts (Abel, 19 Sep 2026: "do not set the user account
/// with its tiktok or youtube, just ask for a name").
struct ProfileHeader: View {
    @Environment(AppSession.self) private var session

    /// Takes them to the Accounts group further down the same screen.
    var showAccounts: () -> Void = {}

    @State private var editing = false
    @State private var draft = ""
    @State private var connecting = false
    /// This month's counters. Empty until read, and drawn as dashes rather
    /// than as zeroes: a zero is a claim.
    @State private var standing: [QuotaStanding] = []

    private var name: String { session.displayName ?? "Add your name" }

    /// The brand line, unless it is still the placeholder name.
    private var subtitle: String? {
        guard let brand = session.brand?.name, brand != "My brand", !brand.isEmpty else {
            return session.accountEmail
        }
        return brand
    }

    private var videos: QuotaStanding? { standing.first { $0.kind == "video_gen" } }
    private var images: QuotaStanding? { standing.first { $0.kind == "image_gen" } }

    private var connectedCount: Int { session.connections.filter(\.isHealthy).count }

    /// Everything made so far this month: videos and pictures together.
    private var madeThisMonth: String {
        guard videos != nil || images != nil else { return "–" }
        return "\((videos?.used ?? 0) + (images?.used ?? 0))"
    }

    private var videosLeft: String {
        guard let videos else { return "–" }
        return "\(videos.left)"
    }

    var body: some View {
        VStack(spacing: 20) {
            identity
            stats
            accounts
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .task { standing = await session.quotaStanding() }
        .alert("Your name", isPresented: $editing) {
            TextField("Name", text: $draft)
                .textContentType(.name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = draft
                Task { await session.saveName(name, promoting: "") }
            }
        }
        .sheet(isPresented: $connecting) { ConnectAccountsSheet() }
    }

    // MARK: - Who

    private var identity: some View {
        VStack(spacing: 0) {
            InitialAvatar(initial: session.initial, size: 88)

            Button {
                draft = session.displayName ?? ""
                editing = true
            } label: {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(session.displayName == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityHint("Change your name")

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            planPill
                .padding(.top, 10)
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
        return plan.autoRenew == false ? "Pro · ends \(when)" : "Pro · renews \(when)"
    }

    // MARK: - How far

    private var stats: some View {
        HStack(spacing: 10) {
            StatTile(value: "\(connectedCount)", label: connectedCount == 1 ? "Account" : "Accounts")
            StatTile(value: madeThisMonth, label: "Made this month")
            StatTile(value: videosLeft, label: "Videos left")
        }
    }

    // MARK: - Where

    /// Every connected account in its own mark, then a way to add another.
    private var accounts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.connections) { connection in
                    Button(action: showAccounts) {
                        AccountChip(connection: connection)
                    }
                    .buttonStyle(.plain)
                }

                Button { connecting = true } label: {
                    Label("Add account", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.accent.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        // Left alone when there is room for all of them, scrolling when there
        // is not; the chips may run to the screen's edge as they go.
        .scrollClipDisabled()
    }
}

/// One number and what it counts, on a quiet card.
private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: Style.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A connected account: its mark, its handle, and an amber dot when it needs
/// signing in again.
private struct AccountChip: View {
    let connection: PlatformConnection

    var body: some View {
        HStack(spacing: 8) {
            connection.platform.logo.view
                .frame(width: 22, height: 22)
            Text(connection.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !connection.isHealthy {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Needs signing in again")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(Color.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
    }
}
