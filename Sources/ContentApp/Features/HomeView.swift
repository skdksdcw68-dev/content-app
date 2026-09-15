import SwiftUI

/// Home: what Autocast is doing for you, laid out the way Remi lays out a day.
///
/// Remi's Home (`remi/native/Sources/Remi/Views/Home/HomeView.swift`) is the
/// reference: the mark and the name at the top with one capsule on the right,
/// white cards on the grey canvas, a pager of pictures, then the things
/// themselves as cards with the picture down the left edge.
///
/// It promotes and never warns. Abel, 15 Sep 2026: no bad warnings on Home.
/// What is wrong still reaches him -- a badge on the You tab and a "Needs
/// attention" section there -- because a failure nobody sees is how three
/// silent days happened in September. It moved; it was not dropped.
///
/// Every number here is read from the database. There is no sample data.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    @State private var approving: PendingPost?
    /// What was made today, read once when the page appears.
    @State private var today: AppSession.DayTally?
    /// Naming another app to market.
    @State private var addingBrand = false
    @State private var newBrand = ""

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

    /// What went out, newest first.
    private var recent: [PendingPost] {
        session.posts
            .filter { $0.state == .published }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HomeHeader(adding: $addingBrand)
                    // Off the status bar: with the navigation bar hidden the
                    // name and picture would sit right under the clock.
                    .padding(.top, 18)

                greeting
                    .padding(.top, 22)
                    .entrance(0)

                HeroCarousel(
                    hasAccount: !session.connections.isEmpty,
                    hasPlan: session.plan != nil
                )
                .padding(.top, 16)
                .entrance(1)

                NavigationLink { CreateView() } label: {
                    PrimaryButtonLabel(title: "Create", systemImage: "plus")
                }
                .primaryButtonStyle()
                .padding(.top, 14)
                .entrance(2)

                if session.connections.isEmpty {
                    ConnectCard()
                        .padding(.top, 16)
                        .entrance(3)
                }

                SectionHeader(title: "Up next")
                    .padding(.top, 28)

                Group {
                    if let nextUp {
                        NavigationLink { PlanView() } label: {
                            UpNextCard(post: nextUp, timezone: brandTimeZone)
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        NavigationLink { CreateView() } label: {
                            EmptyStackCard(
                                art: "empty-plan",
                                symbol: "calendar",
                                message: "Plan your first week and your next post shows up here."
                            )
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
                .padding(.top, 12)
                .entrance(4)

                if !needsYou.isEmpty {
                    SectionHeader(title: "Waiting for you")
                        .padding(.top, 28)

                    VStack(spacing: 12) {
                        ForEach(needsYou.prefix(4)) { post in
                            Button { approving = post } label: {
                                PostCard(post: post, kind: .review)
                            }
                            .buttonStyle(SoftPressStyle())
                        }
                    }
                    .padding(.top, 12)
                }

                if !inFlight.isEmpty {
                    SectionHeader(title: "On its way")
                        .padding(.top, 28)

                    VStack(spacing: 12) {
                        ForEach(inFlight) { post in
                            PostCard(post: post, kind: .working)
                        }
                    }
                    .padding(.top, 12)
                }

                SectionHeader(title: "Recently posted") {
                    NavigationLink { LibraryView() } label: {
                        Text("View all")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 28)

                Group {
                    if recent.isEmpty {
                        EmptyStackCard(
                            art: "empty-posts",
                            symbol: "play.rectangle",
                            message: "Your posts appear here once they go out."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(recent) { post in
                                Button { approving = post } label: {
                                    PostCard(post: post, kind: .result)
                                }
                                .buttonStyle(SoftPressStyle())
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
            .screenGutter()
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        // Home draws its own top -- the mark, the name, the capsule -- so the
        // bar is hidden here. Pushed pages show their own.
        .toolbar(.hidden, for: .navigationBar)
        .task { today = await session.todayTally() }
        .refreshable {
            await session.refreshConnections()
            await session.refreshPosts()
            await session.refreshPlan()
            await session.refreshHealth()
            today = await session.todayTally()
        }
        // Named here, and nothing else asked: what it is for, who it is for
        // and how it should sound are the agent's questions, not a form's.
        .alert("Add an app", isPresented: $addingBrand) {
            TextField("What is it called?", text: $newBrand)
            Button("Cancel", role: .cancel) { newBrand = "" }
            Button("Add") {
                let name = newBrand
                newBrand = ""
                Task {
                    await session.addBrand(named: name)
                    today = await session.todayTally()
                }
            }
        } message: {
            Text("Its own plan, its own accounts, its own schedule.")
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
    }
}

// MARK: - The greeting

private extension HomeView {
    var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timeOfDay)
                .font(.title.bold())
                .foregroundStyle(.primary)

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
            return "Connect TikTok and Autocast posts for you."
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

// MARK: - Top

/// The mark and the name on the left; one capsule on the right holding the app
/// you are marketing and your picture. Remi's header, with the brand switcher
/// where Remi keeps its streak.
private struct HomeHeader: View {
    @Binding var adding: Bool
    @Environment(AppSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            TowerMark()
                .frame(width: 34, height: 34)
            Text("Autocast")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                BrandMenu(adding: $adding)

                NavigationLink { ProfileView() } label: {
                    AccountAvatar(url: session.connections.first?.avatarURL)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your account")
            }
            .padding(.leading, 12)
            .padding(3)
            .background(Color.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5))
        }
    }
}

/// Which app this page is about. Switching is a tap, because posting one app's
/// video under another's name is the worst mistake this product can make.
private struct BrandMenu: View {
    @Binding var adding: Bool
    @Environment(AppSession.self) private var session

    var body: some View {
        Menu {
            ForEach(session.brands) { brand in
                Button {
                    Task { await session.switchBrand(to: brand.id) }
                } label: {
                    if brand.id == session.brand?.id {
                        Label(brand.name, systemImage: "checkmark")
                    } else {
                        Text(brand.name)
                    }
                }
            }
            Divider()
            Button { adding = true } label: {
                Label("Add an app", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(session.brand?.name ?? "My app")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Switch app")
    }
}

/// Your picture, in a quiet ring. Always the same ring: the orange one that
/// meant "needs attention" is gone with the rest of Home's warnings.
private struct AccountAvatar: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5))
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

// MARK: - Cards

/// The one way into connecting, shaped like Remi's coach card: an invitation,
/// not a warning.
private struct ConnectCard: View {
    var body: some View {
        NavigationLink { ProfileView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect TikTok")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Then Autocast can post for you")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
    }
}

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

/// A post that exists: waiting for approval, on its way, or already out.
private struct PostCard: View {
    enum Kind { case review, working, result }

    let post: PendingPost
    let kind: Kind

    private var title: String {
        post.caption.isEmpty ? post.post.hook : post.caption
    }

    var body: some View {
        HStack(spacing: 0) {
            DayTile(date: post.publishedAt ?? post.post.createdAt)

            VStack(alignment: .leading, spacing: 7) {
                Text(title.isEmpty ? "Untitled post" : title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                switch kind {
                case .review:
                    Text(post.state == .needsReapproval ? "Changed · review it again" : "Ready · tap to review")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .working:
                    HStack(spacing: 4) {
                        BreathingDot(size: 8)
                        Text(post.statusLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .result:
                    HStack(spacing: 5) {
                        Image(systemName: "eye.fill")
                            .font(.footnote)
                        Text(views)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            if kind == .review {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 14)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        .raisedCard(radius: Style.rowCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }

    /// TikTok reports numbers for public videos only, so a post can be out and
    /// still have none. "Posted" then, never a zero.
    private var views: String {
        guard let count = post.metrics?.views else { return "Posted" }
        return count == 1 ? "1 view" : "\(count.formatted(.number.notation(.compactName))) views"
    }
}

/// Nothing here yet: a card for a post-to-be, and one line saying what comes.
/// Remi: `EmptyMealsCard`, with the picture where Remi puts its salad.
private struct EmptyStackCard: View {
    let art: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .top) {
                // A second card peeking out from behind, as if a stack.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.raised)
                    .frame(height: 64)
                    .padding(.horizontal, 34)
                    .offset(y: 14)
                    .opacity(0.7)

                HStack(spacing: 14) {
                    Group {
                        if let image = UIImage(named: art) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: symbol)
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 9) {
                        Capsule().fill(Color(uiColor: .systemGray5)).frame(height: 9)
                        Capsule().fill(Color(uiColor: .systemGray5)).frame(width: 96, height: 9)
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.raised)
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                }
                .padding(.horizontal, 18)
            }
            .padding(.top, 22)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous)
                .fill(Color.track.opacity(0.6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
        }
    }
}
