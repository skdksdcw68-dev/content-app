import AVKit
import SwiftUI

/// Home, in Photoroom's shape -- the reference Abel picked on 23 Sep 2026
/// ("the 2nd looks the best fit for us"). Its order, not its screen:
///
///   a header row that is yours (the brand, a bell, Pro)
///   one field to type into
///   "Keep creating" -- what you made, in a row
///   "Start with a tool" -- the four things, two by two, a picture on each
///   one big card for the thing worth pushing
///
/// The pictures on the tiles and the big card are his (asset names in the
/// tiles below); until each exists the tile shows its symbol on a soft
/// circle, and nothing pretends to be art.
///
/// It promotes and never warns (his call, 15 Sep 2026). What is wrong
/// reaches him as a badge on the bell and on the You tab.
///
/// Every number here is read from the database. There is no sample data.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    /// Every video made for this brand, newest first. Nil until loaded.
    @State private var loadedVideos: [BoardPost]?
    /// A video long-pressed for deletion, waiting for the confirm.
    @State private var deleting: BoardPost?
    /// A video tapped, opened to trim and take further.
    @State private var reviewing: BoardPost?
    /// The once-ever reminder to connect somewhere.
    @State private var nudging = false
    /// Planning a month, started from Home and finished on the plan screen.
    @State private var planning = false
    @State private var proposed: PlanProposal?
    /// Typed into the field at the top.
    @State private var ask = ""

    private var videos: [BoardPost] { loadedVideos ?? [] }

    /// The next thing due that has not gone out yet.
    private var nextUp: PlannedPost? {
        session.planPosts
            .filter { ($0.scheduledFor ?? .distantPast) > .now }
            .min { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    private var brandTimeZone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    /// The generator that can make videos, if there is one.
    private var generator: ProviderConnection? {
        session.connectedProviders.first { $0.isHealthy && $0.capabilities.contains("video_generation") }
            ?? session.connectedProviders.first(where: \.isHealthy)
    }

    private var hasGenerator: Bool {
        generator != nil || session.generators.contains(where: \.isWorking)
    }

    private var brandName: String {
        let name = session.brand?.name ?? ""
        return name.isEmpty || name == "My brand" ? (session.displayName ?? "Your brand") : name
    }

    private let pair = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 8)
                    .entrance(0)

                askField
                    .padding(.top, 16)
                    .entrance(1)

                SectionHeader(title: "Keep creating", chevron: !videos.isEmpty) {
                    session.push(.library)
                }
                .padding(.top, 26)

                keepCreating
                    .padding(.top, 12)
                    .entrance(2)

                SectionHeader(title: "Start with a tool", chevron: false) {}
                    .padding(.top, 26)

                LazyVGrid(columns: pair, spacing: 12) {
                    if session.plan != nil {
                        NavigationLink { PlanView() } label: {
                            ToolTile(title: "Your\nmonth", art: "tool-plan", symbol: "calendar")
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        Button { planning = true } label: {
                            ToolTile(title: "Plan a\nmonth", art: "tool-plan", symbol: "calendar")
                        }
                        .buttonStyle(SoftPressStyle())
                    }

                    NavigationLink { ChatView() } label: {
                        ToolTile(title: "Make\nwith AI", art: "tool-make", symbol: "sparkles")
                    }
                    .buttonStyle(SoftPressStyle())

                    if session.connections.isEmpty {
                        NavigationLink { ProfileView() } label: {
                            ToolTile(title: "Connect\nan account", art: "tool-post", symbol: "link")
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        NavigationLink { StudioFlowView() } label: {
                            ToolTile(title: "Post a\nvideo", art: "tool-post", symbol: "arrow.up.circle.fill")
                        }
                        .buttonStyle(SoftPressStyle())
                    }

                    NavigationLink { AutopilotView() } label: {
                        ToolTile(title: "Autopilot", art: "tool-autopilot", symbol: "paperplane.fill")
                    }
                    .buttonStyle(SoftPressStyle())
                }
                .padding(.top, 12)
                .entrance(3)

                // The one big card: the generator until there is one, then
                // the next post.
                Group {
                    if !hasGenerator {
                        NavigationLink { GeneratorsView() } label: {
                            GeneratorPromo(offer: session.connectable.first(where: \.isFeatured) ?? session.connectable.first)
                        }
                        .buttonStyle(SoftPressStyle())
                    } else if let next = nextUp {
                        NavigationLink { PlanView() } label: {
                            UpNextCard(post: next, timezone: brandTimeZone)
                        }
                        .buttonStyle(SoftPressStyle())
                    } else {
                        PlanMonthCard(hasPlan: session.plan != nil) { planning = true }
                    }
                }
                .padding(.top, 26)
                .entrance(4)
            }
            .screenGutter()
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        // The header row above is the bar; the system's steps aside here.
        .tabChrome(title: "", mode: .hidden)
        .task {
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
        }
        .sheet(isPresented: $planning, onDismiss: {
            // Pushed by value on the shell's stack, after the sheet is gone.
            if let proposed { session.push(.plan(proposed)) }
        }) {
            NewPlanSheet(brief: "") { proposed = $0 }
        }
        .fullScreenCover(item: $reviewing) { post in
            VideoReviewView(post: post)
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

    // MARK: - Header

    /// Yours, on one line: the brand on the left, the bell and Pro on the
    /// right, each on its own soft pill.
    private var header: some View {
        HStack(spacing: 10) {
            NavigationLink { ProfileView() } label: {
                HStack(spacing: 8) {
                    InitialAvatar(initial: session.initial, size: 28)
                    Text(brandName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .padding(.vertical, 6)
                .background(Color.raised, in: Capsule())
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel("Your profile")

            Spacer(minLength: 8)

            NavigationLink { ProfileView() } label: {
                Image(systemName: "bell")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .background(Color.raised, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if session.attentionCount > 0 {
                            Text("\(session.attentionCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red, in: Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel(session.attentionCount > 0 ? "\(session.attentionCount) things need you" : "Nothing needs you")

            if session.subscription?.isPro == true {
                HStack(spacing: 4) {
                    Text("Pro")
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Color.raised, in: Capsule())
            } else {
                Button { session.showingPaywall = true } label: {
                    Text("Upgrade")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(SoftPressStyle())
            }
        }
    }

    /// One field. Whatever goes in opens the chat with it.
    private var askField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Ask Autocast anything", text: $ask)
                .submitLabel(.send)
                .onSubmit {
                    let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    ask = ""
                    session.push(.chatOpening(text))
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color.raised, in: Capsule())
    }

    // MARK: - Keep creating

    @ViewBuilder
    private var keepCreating: some View {
        if loadedVideos == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.track)
                            .frame(width: 118, height: 210)
                    }
                }
            }
            .breathing()
        } else if videos.isEmpty && session.uploads.isEmpty {
            NavigationLink { StudioFlowView() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 46, height: 46)
                        .background(Color.track, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Post your first video")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Videos you make and post show up here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .raisedCard(radius: Style.rowCard)
            }
            .buttonStyle(SoftPressStyle())
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(session.uploads) { upload in
                        UploadCard(upload: upload)
                    }
                    ForEach(videos) { video in
                        Button { reviewing = video } label: {
                            RecentVideoCard(post: video)
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
                // Lets the row run to the screen's edges while the gutter
                // stays on everything else.
                .padding(.horizontal, Style.gutter)
            }
            .padding(.horizontal, -Style.gutter)
        }
    }
}

// MARK: - Pieces

private struct SectionHeader: View {
    let title: String
    let chevron: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!chevron)
    }
}

/// One made video in the row: its frame, and its words under it.
private struct RecentVideoCard: View {
    let post: BoardPost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PostThumb(media: post.media, stage: post.stage, width: 118)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if post.stage != .published {
                        StageChip(stage: post.stage, compact: true)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            Text(post.hook.isEmpty ? "Untitled" : post.hook)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
        }
        .accessibilityLabel("\(post.stage.title): \(post.hook)")
    }
}

/// A video on its way up from this phone.
private struct UploadCard: View {
    let upload: AppSession.LocalUpload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let poster = upload.poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    Color.track
                }
            }
            .frame(width: 118, height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            Text(upload.caption.isEmpty ? "New video" : upload.caption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
        }
        .accessibilityLabel("Uploading: \(upload.caption)")
    }
}

/// One tool: the words on the left, the picture on the right, Photoroom's
/// tile. The picture is Abel's, by the asset name; until it exists, the
/// symbol sits on a soft circle where the picture will go.
private struct ToolTile: View {
    let title: String
    let art: String
    let symbol: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let image = UIImage(named: art) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 60, height: 60)
                        .background(Color.track, in: Circle())
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title.replacingOccurrences(of: "\n", with: " "))
    }
}

/// The big card: the generator, until there is one. A picture across the
/// top (asset `home-generator`), the words, and the one button.
private struct GeneratorPromo: View {
    let offer: ConnectableProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = UIImage(named: "home-generator") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.track
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipped()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let Autocast make the videos")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(offer.map { "Sign in to \($0.name) once. Every post in your plan gets its video made ahead of time." }
                         ?? "Connect a generator once. Every post in your plan gets its video made ahead of time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryButtonLabel(title: offer.map { "Sign in to \($0.name)" } ?? "Connect a generator")
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous))
        .raisedCard(radius: Style.bigCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous))
    }
}

/// The next post in the plan, made to be looked at: the day on a tile, the
/// theme and the time on one line, the hook as the headline, and underneath
/// where the post has got to.
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

/// The offer when nothing is scheduled and the generator is in place: a
/// month of posts. A white card, the calendar, two lines, the one button.
private struct PlanMonthCard: View {
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
