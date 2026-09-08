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
    @State private var upgrading = false

    private var needsYou: [PendingPost] { session.posts.filter(\.needsYou) }
    private var inFlight: [PendingPost] { session.posts.filter(\.isBusy) }
    private var failed: [PendingPost] { session.posts.filter { $0.state == .failed } }

    /// The next thing due that has not gone out yet.
    private var nextUp: PlannedPost? {
        session.planPosts
            .filter { ($0.scheduledFor ?? .distantPast) > .now }
            .min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    /// Views on the most recent thing that went out, when the platform has
    /// reported any. Nil for a long while yet: TikTok gives numbers for public
    /// videos only, so nothing posted before the audit clears will have one.
    private var lastViews: Int? {
        session.posts
            .filter { $0.state == .published }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .first?
            .metrics?.views
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

    /// Days in the plan with nothing to publish yet.
    private var needsVideo: Int {
        let queued = Set(session.posts.map(\.postId))
        return session.planPosts.filter { post in
            post.status != .posted && !queued.contains(post.id)
        }.count
    }

    private var brandTimeZone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    /// Everything already dealt with, newest first. What is waiting or in
    /// flight has its own card above; this is the body of work.
    private var recent: [PendingPost] {
        session.posts
            .filter { $0.state == .published || $0.state == .cancelled }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            // 🔴 Spacing was a flat 16 between nine cards, and that is why the
            // screen read as badly as it did. Nine boxes at one weight, evenly
            // spaced, gives the eye nothing to land on: everything competes and
            // nothing wins, and the page reads as a pile rather than a screen.
            //
            // Distance is the cheapest hierarchy there is. Things that belong
            // together sit 10 apart, groups sit 26 apart, and the reader gets
            // the grouping for free without a single line or box being drawn.
            VStack(spacing: 0) {
                greeting
                    .padding(.bottom, 18)

                // The one big action, first, before any status. What somebody
                // opens this app to do is start something; what happened to
                // last Tuesday's upload is what they scroll for.
                NavigationLink {
                    CreateView()
                } label: {
                    CreateNewButton()
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)

                QuickActions(
                    hasPlan: session.plan != nil,
                    hasAccount: !session.connections.isEmpty
                )
                .padding(.bottom, 26)

                // The app showing itself around. Every slide goes to the thing
                // it describes, and what it leads with depends on what is not
                // set up yet.
                PromoCarousel(
                    hasAccount: !session.connections.isEmpty,
                    hasGenerator: session.hasWorkingGenerator,
                    hasPlan: session.plan != nil
                )
                .padding(.bottom, 26)

                if let connection = session.connections.first {
                    AccountCard(connection: connection)
                        .padding(.bottom, 26)
                } else {
                    ConnectFirstCard()
                        .padding(.bottom, 26)
                }

                // Failures lead among the status cards, because they are the
                // only state that will not resolve itself without somebody
                // looking at it.
                if !failed.isEmpty {
                    FailedCard(posts: failed) { approving = $0 }
                        .padding(.bottom, 10)
                }

                // The three cards from the design. They cover what PlanCard and
                // the Insights link used to say separately -- what went out and
                // how it did, what is scheduled, what still needs doing -- and
                // each appears only when it has something true to report.
                Highlights(
                    lastViews: lastViews,
                    scheduledThisWeek: scheduledThisWeek,
                    nextUp: nextUp,
                    needsVideo: needsVideo,
                    needsApproval: needsYou.count,
                    timezone: brandTimeZone
                )
                .padding(.bottom, 10)

                if !needsYou.isEmpty {
                    NeedsYouCard(posts: needsYou) { approving = $0 }
                        .padding(.bottom, 10)
                }

                if !inFlight.isEmpty {
                    InFlightCard(posts: inFlight)
                        .padding(.bottom, 10)
                }

                // Everything else as tiles rather than another list. A month of
                // posts read as rows is a spreadsheet; read as cards it is work
                // you recognise at a glance, which is what it actually is.
                if !recent.isEmpty {
                    RecentGrid(posts: recent) { approving = $0 }
                        .padding(.top, 16)
                } else if !session.connections.isEmpty {
                    NothingYetCard()
                        .padding(.top, 16)
                }

            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.canvas)
        // No title. "Good evening" is the title now, and a large "Home" above
        // it was the same job done twice, in two type sizes, six points apart.
        // The bar keeps its avatar and gets out of the way.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AccountPill(
                    connection: session.connections.first,
                    upgrade: { upgrading = true }
                )
            }
        }
        .refreshable {
            await session.refreshConnections()
            await session.refreshPosts()
            await session.refreshPlan()
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
        .sheet(isPresented: $upgrading) { UpgradeSheet() }
    }
}

// MARK: - The top of the page

private extension HomeView {
    /// A line that says where things stand before anything is asked of you.
    ///
    /// The page began on a full-width purple button. Opening an app and being
    /// handed a call to action before a single word of greeting is what makes
    /// a screen feel like a form -- and there was no title anywhere, so the
    /// first thing the eye met was the loudest thing on the page.
    ///
    /// It reports rather than decorates: what is actually waiting, in one
    /// sentence, and nothing when nothing is.
    var greeting: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(timeOfDay)
                .font(.title.bold())
                .foregroundStyle(Color.primary)

            Text(standing)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var timeOfDay: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12:  "Good morning"
        case 12..<18: "Good afternoon"
        default:      "Good evening"
        }
    }

    /// Most pressing first. Each of these is a thing somebody can act on, and
    /// the last line is the one that means there is nothing to do.
    var standing: String {
        if !failed.isEmpty {
            return failed.count == 1
                ? "One post didn't go out. It needs you."
                : "\(failed.count) posts didn't go out. They need you."
        }
        if !needsYou.isEmpty {
            return needsYou.count == 1
                ? "One post is waiting for your approval."
                : "\(needsYou.count) posts are waiting for your approval."
        }
        if !inFlight.isEmpty {
            return inFlight.count == 1
                ? "One post is being made right now."
                : "\(inFlight.count) posts are being made right now."
        }
        if session.connections.isEmpty {
            return "Connect an account and Autocast can start posting for you."
        }
        if scheduledThisWeek > 0 {
            return scheduledThisWeek == 1
                ? "One post scheduled this week. Nothing needs you."
                : "\(scheduledThisWeek) posts scheduled this week. Nothing needs you."
        }
        return "Nothing waiting. A good time to make something."
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


// MARK: - The plan


// MARK: - Starting something

/// The primary action, given the weight of one.
///
/// Full width, filled, and above everything else. The two things this app is
/// for both begin behind it, and until now they were buried one inside Chat and
/// one behind a toolbar button in Library.
private struct CreateNewButton: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
            Text("Create new")
                .font(.headline)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .opacity(0.6)
        }
        // Theme.onAccent, never a literal white. The accent flips to near-white
        // in Dark Mode, so `.white` here was white text on a white pill -- the
        // same bug as before, brought back by restoring an older file.
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background {
            // A flat fill made the most important control on the screen read
            // as a dead rectangle. Two stops of the same ink and a soft shadow
            // give it a light source, so it sits above the page rather than
            // being cut out of it -- and because both stops come from the
            // accent, it stays correct in either scheme.
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.92), Theme.accent],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Capsule().strokeBorder(Theme.onAccent.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Theme.accent.opacity(0.25), radius: 10, y: 4)
        }
    }
}

/// The same destinations, one tap shallower.
///
/// A row of chips rather than a second stack of cards: these are shortcuts, and
/// a shortcut that takes as much room as the thing it shortcuts is not one.
private struct QuickActions: View {
    let hasPlan: Bool
    let hasAccount: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if hasPlan {
                    Chip(symbol: "calendar", title: "The plan") { PlanView() }
                }
                Chip(symbol: "sparkles", title: "Ideas") { ChatView() }
                if hasAccount {
                    Chip(symbol: "chart.line.uptrend.xyaxis", title: "Insights") { InsightsView() }
                }
                Chip(symbol: "square.grid.2x2", title: "Everything") { LibraryView() }
            }
            .padding(.horizontal, 2)
        }
        // The row bleeds to the screen edges while the cards around it keep
        // their margin, so it reads as scrollable rather than as clipped.
        .padding(.horizontal, -16)
        .safeAreaPadding(.horizontal, 16)
    }
}

private struct Chip<Destination: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The work, as tiles

private struct RecentGrid: View {
    let posts: [PendingPost]
    let open: (PendingPost) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(posts) { post in
                    Button { open(post) } label: {
                        PostTile(post: post)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One post, as something you recognise rather than something you read.
///
/// There is no thumbnail yet -- the video lives in Storage behind a signed URL
/// and fetching thirty of them to draw a home screen is not worth it. So the
/// tile is a colour and a caption, tinted by what happened to it, which is the
/// thing you are actually scanning for.
private struct PostTile: View {
    let post: PendingPost

    private var tint: Color {
        switch post.state {
        case .published: return .green
        case .failed:    return .red
        case .cancelled: return .orange
        default:         return Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [tint.opacity(0.85), tint.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: post.state == .published ? "checkmark.circle.fill" : "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(10)
            }
            .frame(height: 96)

            VStack(alignment: .leading, spacing: 3) {
                Text(post.caption.isEmpty ? post.post.hook : post.caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(post.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// Nothing has gone out yet.
///
/// Centred and open rather than a card, which is the reference's move and the
/// right one: a card is a container for something, and drawing a container
/// around an absence makes the absence look like a failure. Two faint panels
/// behind it show the shape the grid will take, so the space reads as reserved
/// rather than broken -- and the only thing on it is the thing to do next.
private struct NothingYetCard: View {
    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Theme.surface.opacity(0.6))
                        .frame(height: 190)
                }
            }

            VStack(spacing: 6) {
                EmptyArt(name: "empty-posts")
                    .padding(.bottom, 4)

                Text("Nothing here yet")
                    .font(.subheadline)
                    .foregroundStyle(Color(.tertiaryLabel))

                Text("Start posting")
                    .font(.title2.bold())

                Text("Plan a month and it fills this in for you, a day at a time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)

                NavigationLink { CreateView() } label: {
                    Text("Create new")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.softAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Who you are, top right

/// The connected account's own picture, in the navigation bar.
///
/// The ring is the part worth having: it goes orange when the connection needs
/// attention, so the place your eye already goes carries the one fact you would
/// otherwise have to go looking for.
/// The capsule top-right: an offer on the left, your picture on the right.
///
/// Two tap targets in one shape, which is the part worth getting right -- the
/// words open the offer and the picture opens your account, because a single
/// control that does two things does whichever one you did not want half the
/// time. The capsule around them is what makes it read as one object anyway.
private struct AccountPill: View {
    let connection: PlatformConnection?
    let upgrade: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: upgrade) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.semibold))
                    Text("Upgrade")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(Color.primary)
                .padding(.leading, 12)
            }
            .buttonStyle(.plain)

            NavigationLink { ProfileView() } label: {
                AccountAvatar(connection: connection)
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
    }
}

private struct AccountAvatar: View {
    let connection: PlatformConnection?

    private var ring: Color {
        guard let connection else { return Color(.tertiaryLabel) }
        return connection.isHealthy ? Color(.separator) : .orange
    }

    var body: some View {
        AsyncImage(url: connection?.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay(Circle().stroke(ring, lineWidth: 1))
        .accessibilityLabel(connection?.label ?? "Your account")
    }
}

// MARK: - Highlights

/// Three cards that each say one true thing and offer the one thing to do
/// about it.
///
/// They replaced a row of figures -- Posts, Views, On time -- which looked
/// informative and was not: the numbers were 0, a dash and a dash, and none of
/// them was worth a tap. A card that appears only when it has something to
/// report is a screen that never lies about being busy.
///
/// So each one is conditional. A brand new account sees none of them, which is
/// correct, and the screen is shorter rather than emptier.
private struct Highlights: View {
    let lastViews: Int?
    let scheduledThisWeek: Int
    let nextUp: PlannedPost?
    let needsVideo: Int
    let needsApproval: Int
    let timezone: TimeZone

    var body: some View {
        VStack(spacing: 12) {
            if let lastViews {
                Highlight(
                    title: "Your last video got \(lastViews.formatted(.number.notation(.compactName))) views",
                    detail: "Numbers come from TikTok, a day after posting.",
                    action: "View insights",
                    filled: true
                ) { InsightsView() }
            }

            if scheduledThisWeek > 0 {
                Highlight(
                    title: scheduledThisWeek == 1
                        ? "1 post scheduled this week"
                        : "\(scheduledThisWeek) posts scheduled this week",
                    detail: nextUpLine,
                    action: "See the plan",
                    tint: .orange
                ) { PlanView() }
            }

            if needsVideo > 0 {
                Highlight(
                    title: needsVideo == 1 ? "1 day still needs a video" : "\(needsVideo) days still need a video",
                    detail: "Make them with your generator, or add your own.",
                    action: "Open the plan"
                ) { PlanView() }
            }
        }
    }

    private var nextUpLine: String {
        guard let date = nextUp?.scheduledFor else { return "Nothing left ahead this week." }

        var calendar = Calendar.current
        calendar.timeZone = timezone

        let time = DateFormatter()
        time.timeZone = timezone
        time.dateFormat = "h:mm a"

        if calendar.isDateInToday(date) { return "Next up: today at \(time.string(from: date))" }
        if calendar.isDateInTomorrow(date) { return "Next up: tomorrow at \(time.string(from: date))" }

        let day = DateFormatter()
        day.timeZone = timezone
        day.dateFormat = "EEEE"
        return "Next up: \(day.string(from: date)) at \(time.string(from: date))"
    }
}

/// One highlight.
///
/// `filled` inverts it -- ink background, paper text -- for the card that is
/// reporting a result rather than asking for something. `tint` washes the
/// surface faintly for the one that is merely informing. Both are built from
/// system colours, so both follow Dark Mode without a second palette.
private struct Highlight<Destination: View>: View {
    let title: String
    let detail: String
    let action: String
    var filled = false
    var tint: Color?
    @ViewBuilder var destination: () -> Destination

    private var foreground: Color { filled ? Theme.onAccent : .primary }

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(foreground.opacity(filled ? 0.7 : 1))
                    .opacity(filled ? 1 : 0.6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text(action)
                    Image(systemName: "arrow.right")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.mediaRadius, style: .continuous)
        if filled {
            shape.fill(Theme.accent)
        } else if let tint {
            shape.fill(tint.opacity(0.12))
                .overlay(shape.strokeBorder(tint.opacity(0.25), lineWidth: 1))
        } else {
            shape.fill(Theme.surface)
        }
    }
}
