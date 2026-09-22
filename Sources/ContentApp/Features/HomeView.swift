import AVKit
import SwiftUI

/// Home: what is next, the three things you do, the generator, and what has
/// been made. White cards on the grey canvas, Remi's way, no pictures.
///
/// Rebuilt twice on 22 Sep 2026. The carousel of pictures went first ("there
/// is repetitively used pictures"); then the four coloured tiles that replaced
/// it went too ("honestly looking childish... the most thing I hate from home
/// is the colours"). So: black and white, the next post leading, and nothing
/// on the page that is not a thing you can do or a thing you made.
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
    /// A video tapped, playing full screen.
    @State private var watching: BoardPost?
    /// The once-ever reminder to connect somewhere.
    @State private var nudging = false
    /// Planning a month, started from Home and finished on the plan screen.
    @State private var planning = false
    @State private var proposed: PlanProposal?

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

    /// Everything on the grid counts, uploads included.
    private var videoCount: Int { videos.count + session.uploads.count }

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                greeting
                    .padding(.top, 4)
                    .entrance(0)

                // The headline: the next post, or the offer of a month.
                Group {
                    if let next = nextUp {
                        NavigationLink { PlanView() } label: {
                            UpNextCard(post: next, timezone: brandTimeZone)
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        PlanMonthCard(hasPlan: session.plan != nil) { planning = true }
                    }
                }
                .padding(.top, 14)
                .entrance(1)

                HStack(spacing: 10) {
                    NavigationLink { ChatView() } label: {
                        HomeTile(symbol: "sparkles", title: "Make with AI")
                    }
                    .buttonStyle(SoftPressStyle())

                    if session.connections.isEmpty {
                        NavigationLink { ProfileView() } label: {
                            HomeTile(symbol: "link", title: "Connect")
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        NavigationLink { StudioFlowView() } label: {
                            HomeTile(symbol: "arrow.up.circle.fill", title: "Post a video")
                        }
                        .buttonStyle(SoftPressStyle())
                    }

                    NavigationLink { AutopilotView() } label: {
                        HomeTile(symbol: "paperplane.fill", title: "Autopilot")
                    }
                    .buttonStyle(SoftPressStyle())
                }
                .padding(.top, 14)
                .entrance(2)

                GeneratorRow(
                    connected: generator,
                    key: session.generators.first(where: \.isWorking),
                    offer: session.connectable.first(where: \.isFeatured) ?? session.connectable.first
                )
                .padding(.top, 12)
                .entrance(2)

                SectionHeader(title: "Your videos") {
                    if videoCount > 0 {
                        Text("\(videoCount)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 28)

                Group {
                    if loadedVideos == nil {
                        LazyVGrid(columns: grid, spacing: 6) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.track)
                                    .aspectRatio(9 / 16, contentMode: .fit)
                            }
                        }
                        .breathing()
                    } else if videoCount == 0 {
                        NavigationLink { StudioFlowView() } label: {
                            NoVideosCard()
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        LazyVGrid(columns: grid, spacing: 6) {
                            // On their way up from this phone, first, saying so.
                            ForEach(session.uploads) { upload in
                                UploadTile(upload: upload)
                            }
                            ForEach(videos) { video in
                                Button { watching = video } label: {
                                    VideoTile(post: video, timezone: brandTimeZone)
                                }
                                .buttonStyle(SoftPressStyle())
                                .contextMenu {
                                    Button {
                                        session.push(.post(video.id))
                                    } label: {
                                        Label("Details", systemImage: "info.circle")
                                    }
                                    if video.stage != .publishing && video.stage != .verifying {
                                        Button(role: .destructive) { deleting = video } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .entrance(3)
            }
            .screenGutter()
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        // The title and the two things top right go to the shell's bar.
        .tabChrome(
            title: timeOfDay,
            trailing: AnyView(
                HStack(spacing: 14) {
                    if session.subscription?.isPro != true {
                        Button("Upgrade") { session.showingPaywall = true }
                            .font(.subheadline.weight(.semibold))
                    }
                    NavigationLink { ProfileView() } label: {
                        InitialAvatar(initial: session.initial, size: 30)
                    }
                    .accessibilityLabel("Your profile")
                }
            )
        )
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
        // An upload finishing means a new row on the board.
        .onChange(of: session.uploads.count) { _, _ in
            Task {
                loadedVideos = try? await session.videos()
                await session.refreshPosts()
            }
        }
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
            // Pushed by value on the shell's stack, after the sheet is gone.
            if let proposed { session.push(.plan(proposed)) }
        }) {
            NewPlanSheet(brief: "") { proposed = $0 }
        }
        .fullScreenCover(item: $watching) { post in
            VideoFullScreen(post: post)
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
        // The hello is the navigation bar's large title; this is the one
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
        if !session.uploads.isEmpty {
            return session.uploads.count == 1 ? "Uploading your video." : "Uploading \(session.uploads.count) videos."
        }
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
                .font(.title3.bold())
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

// MARK: - The headline

/// The next post in the plan, made to be looked at: the day on a tile, the
/// theme and the time on one line, the hook as the headline, and underneath
/// where the post has got to -- so it reads as a thing that is happening,
/// not a row in a table.
private struct UpNextCard: View {
    let post: PlannedPost
    let timezone: TimeZone

    private var day: (weekday: String, number: String) {
        guard let date = post.scheduledFor else { return ("—", "—") }
        let style = Date.FormatStyle(timeZone: timezone)
        return (
            date.formatted(style.weekday(.abbreviated)).uppercased(),
            date.formatted(style.day())
        )
    }

    private var time: String? {
        post.scheduledFor?.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timezone))
    }

    /// Where the post is, in a person's words.
    private var standing: (symbol: String, text: String) {
        switch post.status {
        case .planned:       ("lightbulb", "Idea in place — Autocast writes it next")
        case .scripted:      ("text.alignleft", "Written — the video comes next")
        case .sourcing:      ("wand.and.stars", "Being made now")
        case .needsApproval: ("hand.raised", "Ready for your approval")
        case .scheduled:     ("clock", "Approved and scheduled")
        case .posted:        ("checkmark.circle.fill", "Posted")
        case .failed:        ("arrow.counterclockwise", "Needs another try")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("UP NEXT")
                    .font(.caption2.weight(.heavy))
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let time {
                    Text(time)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    Text(day.weekday)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(day.number)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .frame(width: 58, height: 62)
                .background(Color.track, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    if let pillar = post.pillar?.name, !pillar.isEmpty {
                        Text(pillar)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(post.hook.isEmpty ? "A post from your plan" : post.hook)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: standing.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(standing.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.bigCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The offer Home leads with when nothing is scheduled: a month of posts.
/// A white card, the calendar, two lines, and the one black button.
private struct PlanMonthCard: View {
    /// A plan exists but has nothing left to go out: the words change.
    let hasPlan: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "calendar")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 46, height: 46)
                    .background(Color.track, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(hasPlan ? "Plan the next month" : "Plan a month")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(hasPlan
                         ? "Your month is done. Write the next one."
                         : "A month of posts from one sentence. You approve each one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: action) {
                PrimaryButtonLabel(title: "Start", systemImage: "arrow.right")
            }
            .primaryButtonStyle()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.bigCard)
    }
}

// MARK: - The three things

/// One thing you do, Studio's shape: the symbol on a white card, the word
/// under it. Same as Create's tiles, so the two screens agree.
private struct HomeTile: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .raisedCard(radius: Style.rowCard)

            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The generator: the one thing asked for by name of what it is, because
/// nothing else on the screen works without it.
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
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Color.track, in: Circle())

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

// MARK: - Videos

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

/// A video on its way up from this phone: its first frame, and the word.
private struct UploadTile: View {
    let upload: AppSession.LocalUpload

    var body: some View {
        ZStack {
            if let poster = upload.poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.track
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text("Uploading")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(6)
        }
        .breathing()
        .accessibilityLabel("Uploading: \(upload.caption)")
    }
}

/// The video, full screen, from a tap on its tile. Black, the system's own
/// player, an X top left, the hook at the bottom.
private struct VideoFullScreen: View {
    let post: BoardPost

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var missing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if missing {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 30, weight: .light))
                    Text("No video yet")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.leading, 16)
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottomLeading) {
            if !post.hook.isEmpty {
                Text(post.hook)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .shadow(color: .black.opacity(0.6), radius: 4)
            }
        }
        .statusBarHidden()
        .task {
            guard let media = post.media, let url = await session.mediaURL(media) else {
                missing = true
                return
            }
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
        .onDisappear { player?.pause() }
    }
}
