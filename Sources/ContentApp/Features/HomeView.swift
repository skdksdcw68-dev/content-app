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

                QuickActions(
                    hasPlan: session.plan != nil,
                    hasAccount: !session.connections.isEmpty
                )

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

                WeekStrip(
                    published: session.posts.filter { $0.state == .published },
                    planned: session.planPosts,
                    timezone: brandTimeZone
                )

                StatsRow(
                    posts: session.posts.filter { $0.state == .published }.count,
                    onTime: onTime
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

    /// Published, out of everything that reached a decision. A post that missed
    /// its window is the only thing that counts against it.
    private var onTime: Int? {
        let done = session.posts.filter { $0.state == .published }.count
        let missed = session.posts.filter { $0.state == .failed }.count
        guard done + missed > 0 else { return nil }
        return Int((Double(done) / Double(done + missed) * 100).rounded())
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
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [status.tint.opacity(0.30), status.tint.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: queued == nil ? "video.badge.plus" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(status.tint.opacity(0.8))
            }
            .frame(height: 136)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 12) {
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
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
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

/// Seven days, one dot each.
///
/// Filled behind you, hollow today, faint ahead. It answers "am I keeping this
/// up" in one glance, which is the question a content app is actually for and
/// the one a list of rows never answers.
private struct WeekStrip: View {
    let published: [PendingPost]
    let planned: [PlannedPost]
    let timezone: TimeZone

    private struct Day: Identifiable {
        let id: Date
        let letter: String
        let isToday: Bool
        let isPast: Bool
        let posted: Bool
        let queued: Bool

        var label: String? {
            if posted { return "Posted" }
            if isToday { return "Today" }
            if queued { return "Queued" }
            return nil
        }
    }

    private var days: [Day] {
        var calendar = Calendar.current
        calendar.timeZone = timezone

        let today = calendar.startOfDay(for: .now)
        // The week the person is in, starting on whatever their locale calls
        // the first day -- Monday here, Sunday in the US, and the strip should
        // read the way their own calendar app does.
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
                isPast: start < today,
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
        VStack(alignment: .leading, spacing: 12) {
            Text("This week")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 0) {
                ForEach(days) { day in
                    VStack(spacing: 6) {
                        Text(day.letter)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(day.isToday ? Color.primary : Color(.tertiaryLabel))

                        dot(for: day)
                            .frame(width: 20, height: 20)

                        Text(day.label ?? " ")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func dot(for day: Day) -> some View {
        if day.isToday {
            Circle().stroke(Color.primary, lineWidth: 1.5).frame(width: 12, height: 12)
        } else if day.posted {
            Circle().fill(Color.primary).frame(width: 7, height: 7)
        } else if day.queued {
            Circle().fill(Color(.tertiaryLabel)).frame(width: 7, height: 7)
        } else {
            Circle().fill(Color(.quaternaryLabel)).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Numbers

/// Three figures, big, with no card around them.
///
/// A dash where a number is not known yet, never a zero. TikTok reports views
/// only for public videos, so an unaudited account genuinely has no figure --
/// and a confident 0 would be a lie about something that was never measured.
private struct StatsRow: View {
    let posts: Int
    let onTime: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Stat(value: "\(posts)", label: "Posts")
            Stat(value: "—", label: "Views")
            Stat(value: onTime.map { "\($0)%" } ?? "—", label: "On time")
        }
    }

    private struct Stat: View {
        let value: String
        let label: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    Chip(symbol: "chart.bar", title: "Insights") { InsightsView() }
                }
                Chip(symbol: "square.grid.2x2", title: "Everything") { LibraryView() }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, -24)
        .safeAreaPadding(.horizontal, 24)
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
