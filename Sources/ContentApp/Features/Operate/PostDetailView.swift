import SwiftUI
import PhotosUI

/// One planned post in a list: the video, the hook, the words, and where it is.
struct PostPreviewCard: View {
    let post: BoardPost
    let timezone: TimeZone

    private var time: String {
        guard let when = post.when else { return "No time yet" }
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: when)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PostThumb(media: post.media, stage: post.stage, width: 74)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(time)
                        .font(.caption.weight(.bold).monospacedDigit())
                    Text("·").foregroundStyle(.tertiary)
                    Text(post.platformName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    StageChip(stage: post.stage, compact: true)
                }

                Text(post.hook)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if !post.publishText.isEmpty {
                    Text(post.publishText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    if let pillar = post.pillar { FactChip(text: pillar) }
                    if let cta = post.cta, !cta.isEmpty { FactChip(text: "CTA", symbol: "hand.tap") }
                    if post.media?.source == "user_upload" { FactChip(text: "Your video", symbol: "person.crop.square") }
                    if post.approved { FactChip(text: "Approved", symbol: "checkmark.seal") }
                }
                .padding(.top, 1)

                if post.stage == .needsAttention, let problem = post.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }
}

/// Exactly what Autocast is going to publish, where it is in the loop, and the
/// one thing to do about it.
struct PostDetailView: View {
    let postID: UUID

    @Environment(AppSession.self) private var session
    @State private var post: BoardPost?
    @State private var failed = false
    @State private var reviewing = false
    @State private var rescheduling = false
    @State private var pickingVideo = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var attaching = false

    private var timezone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    var body: some View {
        ScrollView {
            if let post {
                content(post)
            } else if failed {
                ContentUnavailableView("Couldn't load this post", systemImage: "exclamationmark.triangle",
                                       description: Text("Pull to try again."))
                    .padding(.top, 80)
            } else {
                VStack(spacing: 14) {
                    SkeletonCard(height: 360)
                    SkeletonCard(height: 160)
                }
                .screenGutter()
                .padding(.top, 12)
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .refreshable { await load() }
        .task { await load() }
        // While Autocast is working on it, check back. Keyed on the stage so it
        // stops as soon as nothing is moving.
        .task(id: post?.stage) { await watch() }
        .sheet(isPresented: $reviewing) {
            if let post {
                ReviewSheet(post: post) { Task { await load() } }
            }
        }
        .sheet(isPresented: $rescheduling) {
            if let post {
                RescheduleSheet(post: post) { Task { await load() } }
            }
        }
        .photosPicker(isPresented: $pickingVideo, selection: $pickerItem, matching: .videos)
        .task(id: pickerItem) { await attachPicked() }
    }

    @ViewBuilder
    private func content(_ post: BoardPost) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()
                PostMediaView(media: post.media, concept: post.concept, height: 400)
                Spacer()
            }
            .padding(.top, 8)

            header(post)
            move(post)

            section("What will be published") {
                VStack(alignment: .leading, spacing: 12) {
                    labelled("Hook", post.hook, strong: true)
                    if let caption = post.caption, !caption.isEmpty {
                        labelled(post.isPrepared ? "Caption (with CTA)" : "Caption", caption)
                    }
                    if !post.isPrepared, let cta = post.cta, !cta.isEmpty {
                        labelled("Call to action", cta)
                    }
                    if let tags = post.hashtags, !tags.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Hashtags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            FlowTags(tags: tags)
                        }
                    }
                    Divider()
                    HStack(spacing: 6) {
                        FactChip(text: post.platformName, symbol: "music.note")
                        FactChip(text: (post.format ?? "video").capitalized, symbol: "film")
                        if let pillar = post.pillar { FactChip(text: pillar, symbol: "square.stack") }
                        if let privacy = post.privacyName { FactChip(text: privacy, symbol: "eye") }
                    }
                }
            }

            section("Progress") {
                LoopTimeline(post: post, timezone: timezone)
            }

            if let concept = post.concept, !concept.isEmpty {
                section("What the video shows") {
                    Text(concept).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let rationale = post.rationale, !rationale.isEmpty {
                section("Why this post") {
                    Text(rationale).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let plan = post.planTitle {
                Label("Part of \(plan)", systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .screenGutter()
        .padding(.bottom, 32)
    }

    private func header(_ post: BoardPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StageChip(stage: post.stage)
            Text(whenLine(post))
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let username = post.username {
                    Text("@\(username)")
                } else {
                    Text("No \(post.platformName) account connected")
                }
                if post.connectionStatus != nil, post.connectionStatus != "active" {
                    Text("· needs reconnecting").foregroundStyle(.red)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func whenLine(_ post: BoardPost) -> String {
        if post.stage == .published, let date = post.publishedDate ?? post.when {
            return "Published " + LoopTimeline.format(date, timezone)
        }
        guard let when = post.when else { return "Not scheduled yet" }
        if when < Date() && post.stage != .publishing && post.stage != .verifying {
            return "Was due " + LoopTimeline.format(when, timezone)
        }
        return "Goes out " + LoopTimeline.format(when, timezone)
    }

    @ViewBuilder
    private func move(_ post: BoardPost) -> some View {
        switch post.stage {
        case .readyForReview:
            MoveBanner(yours: true, text: "Check the video and caption, then approve it.",
                       action: ("Review", { reviewing = true }))
        case .needsAttention:
            if post.targetState == "needs_reapproval" {
                MoveBanner(yours: true, text: "It changed after you approved it. Approve this version to post it.",
                           action: ("Review", { reviewing = true }))
            } else {
                MoveBanner(yours: true, text: post.problem ?? "Something went wrong. Pick a new time to try again.",
                           action: ("New time", { rescheduling = true }))
            }
        case .approved:
            MoveBanner(yours: true, text: "Approved, but its time has passed. Pick a new one.",
                       action: ("Pick time", { rescheduling = true }))
        case .readyToPublish:
            MoveBanner(yours: false, text: "Approved and queued. Autopilot publishes it at its time, then checks it went live.",
                       action: ("Change time", { rescheduling = true }))
        case .publishing:
            MoveBanner(yours: false, text: "Uploading to \(post.platformName) now.")
        case .verifying:
            MoveBanner(yours: false, text: "\(post.platformName) has it. Waiting for it to confirm the post is live.")
        case .generating:
            MoveBanner(yours: false, text: "Making the video. It comes to you for review when it's done.")
        case .published:
            if let url = post.tiktokURL {
                MoveBanner(yours: false, text: "Live. Autocast reads its numbers every hour and learns from them.",
                           action: ("Open", { UIApplication.shared.open(url) }))
            } else {
                MoveBanner(yours: false, text: post.privacy == "SELF_ONLY"
                           ? "Published privately — only you can see it on \(post.platformName)."
                           : "Published. Autocast reads its numbers every hour and learns from them.")
            }
        case .inDrafts:
            MoveBanner(yours: true, text: "It's in your TikTok drafts (inbox). Open TikTok to add sound or effects and post it.",
                       action: ("Open TikTok", { if let url = URL(string: "snssdk1233://") { UIApplication.shared.open(url) } }))
        case .scheduled, .draft:
            if post.media == nil && attaching {
                MoveBanner(yours: false, text: "Adding your video and checking it…")
            } else if post.media == nil {
                MoveBanner(yours: true, text: "This post needs a video.",
                           action: ("Add video", { pickingVideo = true }))
            } else {
                MoveBanner(yours: false, text: "Waiting for the plan to be approved.")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }

    private func labelled(_ title: String, _ text: String, strong: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(strong ? .body.weight(.semibold) : .subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Loading

    private func load() async {
        do {
            post = try await session.boardPost(postID)
            failed = post == nil
        } catch {
            if post == nil { failed = true }
        }
    }

    private func watch() async {
        guard let stage = post?.stage else { return }
        let dueSoon = (post?.when ?? .distantFuture).timeIntervalSinceNow < 15 * 60
        guard stage.isWorking || (stage == .readyToPublish && dueSoon) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(stage.isWorking ? 6 : 15))
            guard !Task.isCancelled else { return }
            let before = post?.stage
            await load()
            if post?.stage != before { return }
        }
    }

    /// A video for a post that has none: the same prepare and validate steps
    /// the upload flow runs.
    private func attachPicked() async {
        guard let pickerItem, let post else { return }
        defer { self.pickerItem = nil }
        attaching = true
        defer { attaching = false }
        do {
            guard let movie = try await pickerItem.loadTransferable(type: Movie.self) else { return }
            let facts = try await VideoFacts.read(movie.url)
            let path = try await session.uploadVideo(at: movie.url)
            try? FileManager.default.removeItem(at: movie.url)
            let prepared = try await session.prepare(post: post.id, path: path, video: facts)
            if prepared.ok {
                _ = try await session.validate(post: post.id)
            }
            await load()
        } catch {
            session.lastError = session.readableMessage(error)
        }
    }
}

/// Hashtags that wrap onto as many lines as they need.
struct FlowTags: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
