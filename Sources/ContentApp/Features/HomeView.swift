import SwiftUI

/// What needs you, what is on its way, and what went out.
///
/// Every number here is read from the database. There is no sample data
/// anywhere in this app, which is the whole reason the previous one was thrown
/// away: a screen full of convincing fixtures taught nobody whether any of it
/// actually worked.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    @State private var approving: PendingPost?

    private var needsYou: [PendingPost] { session.posts.filter(\.needsYou) }
    private var inFlight: [PendingPost] { session.posts.filter(\.isBusy) }
    private var published: [PendingPost] { session.posts.filter { $0.state == .published } }
    private var failed: [PendingPost] { session.posts.filter { $0.state == .failed } }

    /// The next few still ahead of us. Anything whose slot has passed is not
    /// upcoming, whatever the plan says.
    private var upcoming: [PlannedPost] {
        session.planPosts
            .filter { ($0.scheduledFor ?? .distantPast) > .now }
            .prefix(3)
            .map { $0 }
    }

    private var brandTimeZone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let connection = session.connections.first {
                    AccountCard(connection: connection)
                } else {
                    ConnectFirstCard()
                }

                // Failures lead, because they are the only state that will not
                // resolve itself without somebody looking at it.
                if !failed.isEmpty {
                    FailedCard(posts: failed) { approving = $0 }
                }

                // The plan sits above the queue on purpose. What is going out
                // over the next month is the reason to open this app; what
                // happened to one upload is the reason to scroll.
                if let plan = session.plan {
                    NavigationLink {
                        PlanView()
                    } label: {
                        PlanCard(
                            plan: plan,
                            upcoming: upcoming,
                            timezone: brandTimeZone
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !needsYou.isEmpty {
                    NeedsYouCard(posts: needsYou) { approving = $0 }
                } else if !session.connections.isEmpty {
                    NothingWaitingCard(hasPosts: !session.posts.isEmpty)
                }

                if !inFlight.isEmpty {
                    InFlightCard(posts: inFlight)
                }

                if !published.isEmpty {
                    PublishedCard(posts: published)
                }

                if !session.connections.isEmpty {
                    NavigationLink {
                        InsightsView()
                    } label: {
                        InsightsLinkCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Home")
        .refreshable {
            await session.refreshConnections()
            await session.refreshPosts()
            await session.refreshPlan()
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
    }
}

// MARK: - Account

private struct AccountCard: View {
    let connection: PlatformConnection

    var body: some View {
        Card {
            HStack(spacing: 12) {
                AsyncImage(url: connection.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 46, height: 46)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.label)
                        .font(.headline)
                    Text(connection.problem ?? "Connected and ready")
                        .font(.caption)
                        .foregroundStyle(connection.isHealthy ? Color.secondary : Color.red)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: connection.isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(connection.isHealthy ? Color.green : Color.orange)
            }
        }
    }
}

private struct ConnectFirstCard: View {
    var body: some View {
        Card("Start here", systemImage: "link") {
            Text("Connect a TikTok account and Autocast can start holding posts for it. Nothing is published without your say-so.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("You → Connect TikTok")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Waiting on a person

private struct NeedsYouCard: View {
    let posts: [PendingPost]
    let open: (PendingPost) -> Void

    var body: some View {
        Card("Waiting for you", systemImage: "hand.raised.fill") {
            Text(posts.count == 1
                 ? "One post is ready and needs your approval."
                 : "\(posts.count) posts are ready and need your approval.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(posts.prefix(4)) { post in
                    Button { open(post) } label: {
                        HStack(spacing: 10) {
                            Text(post.caption.isEmpty ? post.post.hook : post.caption)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 8)

                            Text(post.state == .needsReapproval ? "Changed" : "Review")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.softAccent, in: Capsule())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct NothingWaitingCard: View {
    let hasPosts: Bool

    var body: some View {
        Card("Nothing needs you", systemImage: "checkmark.circle") {
            Text(hasPosts
                 ? "Everything here has been dealt with."
                 : "Add a video in Library and it will show up here for approval.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - In flight and done

private struct InFlightCard: View {
    let posts: [PendingPost]

    var body: some View {
        Card("On its way", systemImage: "paperplane") {
            ForEach(posts) { post in
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(post.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct PublishedCard: View {
    let posts: [PendingPost]

    var body: some View {
        Card("Posted", systemImage: "checkmark.circle.fill") {
            ForEach(posts.prefix(5)) { post in
                VStack(alignment: .leading, spacing: 3) {
                    Text(post.caption.isEmpty ? post.post.hook : post.caption)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(CreatorInfo.label(for: post.privacy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct FailedCard: View {
    let posts: [PendingPost]
    let open: (PendingPost) -> Void

    var body: some View {
        Card("Did not go out", systemImage: "exclamationmark.triangle.fill") {
            ForEach(posts.prefix(3)) { post in
                Button { open(post) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(post.caption.isEmpty ? post.post.hook : post.caption)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Text(post.failureReason ?? "It failed.")
                            .font(.caption)
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Insights lives behind a tap rather than a tab. It is the screen you look at
/// weekly, not the one you open the app for.
private struct InsightsLinkCard: View {
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.softAccent, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Insights")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text("Followers and views, straight from TikTok")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
    }
}

// MARK: - The plan

/// What is coming, and whether it is waiting on you.
///
/// Two states in one card because they are the same object at different moments:
/// a proposal you have not read, and a schedule that is running. The difference
/// that matters to a person is whether they still have to do something.
private struct PlanCard: View {
    let plan: ContentPlan
    let upcoming: [PlannedPost]
    let timezone: TimeZone

    var body: some View {
        Card(
            plan.isProposal ? "A plan is waiting for you" : "Your plan",
            systemImage: plan.isProposal ? "calendar.badge.exclamationmark" : "calendar"
        ) {
            Text(plan.isProposal
                 ? "A month of posts is written and needs a look. Nothing is scheduled yet."
                 : "Running. Here is what is next.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if upcoming.isEmpty {
                Text(plan.isProposal ? "Open it to read the month." : "Nothing left ahead in this plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(upcoming) { post in
                        HStack(alignment: .top, spacing: 10) {
                            Text(when(post))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                                .frame(width: 78, alignment: .leading)

                            Text(post.hook)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            HStack(spacing: 4) {
                Text(plan.isProposal ? "Read it" : "See the month")
                Image(systemName: "chevron.right")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.accent)
        }
    }

    /// "Today 09:00" for the ones a person can still act on, the weekday after
    /// that. A bare time on a card is ambiguous once it is not today.
    private func when(_ post: PlannedPost) -> String {
        guard let date = post.scheduledFor else { return "--:--" }

        var calendar = Calendar.current
        calendar.timeZone = timezone

        let time = DateFormatter()
        time.timeZone = timezone
        time.dateFormat = "HH:mm"

        if calendar.isDateInToday(date) { return "Today \(time.string(from: date))" }
        if calendar.isDateInTomorrow(date) { return "Tmrw \(time.string(from: date))" }

        let day = DateFormatter()
        day.timeZone = timezone
        day.dateFormat = "EEE"
        return "\(day.string(from: date)) \(time.string(from: date))"
    }
}
