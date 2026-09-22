import SwiftUI
import Charts

/// One video, laid out like Studio's "Video analysis" and filled with every
/// number Autocast has: the video itself playing on the page, the counts
/// across the top, then Overview (rates, growth, rings against the account's
/// own videos, what stands out, what to make next), Viewers, Engagement and
/// About. What only TikTok Business gives says so in its own card.
struct AnalyticsPostView: View {
    let videoId: String
    let title: String

    enum Page: String, CaseIterable, Hashable {
        case overview, viewers, engagement, about

        var title: String {
            switch self {
            case .overview:   "Overview"
            case .viewers:    "Viewers"
            case .engagement: "Engagement"
            case .about:      "About"
            }
        }
    }

    @Environment(AppSession.self) private var session
    @State private var data: PostAnalytics?
    @State private var failed: String?
    @State private var ask: AnalyticsAsk?
    @State private var page: Page = .overview
    @State private var playing = false
    @State private var planDraft: PlanDraft?
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let data {
                    header(data.video)
                        .padding(.bottom, 14)
                }

                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        if let data {
                            switch page {
                            case .overview:   overview(data)
                            case .viewers:    viewers
                            case .engagement: engagement(data)
                            case .about:      about(data)
                            }
                        } else if let failed {
                            RetryNotice(title: failed) { Task { await load() } }
                        } else {
                            SkeletonCard(height: 200)
                            SkeletonCard(height: 120)
                        }
                    }
                    .screenGutter()
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                } header: {
                    UnderlineTabs(items: Page.allCases, selection: $page) { $0.title }
                }
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Video analysis")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .task { await load() }
        .refreshable { await load() }
        .navigationDestination(item: $ask) { question in
            ChatView(opening: question.text)
        }
        .sheet(item: $planDraft, onDismiss: {
            if proposed != nil { showingPlan = true }
        }) { draft in
            NewPlanSheet(brief: draft.brief) { proposed = $0 }
        }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed)
        }
    }

    private func load() async {
        do {
            data = try await session.postAnalytics(videoId: videoId)
            failed = nil
        } catch {
            if data == nil { failed = "Couldn't load this video." }
        }
    }

    // MARK: - Header

    private func header(_ video: PostAnalytics.Video) -> some View {
        VStack(spacing: 12) {
            player(video)

            if let posted = video.postedAt.flatMap(PostgresTimestamp.parse) {
                Text("Posted on \(posted.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                stat("eye", video.views, "Views")
                stat("heart", video.likes, "Likes")
                stat("bubble.left", video.comments, "Comments")
                stat("arrowshape.turn.up.right", video.shares, "Shares")
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .raisedCard(radius: 18)
            .padding(.top, 4)

            Text(video.fromAutocast ? "Posted with Autocast" : "Posted outside Autocast")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.track, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .screenGutter()
    }

    /// The cover until tapped, then TikTok's own player in the same frame.
    @ViewBuilder
    private func player(_ video: PostAnalytics.Video) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            if playing {
                TikTokPlayer(videoId: video.videoId)
            } else {
                AnalyticsThumbnail(url: video.coverUrl, width: 170, height: 302)
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                Button {
                    withAnimation(.snappy(duration: 0.25)) { playing = true }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel("Play video")
                if let seconds = video.durationS {
                    Text(AnalyticsFormat.duration(seconds: Double(seconds)))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(width: 170, height: 302)
        .background(Color.black)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private func stat(_ symbol: String, _ value: Int, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(height: 24)
            Text(AnalyticsFormat.number(Double(value)))
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: - Overview

    @ViewBuilder
    private func overview(_ data: PostAnalytics) -> some View {
        keyMetrics(data)
        growth(data)
        rings(data)
        standsOut(data)
        nextStep(data)
        BusinessOnlyCard(
            title: "Watch time and retention",
            detail: "Total play time, average watch time, how many watched to the end, and the second people stopped watching."
        )
        BusinessOnlyCard(
            title: "Traffic sources",
            detail: "For You, search, your profile, following and messages."
        )
    }

    private func keyMetrics(_ data: PostAnalytics) -> some View {
        let video = data.video
        let context = data.context
        let views = Double(video.views)
        return AnalyticsCard(
            title: "Key metrics",
            subtitle: data.video.measuredAt.flatMap(PostgresTimestamp.parse).map { "As of \($0.formatted(date: .abbreviated, time: .shortened))" },
            info: "Lifetime numbers for this video, as TikTok reported them at Autocast's last check. Rates are worked out from those numbers."
        ) {
            LazyVGrid(columns: columns, spacing: 12) {
                KeyTile(
                    title: "Video views",
                    value: AnalyticsFormat.number(views),
                    caption: context.map { "#\($0.rank) of your \($0.videos) videos" },
                    isSelected: true
                )
                KeyTile(
                    title: "Engagement rate",
                    value: video.engagementRate.map(AnalyticsFormat.percent) ?? "—",
                    caption: context?.medianEngagement.map { "Your usual: \(AnalyticsFormat.percent($0))" } ?? "Likes, comments and shares per view"
                )
                KeyTile(
                    title: "Likes per 100 views",
                    value: views > 0 ? (Double(video.likes) / views * 100).formatted(.number.precision(.fractionLength(1))) : "—"
                )
                KeyTile(
                    title: "Comments per 1K views",
                    value: views > 0 ? (Double(video.comments) / views * 1000).formatted(.number.precision(.fractionLength(1))) : "—"
                )
                KeyTile(
                    title: "Share rate",
                    value: views > 0 ? AnalyticsFormat.percent(Double(video.shares) / views) : "—",
                    caption: "Shares per view"
                )
                KeyTile(
                    title: "Views per hour",
                    value: viewsPerHour(views, context?.hoursLive),
                    caption: context?.hoursLive.map { "Live for \(PostInsights.liveFor($0))" }
                )
                KeyTile(
                    title: "Share of your views",
                    value: context?.shareOfViews.map(AnalyticsFormat.percent) ?? "—",
                    caption: "Across all your videos"
                )
                KeyTile(
                    title: "Length",
                    value: video.durationS.map { "\($0)s" } ?? "—",
                    caption: context?.medianDuration.map { "Your usual: \(Int($0.rounded()))s" }
                )
            }
        }
    }

    private func viewsPerHour(_ views: Double, _ hours: Double?) -> String {
        guard let hours, hours > 0 else { return "—" }
        return AnalyticsFormat.number(views / hours)
    }

    @ViewBuilder
    private func growth(_ data: PostAnalytics) -> some View {
        let points = (data.readings ?? []).compactMap { reading in
            PostgresTimestamp.parse(reading.at).map { (at: $0, views: reading.views) }
        }
        AnalyticsCard(
            title: "Views over time",
            subtitle: PostInsights.recentGrowth(data.readings ?? []).map { "+\($0.views) views in the last \(PostInsights.liveFor($0.hours))" },
            info: "Running total at each hourly check. The steeper the line, the faster it's growing."
        ) {
            if points.count >= 2 {
                Chart(points, id: \.at) { point in
                    AreaMark(x: .value("Time", point.at), y: .value("Views", point.views))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.at), y: .value("Views", point.views))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Time", point.at), y: .value("Views", point.views))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(18)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel()
                    }
                }
                .frame(height: 190)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text(points.first.map { "One reading so far, at \($0.at.formatted(date: .omitted, time: .shortened)). Autocast checks every hour, so the curve appears within the hour." }
                         ?? "No readings yet. Autocast checks every hour.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The "O" charts: this video against the account's own, at a glance.
    @ViewBuilder
    private func rings(_ data: PostAnalytics) -> some View {
        let video = data.video
        let context = data.context
        let viewsRatio = PostInsights.ratio(Double(video.views), to: context?.medianViews)
        let engagementRatio = video.engagementRate.flatMap { PostInsights.ratio($0, to: context?.medianEngagement) }
        let share = context?.shareOfViews
        if viewsRatio != nil || engagementRatio != nil || share != nil {
            AnalyticsCard(
                title: "Against your usual",
                info: "For views and engagement, a full ring is your other videos' median; past full, the ring turns green. Share is this video's part of all your views."
            ) {
                HStack(alignment: .top, spacing: 8) {
                    if let viewsRatio {
                        ringTile("Views", progress: viewsRatio, text: PostInsights.times(viewsRatio),
                                 usual: "Usual \(AnalyticsFormat.number(context?.medianViews ?? 0))",
                                 good: viewsRatio >= 1)
                    }
                    if let engagementRatio {
                        ringTile("Engagement", progress: engagementRatio, text: PostInsights.times(engagementRatio),
                                 usual: "Usual \(AnalyticsFormat.percent(context?.medianEngagement ?? 0))",
                                 good: engagementRatio >= 1)
                    }
                    if let share {
                        ringTile("Of all views", progress: share, text: AnalyticsFormat.percent(share),
                                 usual: context.map { "\($0.videos) videos" } ?? "",
                                 good: false)
                    }
                }
            }
        }
    }

    private func ringTile(_ label: String, progress: Double, text: String, usual: String, good: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                ProgressRing(progress: min(1, max(0, progress)), lineWidth: 9, color: good ? .green : .accentColor)
                Text(text)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 12)
            }
            .frame(width: 86, height: 86)
            Text(label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Text(usual)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func standsOut(_ data: PostAnalytics) -> some View {
        let items = PostInsights.observations(data)
        if !items.isEmpty {
            AnalyticsCard(
                title: "What stands out",
                subtitle: "Compared with your own videos. Observations, not proven causes.",
                info: "Worked out from this video's numbers and your other videos'. Watch time and traffic sources would say more, and come with TikTok Business."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.title3)
                                .foregroundStyle(item.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(item.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func nextStep(_ data: PostAnalytics) -> some View {
        let step = PostInsights.nextStep(data, title: title)
        // Inverted, as in the mockup: the one card that asks for an action.
        let ink = Theme.onAccent
        return VStack(alignment: .leading, spacing: 12) {
            Label("What to post next", systemImage: "sparkles")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.headline)
                Text(step.detail)
                    .font(.subheadline)
                    .opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    planDraft = PlanDraft(brief: step.brief)
                } label: {
                    Text("Plan it")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(ink, in: Capsule())
                }
                .buttonStyle(SoftPressStyle())

                Button {
                    ask = AnalyticsAsk(text: "Why did my post \"\(title)\" perform the way it did, and what should I post next?")
                } label: {
                    Text("Ask Autocast")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(Capsule().strokeBorder(ink.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(SoftPressStyle())
            }
        }
        .foregroundStyle(ink)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Viewers

    @ViewBuilder
    private var viewers: some View {
        BusinessOnlyCard(
            title: "Total viewers",
            detail: "Unique viewers, new vs returning, and followers vs non-followers."
        )
        BusinessOnlyCard(
            title: "Gender, age and locations",
            detail: "Who watched this video."
        )
    }

    // MARK: - Engagement

    @ViewBuilder
    private func engagement(_ data: PostAnalytics) -> some View {
        AnalyticsCard(title: "Engagement") {
            LazyVGrid(columns: columns, spacing: 12) {
                KeyTile(title: "Likes", value: AnalyticsFormat.number(Double(data.video.likes)))
                KeyTile(title: "Comments", value: AnalyticsFormat.number(Double(data.video.comments)))
                KeyTile(title: "Shares", value: AnalyticsFormat.number(Double(data.video.shares)))
                KeyTile(title: "Engagement rate", value: data.video.engagementRate.map(AnalyticsFormat.percent) ?? "—")
            }
        }
        engagementMix(data.video)
        comparisons(data)
        BusinessOnlyCard(
            title: "Saves and likes across the video",
            detail: "How many saved it, and the moment in the video where most people liked it."
        )
    }

    /// The donut: what the engagement was made of.
    @ViewBuilder
    private func engagementMix(_ video: PostAnalytics.Video) -> some View {
        let parts: [(name: String, value: Int, color: Color)] = [
            ("Likes", video.likes, Color.accentColor),
            ("Comments", video.comments, Color.accentColor.opacity(0.55)),
            ("Shares", video.shares, Color.accentColor.opacity(0.25)),
        ]
        let total = parts.reduce(0) { $0 + $1.value }
        if total > 0 {
            AnalyticsCard(title: "What people did", info: "Of every like, comment and share, how much was each.") {
                HStack(spacing: 20) {
                    Chart(parts, id: \.name) { part in
                        SectorMark(
                            angle: .value("Count", part.value),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .cornerRadius(3)
                        .foregroundStyle(part.color)
                    }
                    .frame(width: 120, height: 120)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(AnalyticsFormat.number(Double(total)))
                                .font(.headline.monospacedDigit())
                            Text("actions")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(parts, id: \.name) { part in
                            HStack(spacing: 8) {
                                Circle().fill(part.color).frame(width: 9, height: 9)
                                Text(part.name)
                                    .font(.subheadline)
                                Spacer(minLength: 6)
                                Text(AnalyticsFormat.percent(Double(part.value) / Double(total)))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                        }
                    }
                }
            }
        }
    }

    private func comparisons(_ data: PostAnalytics) -> some View {
        AnalyticsCard(
            title: "How it compares",
            info: "This video's views against the median of groups with at least 3 other videos."
        ) {
            if data.comparisons.isEmpty {
                Text("Not enough other videos to compare with yet. Comparisons appear once a group has 3 or more.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(data.comparisons.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Divider() }
                        comparisonRow(group, views: data.video.views)
                    }
                }
            }
        }
    }

    private func comparisonRow(_ group: PostAnalytics.Comparison, views: Int) -> some View {
        let median = group.medianViews ?? 0
        let ratio = median > 0 ? Double(views) / median : nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.label)
                    .font(.subheadline.weight(.semibold))
                Text("\(group.posts) videos · median \(AnalyticsFormat.number(median)) views")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let ratio {
                Text(PostInsights.times(ratio))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(ratio >= 1 ? Color.green : Color.red)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - About

    @ViewBuilder
    private func about(_ data: PostAnalytics) -> some View {
        contentCard(data)
        Button {
            ask = AnalyticsAsk(text: "Why did my post \"\(title)\" perform the way it did?")
        } label: {
            PrimaryButtonLabel(title: "Ask Autocast why", systemImage: "sparkles")
        }
        .primaryButtonStyle()

        if let share = data.video.shareUrl, let link = URL(string: share) {
            Link(destination: link) {
                Text("Open on TikTok")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.track, in: Capsule())
            }
        }
    }

    private func contentCard(_ data: PostAnalytics) -> some View {
        AnalyticsCard(title: "The post") {
            VStack(alignment: .leading, spacing: 12) {
                if let post = data.post {
                    info("Hook", post.hook)
                    info("Caption", post.caption)
                    info("What it showed", post.concept)
                    info("Call to action", nil, empty: "Not tracked yet: Autocast doesn't store a separate call to action")
                    info("Format", post.format?.capitalized)
                    info("Theme", post.pillar)
                    info("Campaign", post.campaign)
                    info("Hashtags", post.hashtags.map { $0.joined(separator: " ") })
                    info("Published", post.publishedAt.flatMap(PostgresTimestamp.parse).map { $0.formatted(date: .abbreviated, time: .shortened) })
                    info("Why it was planned", post.rationale)
                } else {
                    info("Caption", data.video.description ?? data.video.title)
                    if let tags = data.context?.hashtags {
                        info("Hashtags", "\(tags)")
                    }
                    Text("Posted outside Autocast, so there is no hook, theme or media record, only what TikTok reports.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Media used")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if data.media.isEmpty {
                        Text(data.post == nil ? "Not recorded" : "No media recorded for this post")
                            .font(.subheadline)
                    } else {
                        ForEach(Array(data.media.enumerated()), id: \.offset) { _, item in
                            Text(mediaLine(item))
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func info(_ label: String, _ value: String?, empty: String? = nil) -> some View {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (text?.isEmpty == false) || empty != nil {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text((text?.isEmpty == false ? text : empty) ?? "")
                    .font(.subheadline)
                    .foregroundStyle(text?.isEmpty == false ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mediaLine(_ media: PostAnalytics.Media) -> String {
        var parts: [String] = []
        if let kind = media.kind { parts.append(kind.capitalized) }
        if let source = media.source {
            parts.append(source == "generated" ? "Generated" : source == "user_upload" ? "Uploaded by you" : source.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if let model = media.model { parts.append(model) }
        if let ms = media.durationMs { parts.append(AnalyticsFormat.duration(seconds: Double(ms) / 1000)) }
        if let width = media.width, let height = media.height { parts.append("\(width)×\(height)") }
        return parts.isEmpty ? "Media" : parts.joined(separator: " · ")
    }
}
