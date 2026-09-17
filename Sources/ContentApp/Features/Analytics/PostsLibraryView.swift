import SwiftUI

/// Your posts, the way TikTok shows a profile: the account up top, then a
/// three-across grid of 3:4 covers with the view count in the corner.
///
/// Abel, 17 Sep 2026: a library where the posts can be checked "exactly like
/// TikTok", three in a row, reached from the top left of Analytics, and
/// hiding the tab bar while it is open.
///
/// Three tabs: what went out (every video on the account, Autocast's marked),
/// what is scheduled, and what is waiting for approval.
struct PostsLibraryView: View {
    @Environment(AppSession.self) private var session

    enum Page: String, CaseIterable, Hashable {
        case videos, scheduled, waiting

        var title: String {
            switch self {
            case .videos:    "Videos"
            case .scheduled: "Scheduled"
            case .waiting:   "Needs you"
            }
        }
    }

    @State private var page: Page = .videos
    @State private var library: PostsLibrary?
    @State private var failed = false
    @State private var approving: PendingPost?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var connection: PlatformConnection? { session.connections.first }

    private var scheduled: [PlannedPost] {
        session.planPosts
            .filter { ($0.scheduledFor ?? .distantPast) > .now }
            .sorted { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    private var waiting: [PendingPost] { session.posts.filter(\.needsYou) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                    .padding(.bottom, 14)

                Section {
                    Group {
                        switch page {
                        case .videos:    videos
                        case .scheduled: scheduledGrid
                        case .waiting:   waitingGrid
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 32)
                } header: {
                    UnderlineTabs(items: Page.allCases, selection: $page) { tabTitle($0) }
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle(connection.map { "@\($0.username)" } ?? "Your posts")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .task { await load() }
        .refreshable {
            _ = await session.metrics()
            await session.refreshPosts()
            await session.refreshPlan()
            await load()
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
    }

    private func tabTitle(_ tab: Page) -> String {
        let count: Int
        switch tab {
        case .videos:    return tab.title
        case .scheduled: count = scheduled.count
        case .waiting:   count = waiting.count
        }
        return count == 0 ? tab.title : "\(tab.title) \(count)"
    }

    private func load() async {
        do {
            library = try await session.postsLibrary()
            failed = false
        } catch {
            if library == nil { failed = true }
        }
    }

    // MARK: - Profile

    private var header: some View {
        VStack(spacing: 10) {
            AsyncImage(url: connection?.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .frame(width: 92, height: 92)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5))
            .padding(.top, 12)

            Text(connection.map { "@\($0.username)" } ?? "Not connected")
                .font(.headline)

            HStack(spacing: 0) {
                count(library?.account.videoCount ?? library?.videos.count, "Videos")
                divider
                count(library?.account.followers, "Followers")
                divider
                count(library?.account.likes, "Likes")
            }
            .padding(.top, 4)

            if let brand = session.brand {
                Text(brand.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func count(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map { AnalyticsFormat.number(Double($0)) } ?? "—")
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(width: 96)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 0.5, height: 14)
    }

    // MARK: - Grids

    @ViewBuilder
    private var videos: some View {
        if let library {
            if library.videos.isEmpty {
                empty("No public videos yet", "Videos appear here once they're public on TikTok. Autocast checks every 6 hours.")
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.videos) { video in
                        NavigationLink {
                            AnalyticsPostView(videoId: video.videoId, title: video.title ?? "Video")
                        } label: {
                            VideoCell(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if failed {
            RetryNotice(title: "Couldn't load your videos") { Task { await load() } }
                .screenGutter()
                .padding(.top, 12)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<9, id: \.self) { _ in
                    Color.track
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .breathing()
                }
            }
        }
    }

    @ViewBuilder
    private var scheduledGrid: some View {
        if scheduled.isEmpty {
            empty("Nothing scheduled", "Plan a week and the posts waiting to go out show up here.")
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(scheduled) { post in
                    NavigationLink { PlanView() } label: {
                        TextCell(
                            date: post.scheduledFor,
                            text: post.hook.isEmpty ? post.concept : post.hook,
                            badge: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var waitingGrid: some View {
        if waiting.isEmpty {
            empty("Nothing waiting", "Posts that need your approval before they go out show up here.")
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(waiting) { post in
                    Button { approving = post } label: {
                        TextCell(
                            date: post.post.createdAt,
                            text: post.caption.isEmpty ? post.post.hook : post.caption,
                            badge: post.state == .needsReapproval ? "Changed" : "Review"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            EmptyArt(name: "empty-posts", size: 110)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Cells

/// One cover, TikTok's way: cropped to 3:4, the view count bottom left over a
/// soft shade, and a small mark on what Autocast posted.
private struct VideoCell: View {
    let video: PostsLibrary.Video

    var body: some View {
        Color.track
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let cover = video.coverUrl, let url = URL(string: cover) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "play.fill")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    Image(systemName: "play")
                        .font(.caption2.weight(.bold))
                    Text(AnalyticsFormat.number(Double(video.views)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .padding(6)
            }
            .overlay(alignment: .topLeading) {
                if video.fromAutocast {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(5)
                        .accessibilityLabel("Posted with Autocast")
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(video.title ?? "Video"), \(video.views) views")
    }
}

/// A post with no picture yet: its day, and its first line.
private struct TextCell: View {
    let date: Date?
    let text: String
    let badge: String?

    var body: some View {
        Color.track
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if let date {
                        Text(date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption.weight(.bold))
                        Text(date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(text.isEmpty ? "Untitled" : text)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                }
                .padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .padding(6)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
