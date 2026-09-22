import SwiftUI

/// Home: the four things the app does, each in its own colour, then what is
/// next and what has been made.
///
/// Rebuilt on 22 Sep 2026 after Abel: "I really hate the homepage. There is
/// repetitively used pictures... I want the homepage to be so much clean," and
/// "the main things... use different kinds of colours so the users literally
/// love them and use them." So: no pictures at all. The main things are four
/// tiles, each a system colour, each one tap from the thing itself. The
/// generator gets its own row because it is the thing most people have not
/// done and the thing that makes the rest work.
///
/// It promotes and never warns (his call, 15 Sep 2026). What is wrong reaches
/// him as a badge on the You tab.
///
/// Every number here is read from the database. There is no sample data.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    /// What was made today, read once when the page appears.
    @State private var today: AppSession.DayTally?
    /// Every video made for this brand, newest first. Nil until loaded.
    @State private var loadedVideos: [BoardPost]?
    /// A video long-pressed for deletion, waiting for the confirm.
    @State private var deleting: BoardPost?
    /// The once-ever reminder to connect somewhere.
    @State private var nudging = false
    /// Planning a month, started from Home and finished on the plan screen.
    @State private var planning = false
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false

    private var videos: [BoardPost] { loadedVideos ?? [] }
    private var needsYou: [PendingPost] { session.posts.filter(\.needsYou) }
    private var inFlight: [PendingPost] { session.posts.filter(\.isBusy) }

    /// The next thing due that has not gone out yet.
    private var nextUp: PlannedPost? {
        session.planPosts
            .filter { ($0.scheduledFor ?? .distantPast) > .now }
            .min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    private var scheduledThisWeek: Int {
        var calendar = Calendar.current
        calendar.timeZone = brandTimeZone
        guard let week = calendar.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return session.planPosts.filter { post in
            guard let at = post.scheduledFor else { return false }
            return week.contains(at) && at > .now
        }.count
    }

    private var brandTimeZone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    /// The generator that can make videos, if there is one.
    private var generator: ProviderConnection? {
        session.connectedProviders.first { $0.isHealthy && $0.capabilities.contains("video_generation") }
            ?? session.connectedProviders.first(where: \.isHealthy)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                greeting
                    .padding(.top, 4)
                    .entrance(0)

                LazyVGrid(columns: columns, spacing: 12) {
                    tiles
                }
                .padding(.top, 16)
                .entrance(1)

                GeneratorRow(
                    connected: generator,
                    key: session.generators.first(where: \.isWorking),
                    offer: session.connectable.first(where: \.isFeatured) ?? session.connectable.first
                )
                .padding(.top, 12)
                .entrance(2)

                if let next = nextUp {
                    SectionHeader(title: "Up next")
                        .padding(.top, 28)
                    NavigationLink { PlanView() } label: {
                        UpNextCard(post: next, timezone: brandTimeZone)
                    }
                    .buttonStyle(SoftPressStyle())
                    .padding(.top, 12)
                    .entrance(3)
                }

                SectionHeader(title: "Your videos") {
                    if !videos.isEmpty {
                        Text("\(videos.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 28)

                Group {
                    if let videos = loadedVideos, !videos.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(videos) { video in
                                NavigationLink { PostDetailView(postID: video.id) } label: {
                                    VideoTile(post: video, timezone: brandTimeZone)
                                }
                                .buttonStyle(SoftPressStyle())
                                .contextMenu {
                                    if video.stage != .publishing && video.stage != .verifying {
                                        Button(role: .destructive) { deleting = video } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    } else if loadedVideos == nil {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.track)
                                    .aspectRatio(9 / 16, contentMode: .fit)
                            }
                        }
                        .breathing()
                    } else {
                        NavigationLink { StudioFlowView() } label: {
                            NoVideosCard()
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
                .padding(.top, 12)
                .entrance(4)
            }
            .screenGutter()
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle(timeOfDay)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if session.subscription?.isPro != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Upgrade") { session.showingPaywall = true }
                        .font(.subheadline.weight(.semibold))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ProfileView() } label: {
                    InitialAvatar(initial: session.initial, size: 30)
                }
                .accessibilityLabel("Your profile")
            }
        }
        .task {
            today = await session.todayTally()
            await session.refreshConnectedProviders()
            await session.refreshConnectable()
            // A moment after the app is on screen, not over the top of it.
            try? await Task.sleep(for: .seconds(1.2))
            if SetupNudge.due(session) {
                SetupNudge.markShown()
                nudging = true
            }
        }
        .sheet(isPresented: $nudging) { SetupNudge() }
        .task(id: session.brand?.id) { loadedVideos = try? await session.videos() }
        .refreshable {
            loadedVideos = try? await session.videos()
            await session.refreshConnections()
            await session.refreshPosts()
            await session.refreshPlan()
            await session.refreshHealth()
            await session.refreshConnectedProviders()
            await session.refreshConnectable()
            today = await session.todayTally()
        }
        .sheet(isPresented: $planning, onDismiss: {
            if proposed != nil { showingPlan = true }
        }) {
            NewPlanSheet(brief: "") { proposed = $0 }
        }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed)
        }
        .alert("Delete this video?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let video = deleting else { return }
                deleting = nil
                Task {
                    if await session.deletePost(video.id) {
                        loadedVideos?.removeAll { $0.id == video.id }
                    }
                }
            }
        } message: {
            Text("It’s removed from Autocast. Anything already on TikTok stays there.")
        }
    }

    // MARK: - The four things

    /// Each tile is the thing itself, in its own colour. The words change with
    /// the account -- a month that exists is "Your month", not an offer to
    /// plan one -- and the colour never does, so the screen is learnable.
    @ViewBuilder
    private var tiles: some View {
        if session.plan != nil {
            NavigationLink { PlanView() } label: {
                HomeTile(color: .indigo, symbol: "calendar", title: "Your month", detail: monthDetail)
            }
            .buttonStyle(SoftPressStyle())
        } else {
            Button { planning = true } label: {
                HomeTile(color: .indigo, symbol: "calendar", title: "Plan a month",
                         detail: "A month of posts from one sentence")
            }
            .buttonStyle(SoftPressStyle())
        }

        NavigationLink { ChatView() } label: {
            HomeTile(color: .orange, symbol: "sparkles", title: "Make a video",
                     detail: "Describe it and Autocast makes it")
        }
        .buttonStyle(SoftPressStyle())

        if session.connections.isEmpty {
            NavigationLink { ProfileView() } label: {
                HomeTile(color: .teal, symbol: "link", title: "Connect an account",
                         detail: "TikTok, YouTube or Instagram")
            }
            .buttonStyle(SoftPressStyle())
        } else {
            NavigationLink { StudioFlowView() } label: {
                HomeTile(color: .teal, symbol: "arrow.up.circle.fill", title: "Post a video",
                         detail: "Upload one and it goes out for you")
            }
            .buttonStyle(SoftPressStyle())
        }

        NavigationLink { AutopilotView() } label: {
            HomeTile(color: .pink, symbol: "paperplane.fill", title: "Autopilot",
                     detail: session.autopilotState?.title ?? "Posts on time, even with the app closed")
        }
        .buttonStyle(SoftPressStyle())
    }

    private var monthDetail: String {
        if scheduledThisWeek > 0 {
            return scheduledThisWeek == 1 ? "1 post goes out this week" : "\(scheduledThisWeek) posts go out this week"
        }
        let count = session.planPosts.count
        return count == 1 ? "1 post planned" : "\(count) posts planned"
    }
}

// MARK: - The greeting

private extension HomeView {
    var greeting: some View {
        // The hello is the navigation bar's large title now; this is the one
        // sentence underneath it.
        Text(standing)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var timeOfDay: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12:  "Good morning"
        case 12..<18: "Good afternoon"
        default:      "Good evening"
        }
    }

    /// One sentence, and never a failure's title.
    ///
    /// It also never claims what is not true. When something is blocked,
    /// "3 posts go out this week" would be the exact reassurance that stopped
    /// anyone looking in September -- so that line is withheld, and the
    /// sentence points calmly at where the problem now lives.
    var standing: String {
        if !needsYou.isEmpty {
            return needsYou.count == 1
                ? "One post is ready for you to approve."
                : "\(needsYou.count) posts are ready for you to approve."
        }
        if !inFlight.isEmpty {
            return "Your next posts are on their way."
        }
        if session.connections.isEmpty {
            return "Connect an account and Autocast posts for you."
        }
        if session.health.contains(where: \.isBlocked) {
            return "One thing needs you in You."
        }
        if scheduledThisWeek > 0 {
            return scheduledThisWeek == 1
                ? "1 post goes out this week."
                : "\(scheduledThisWeek) posts go out this week."
        }
        if let tally = today, !tally.isEmpty {
            var parts: [String] = []
            if tally.made > 0 { parts.append(tally.made == 1 ? "1 made" : "\(tally.made) made") }
            if tally.written > 0 { parts.append(tally.written == 1 ? "1 written up" : "\(tally.written) written up") }
            return "Today: \(parts.joined(separator: ", "))."
        }
        return "Tell Autocast what to post next."
    }
}

// MARK: - Sections

private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

private extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

// MARK: - Tiles

/// One of the four things, in its colour. A system colour, so it is a
/// different shade in the dark and still the same colour; the words are
/// white on all of them.
private struct HomeTile: View {
    let color: Color
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.22), in: Circle())

            Spacer(minLength: 18)

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous)
                .fill(color.gradient)
        }
        .contentShape(RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

/// The generator: the one thing on Home that is asked for by name of what
/// it is, because nothing else on the screen works without it.
private struct GeneratorRow: View {
    let connected: ProviderConnection?
    let key: Generator?
    let offer: ConnectableProvider?

    private var title: String {
        if let connected { return connected.providerName }
        if let key { return key.name }
        return "Connect a video generator"
    }

    private var detail: String {
        if let connected { return connected.summary }
        if let key { return key.statusLine }
        if let offer { return "Sign in to \(offer.name) and Autocast makes the videos itself" }
        return "So Autocast can make the videos itself"
    }

    var body: some View {
        NavigationLink { GeneratorsView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.green.gradient, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .raisedCard(radius: Style.rowCard)
            .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
    }
}

// MARK: - Cards

/// The next post in the plan. Remi's `MealCard` shape: the day down the left
/// edge, the hook, the time on a chip.
private struct UpNextCard: View {
    let post: PlannedPost
    let timezone: TimeZone

    var body: some View {
        HStack(spacing: 0) {
            DayTile(date: post.scheduledFor, timezone: timezone)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(post.pillar?.name ?? "Next post")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let at = post.scheduledFor {
                        TimeChip(text: at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timezone)))
                    }
                }

                Text(post.hook.isEmpty ? "A post from your plan" : post.hook)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        .raisedCard(radius: Style.rowCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }
}

/// Nothing made yet. One quiet card, no picture.
private struct NoVideosCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Videos you make show up here")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Drafts, scheduled and posted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .raisedCard(radius: Style.bigCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous))
    }
}

/// One made video on Home: its frame, where it is, and its words.
private struct VideoTile: View {
    let post: BoardPost
    let timezone: TimeZone

    var body: some View {
        GeometryReader { proxy in
            PostThumb(media: post.media, stage: post.stage, width: proxy.size.width)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            // Only what the picture cannot say: where this one has got to.
            // Anything still on its way is worth a word; a published video is
            // just a video.
            if post.stage != .published {
                StageChip(stage: post.stage, compact: true)
                    .background(.regularMaterial, in: Capsule())
                    .padding(6)
            }
        }
        .accessibilityLabel("\(post.stage.title): \(post.hook)")
    }
}
