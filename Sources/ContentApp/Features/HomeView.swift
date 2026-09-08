import SwiftUI

/// The first screen, rebuilt to the reference.
///
/// Four ideas from the design, in its order: who you are, the one post that is
/// next, the week as a strip, and three numbers. Everything that used to be a
/// stack of status cards is gone -- a card per state reads as a queue, and this
/// product is not a queue.
///
/// The header lives in the scroll rather than the navigation bar, which is why
/// the bar is hidden here. Pushed screens bring their own back button, so
/// nothing is lost by it.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    @State private var approving: PendingPost?

    private var needsYou: [PendingPost] { session.posts.filter(\.needsYou) }
    private var inFlight: [PendingPost] { session.posts.filter(\.isBusy) }
    private var failed: [PendingPost] { session.posts.filter { $0.state == .failed } }

    private var brandTimeZone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    /// The next thing due that has not gone out yet. One, not a list -- the
    /// design's whole point is that tomorrow is not your problem today.
    private var nextUp: PlannedPost? {
        session.planPosts
            .filter { ($0.scheduledFor ?? .distantPast) > .now }
            .min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    private var recent: [PendingPost] {
        session.posts
            .filter { $0.state == .published }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Greeting(
                    headline: headline,
                    connection: session.connections.first
                )

                NavigationLink { CreateView() } label: { CreateNewButton() }
                    .buttonStyle(.plain)

                PromoCarousel(
                    hasAccount: !session.connections.isEmpty,
                    hasGenerator: session.hasWorkingGenerator,
                    hasPlan: session.plan != nil
                )

                if let nextUp {
                    NavigationLink { PlanView() } label: {
                        NextUpCard(
                            post: nextUp,
                            queued: session.posts.first { $0.postId == nextUp.id },
                            handle: session.connections.first?.label,
                            timezone: brandTimeZone
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Only once there is a week to show. Seven identical grey dots
                // under the word THIS WEEK is not a calm empty state, it is a
                // component that looks like it failed to load.
                if session.plan != nil || !session.posts.isEmpty {
                    WeekStrip(
                        published: session.posts.filter { $0.state == .published },
                        planned: session.planPosts,
                        timezone: brandTimeZone
                    )
                }

                Highlights(
                    lastViews: lastViews,
                    scheduledThisWeek: scheduledThisWeek,
                    nextUp: nextUp,
                    needsVideo: needsVideo,
                    needsApproval: needsYou.count,
                    timezone: brandTimeZone
                )

                // Only the states that need a person. Everything else is the
                // strip and the numbers above.
                if !failed.isEmpty {
                    FailedCard(posts: failed) { approving = $0 }
                }

                if !needsYou.isEmpty {
                    NeedsYouCard(posts: needsYou) { approving = $0 }
                }

                if !inFlight.isEmpty {
                    InFlightCard(posts: inFlight)
                }

                if !recent.isEmpty {
                    RecentGrid(posts: recent) { approving = $0 }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            await session.refreshConnections()
            await session.refreshPosts()
            await session.refreshPlan()
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
    }

    /// The big line under the greeting.
    ///
    /// The reference puts a person's name here. This app has never asked for
    /// one -- sign-in is anonymous -- so a name would be invented. What goes
    /// there instead is the thing a name could never tell you: what today
    /// actually holds.
    private var headline: String {
        let today = Calendar.current
        let due = session.planPosts.filter { post in
            guard let when = post.scheduledFor else { return false }
            return today.isDateInToday(when)
        }

        if !needsYou.isEmpty {
            return needsYou.count == 1 ? "1 post needs you" : "\(needsYou.count) posts need you"
        }
        if due.isEmpty { return "Nothing due today" }
        return due.count == 1 ? "1 post today" : "\(due.count) posts today"
    }

    /// Views on the most recent thing that went out, when the platform has
    /// reported any. Nil is the normal state for a long while: TikTok gives
    /// numbers for public videos only, so nothing posted before the audit
    /// clears will ever have one.
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
}

// MARK: - Header

/// Greeting, headline, and the account's own picture.
private struct Greeting: View {
    let headline: String
    let connection: PlatformConnection?

    private var timeOfDay: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<12:  return "Good morning,"
        case 12..<18: return "Good afternoon,"
        default:      return "Good evening,"
        }
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeOfDay)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(headline)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 12)

            NavigationLink { ProfileView() } label: {
                AccountAvatar(connection: connection)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }
}

/// The connected account's picture, in a ring.
///
/// The ring is the honest part: it goes orange when the connection needs
/// attention, so the place your eye already goes carries the one fact you would
/// otherwise have to go hunting for.
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
        .frame(width: 38, height: 38)
        .clipShape(Circle())
        .overlay(Circle().stroke(ring, lineWidth: 1))
        .accessibilityLabel(connection?.label ?? "Your account")
    }
}

// MARK: - Next up

/// The one post that is next, with room for its picture.
///
/// The hero is a placeholder tinted by state rather than a thumbnail: the video
/// lives behind a signed URL and pulling a frame out of it means downloading it,
/// which is not a thing to do while drawing a home screen. When thumbnails
/// exist this is where they go, and nothing else about the card changes.
private struct NextUpCard: View {
    let post: PlannedPost
    let queued: PendingPost?
    let handle: String?
    let timezone: TimeZone

    private var status: (text: String, tint: Color) {
        guard let queued else { return ("Needs a video", .orange) }
        if queued.needsYou { return ("Needs you", .orange) }
        if queued.isApproved { return ("Queued", .blue) }
        return (queued.statusLine, .secondary)
    }

    var body: some View {
        // No hero block. The design has a 136pt thumbnail here and there is
        // nothing to put in it -- the video sits behind a signed URL, and a
        // tinted rectangle with an icon in the middle does not read as a design
        // choice, it reads as an image that failed to load. A clean card reads
        // as finished. When real thumbnails exist they go here and nothing else
        // about this changes.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Next up", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(post.hook)
                    .font(.system(size: 16, weight: .semibold))
                    .lineSpacing(2)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if let handle {
                        PlatformPill(text: handle)
                    }

                    Text(when)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 4)

                    StatusPill(text: status.text, tint: status.tint)
                }
            }
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius, style: .continuous))
    }

    private var when: String {
        guard let date = post.scheduledFor else { return "" }
        var calendar = Calendar.current
        calendar.timeZone = timezone

        let time = DateFormatter()
        time.timeZone = timezone
        time.dateFormat = "h:mm a"

        if calendar.isDateInToday(date) { return "\(time.string(from: date)) · Today" }
        if calendar.isDateInTomorrow(date) { return "\(time.string(from: date)) · Tomorrow" }

        let day = DateFormatter()
        day.timeZone = timezone
        day.dateFormat = "EEE d MMM"
        return "\(time.string(from: date)) · \(day.string(from: date))"
    }
}

private struct PlatformPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - The week

/// Seven days, as cells rather than dots.
///
/// The first version was a day letter, a 7pt dot and an 8pt caption under each
/// -- three sizes of nothing, and with an empty account all seven looked
/// identical, which read as a component that had failed to load rather than a
/// week with nothing in it.
///
/// Cells carry the state in their fill, which is legible at a glance and still
/// legible when the answer is "nothing yet". The counts underneath say in words
/// what the row says in shape, so neither has to be decoded.
private struct WeekStrip: View {
    let published: [PendingPost]
    let planned: [PlannedPost]
    let timezone: TimeZone

    private struct Day: Identifiable {
        let id: Date
        let letter: String
        let isToday: Bool
        let posted: Bool
        let queued: Bool
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timezone
        return calendar
    }

    private var days: [Day] {
        let calendar = self.calendar
        let today = calendar.startOfDay(for: .now)
        // The week the person is in, starting on whatever their own locale
        // calls the first day -- Monday here, Sunday in the US.
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else { return [] }

        let letters = DateFormatter()
        letters.timeZone = timezone
        letters.dateFormat = "EEEEE"

        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let start = calendar.startOfDay(for: date)

            return Day(
                id: start,
                letter: letters.string(from: start),
                isToday: calendar.isDate(start, inSameDayAs: today),
                posted: published.contains { post in
                    guard let at = post.publishedAt else { return false }
                    return calendar.isDate(at, inSameDayAs: start)
                },
                queued: planned.contains { post in
                    guard let at = post.scheduledFor else { return false }
                    return calendar.isDate(at, inSameDayAs: start)
                }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This week")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(days) { day in
                    cell(day)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func cell(_ day: Day) -> some View {
        Text(day.letter)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(day.posted ? Theme.onAccent : (day.isToday ? Color.primary : .secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if day.posted {
                    shape.fill(Theme.accent)
                } else if day.queued {
                    shape.fill(Theme.softAccent)
                } else {
                    shape.fill(Color(.tertiarySystemGroupedBackground))
                }
            }
            .overlay {
                if day.isToday {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
            .accessibilityLabel(label(day))
    }

    private var summary: String {
        let posted = days.filter(.posted).count
        let queued = days.filter { $0.queued && !$0.posted }.count

        switch (posted, queued) {
        case (0, 0):  return "Nothing yet"
        case (0, _):  return "(queued) coming"
        case (_, 0):  return "(posted) posted"
        default:      return "(posted) posted · (queued) coming"
        }
    }

    private func label(_ day: Day) -> String {
        if day.posted { return "Posted" }
        if day.queued { return "Scheduled" }
        return day.isToday ? "Today, nothing scheduled" : "Nothing"
    }
}

// MARK: - Starting something

private struct CreateNewButton: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
            Text("Create new")
                .font(.headline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity)
        .background(Theme.accent, in: Capsule())
    }
}

// MARK: - States that need a person

private struct NeedsYouCard: View {
    let posts: [PendingPost]
    let open: (PendingPost) -> Void

    var body: some View {
        Card("Waiting for you", systemImage: "hand.raised.fill") {
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

// MARK: - What has gone out

private struct RecentGrid: View {
    let posts: [PendingPost]
    let open: (PendingPost) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Posted")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(posts) { post in
                    Button { open(post) } label: { PostTile(post: post) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct PostTile: View {
    let post: PendingPost

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color.green.opacity(0.30), Color.green.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.green)
                    .padding(10)
            }
            .frame(height: 88)

            VStack(alignment: .leading, spacing: 3) {
                Text(post.caption.isEmpty ? post.post.hook : post.caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(CreatorInfo.label(for: post.privacy))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
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
