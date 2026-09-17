import SwiftUI
import Charts

/// One video, laid out like Studio's "Video analysis": the cover and its
/// numbers across the top, then tabs. What TikTok only gives Business accounts
/// -- watch time, retention, traffic sources, who watched -- says so in its own
/// card. Comparisons appear only against groups of three or more other videos.
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let data {
                    header(data.video)
                        .padding(.bottom, 12)
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
        .task { await load() }
        .navigationDestination(item: $ask) { question in
            ChatView(opening: question.text)
        }
    }

    private func load() async {
        do {
            data = try await session.postAnalytics(videoId: videoId)
            failed = nil
        } catch {
            failed = "Couldn't load this video."
        }
    }

    // MARK: - Header

    private func header(_ video: PostAnalytics.Video) -> some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottom) {
                AnalyticsThumbnail(url: video.coverUrl, width: 116, height: 154)
                if let seconds = video.durationS {
                    Text(AnalyticsFormat.duration(seconds: Double(seconds)))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(.bottom, 8)
                }
            }

            if let posted = video.postedAt.flatMap(PostgresTimestamp.parse) {
                Text("Posted on \(posted.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                stat("play.fill", video.views)
                separator
                stat("heart.fill", video.likes)
                separator
                stat("ellipsis.bubble.fill", video.comments)
                separator
                stat("arrowshape.turn.up.right.fill", video.shares)
            }
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

    private func stat(_ symbol: String, _ value: Int) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 0.5, height: 30)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    // MARK: - Pages

    @ViewBuilder
    private func overview(_ data: PostAnalytics) -> some View {
        AnalyticsCard(
            title: "Key metrics",
            subtitle: data.video.measuredAt.flatMap(PostgresTimestamp.parse).map { "As of \($0.formatted(date: .abbreviated, time: .shortened))" },
            info: "Lifetime numbers for this video, as TikTok reported them at Autocast's last check."
        ) {
            LazyVGrid(columns: columns, spacing: 12) {
                KeyTile(title: "Video views", value: AnalyticsFormat.number(Double(data.video.views)), isSelected: true)
                KeyTile(
                    title: "Engagement rate",
                    value: data.video.engagementRate.map(AnalyticsFormat.percent) ?? "—",
                    caption: "Likes, comments and shares per view"
                )
            }
            growth(data)
        }
        BusinessOnlyCard(
            title: "Watch time and retention",
            detail: "Total play time, average watch time, how many watched to the end, and the second people stopped watching."
        )
        BusinessOnlyCard(
            title: "Traffic sources",
            detail: "For You, search, your profile, following and messages."
        )
    }

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
        comparisons(data)
        BusinessOnlyCard(
            title: "Likes across the video",
            detail: "The moment in the video where most people liked it."
        )
    }

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

    // MARK: - Pieces

    @ViewBuilder
    private func growth(_ data: PostAnalytics) -> some View {
        let days = data.daily.compactMap { day in
            AnalyticsDay.parse(day.day).map { (date: $0, views: day.views) }
        }
        if days.count >= 2 {
            Chart(days, id: \.date) { day in
                AreaMark(x: .value("Day", day.date, unit: .day), y: .value("Views", day.views))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Views", day.views))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel()
                }
            }
            .frame(height: 180)
            Text("Running total on each day Autocast checked.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Text(days.first.map { "One reading so far, on \(AnalyticsFormat.day($0.date)). The chart appears after the next check, within 6 hours." }
                 ?? "No readings yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Text("\(ratio.formatted(.number.precision(.fractionLength(1))))×")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(ratio >= 1 ? Color.green : Color.red)
            }
        }
        .padding(.vertical, 10)
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
