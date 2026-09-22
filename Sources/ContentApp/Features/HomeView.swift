import SwiftUI
import TipKit

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
    /// Every video made for this brand, newest first. Nil until loaded.
    @State private var loadedVideos: [BoardPost]?
    /// A video long-pressed for deletion, waiting for the confirm.
    @State private var deleting: BoardPost?
    /// The once-a-day reminder to save the account and connect somewhere.
    @State private var nudging = false
    /// Planning a month, started from Home and finished on the plan screen.
    @State private var planning = false
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false
    /// First-time help, one at a time.
    @State private var tips = TipGroup(.ordered) {
        CreateTip()
    }

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

    /// The three things that have to exist before Autocast can run itself,
    /// each read from the account rather than remembered in a flag.
    var setup: [SetupStep] {
        [
            SetupStep(
                title: "Connect where it posts",
                detail: "TikTok, YouTube or Instagram.",
                symbol: "link",
                isDone: !session.connections.isEmpty,
                route: .profile
            ),
            SetupStep(
                title: "Connect a video generator",
                detail: "Your own key, so the frames are yours and we never bill you for them.",
                symbol: "wand.and.stars",
                isDone: session.hasWorkingGenerator,
                route: .profile
            ),
            SetupStep(
                title: "Plan your month",
                detail: "One sentence in, a month of posts out.",
                symbol: "calendar",
                isDone: session.plan != nil,
                route: .plan
            ),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                greeting
                    .padding(.top, 4)
                    .entrance(0)

                // The headline. A month is the thing this app is for, so Home
                // either offers to write one or shows the next post from the
                // one there is -- and nothing else gets to be this big.
                Group {
                    if let next = nextUp {
                        NavigationLink { PlanView().pushedPage() } label: {
                            UpNextCard(post: next, timezone: brandTimeZone)
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        PlanMonthCard(hasPlan: session.plan != nil) { planning = true }
                    }
                }
                .padding(.top, 14)
                .entrance(1)

                NavigationLink { CreateView().pushedPage() } label: {
                    PrimaryButtonLabel(title: "Create", systemImage: "plus")
                }
                .primaryButtonStyle()
                .popoverTip(tips.currentTip as? CreateTip, arrowEdge: .top)
                .padding(.top, 14)
                .entrance(2)

                // Three things, in the order they unblock each other, and gone
                // the moment they are all done. It replaced a lone "connect an
                // account" card that never mentioned the generator -- so
                // nobody connected one (Abel, 22 Sep 2026).
                if !setup.allSatisfy(\.isDone) {
                    StartHereCard(steps: setup, onPlan: { planning = true })
                        .padding(.top, 16)
                        .entrance(2)
                }

                HeroCarousel(
                    hasAccount: !session.connections.isEmpty,
                    hasPlan: session.plan != nil
                )
                .padding(.top, 22)
                .entrance(3)

                AutopilotLinkRow(brandName: session.brand?.name)
                    .padding(.top, 6)
                    .entrance(3)

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
                            EmptyStackCard(
                                art: "empty-posts",
                                symbol: "video.badge.plus",
                                message: "Videos you make show up here — drafts, scheduled and posted."
                            )
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
                NavigationLink { ProfileView().pushedPage() } label: {
                    InitialAvatar(initial: session.initial, size: 30)
                }
                .accessibilityLabel("Your profile")
            }
        }
        .task {
            today = await session.todayTally()
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
            today = await session.todayTally()
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
        .sheet(isPresented: $planning, onDismiss: {
            if proposed != nil { showingPlan = true }
        }) {
            NewPlanSheet(brief: "") { proposed = $0 }
        }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed).pushedPage()
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

// MARK: - Cards

/// One of the three things that have to exist before Autopilot can run.
struct SetupStep: Identifiable {
    enum Route { case profile, plan }

    var id: String { title }
    let title: String
    let detail: String
    let symbol: String
    let isDone: Bool
    let route: Route
}

/// Start here: connect somewhere to post, connect a generator, plan a month.
///
/// It replaced a single "Connect an account" card. That card was honest and
/// useless -- it named one of three things, so an account with a connection and
/// nothing else looked finished while the app could not make a video or fill a
/// day (Abel, 22 Sep 2026: "so they connect the generator thing").
///
/// Done steps stay, ticked, rather than vanishing one at a time: three of three
/// is the only state worth celebrating, and it is the state that removes the
/// whole card.
private struct StartHereCard: View {
    let steps: [SetupStep]
    let onPlan: () -> Void

    private var done: Int { steps.filter(\.isDone).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Start here")
                    .font(.headline)
                Spacer(minLength: 8)
                Text("\(done) of \(steps.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Divider().padding(.leading, 56) }
                row(step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.bigCard)
    }

    @ViewBuilder
    private func row(_ step: SetupStep) -> some View {
        switch step.route {
        case .profile:
            NavigationLink { ProfileView().pushedPage() } label: { label(step) }
                .buttonStyle(SoftPressStyle())
                .disabled(step.isDone)
        case .plan:
            Button(action: onPlan) { label(step) }
                .buttonStyle(SoftPressStyle())
                .disabled(step.isDone)
        }
    }

    private func label(_ step: SetupStep) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : step.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(step.isDone ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary))
                .frame(width: 28, height: 28)
                .background(step.isDone ? Color.clear : Color.track, in: Circle())
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(step.isDone ? Color.secondary : Color.primary)
                    .strikethrough(step.isDone, color: .secondary)
                if !step.isDone {
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if !step.isDone {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The offer Home leads with when there is nothing scheduled: a month of posts.
///
/// A picture that runs to the card's edges with the words over it, rather than
/// a row with an icon -- Home's job is to make the best thing in the app look
/// like the best thing in the app (Abel, 22 Sep 2026: "the ui on the home is
/// the main thing actually").
private struct PlanMonthCard: View {
    /// A plan exists but has nothing left to go out: the words change, the
    /// offer does not.
    let hasPlan: Bool
    let action: () -> Void

    private var art: UIImage? {
        ["hero-plan", "promo-plan"].lazy.compactMap { UIImage(named: $0) }.first
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let art {
                        Image(uiImage: art)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color(red: 0.13, green: 0.13, blue: 0.15), .black],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.8), location: 1),
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(hasPlan ? "PLAN THE NEXT ONE" : "PLAN A MONTH")
                        .font(.caption2.weight(.heavy))
                        .kerning(1.4)
                        .foregroundStyle(.white.opacity(0.7))

                    Text(hasPlan
                         ? "Your month is done. Write the next one."
                         : "A month of posts from one sentence")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Start")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(.white, in: Capsule())
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(hasPlan ? "Plan the next month" : "Plan a month of posts")
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

/// The way into Autopilot from Home: what it is, never what is wrong.
private struct AutopilotLinkRow: View {
    let brandName: String?

    var body: some View {
        NavigationLink { AutopilotView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "airplane")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Autopilot")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("What it’s doing for \(brandName ?? "you"), and what’s next")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
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
