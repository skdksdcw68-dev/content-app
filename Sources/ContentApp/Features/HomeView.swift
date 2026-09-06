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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Home")
        .refreshable {
            await session.refreshConnections()
            await session.refreshPosts()
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
