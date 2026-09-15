import SwiftUI
import Charts

/// One post, in full: what it did, what it was, and how it compares.
///
/// Comparisons appear only against groups of three or more other videos; with
/// fewer, "2× your format average" would be a comparison with one video.
struct AnalyticsPostView: View {
    let videoId: String
    let title: String

    @Environment(AppSession.self) private var session
    @State private var data: PostAnalytics?
    @State private var failed: String?
    @State private var ask: AnalyticsAsk?

    private static let perPostUnavailable: [(String, String)] = [
        ("Reach", "reach"),
        ("Saves", "saves"),
        ("Average watch time", "avg_watch_time"),
        ("Retention", "avg_retention"),
        ("Followers gained", "followers_gained"),
        ("Link / CTA clicks", "link_clicks"),
        ("Conversions", "conversions"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let data {
                    header(data.video)
                    summary(data)
                        .padding(.top, 18)
                    growth(data)
                        .padding(.top, 14)
                    comparisons(data)
                        .padding(.top, 28)
                    contentCard(data)
                        .padding(.top, 28)
                    actions(data.video)
                        .padding(.top, 24)
                } else if let failed {
                    RetryNotice(title: failed) { Task { await load() } }
                        .padding(.top, 16)
                } else {
                    VStack(spacing: 12) {
                        SkeletonRow()
                        SkeletonCard(height: 120)
                        SkeletonCard(height: 160)
                    }
                    .padding(.top, 16)
                }
            }
            .screenGutter()
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Post")
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
            failed = "Couldn't load this post."
        }
    }

    // MARK: - Sections

    private func header(_ video: PostAnalytics.Video) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AnalyticsThumbnail(url: video.coverUrl, width: 84, height: 112)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(meta(video))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let measured = video.measuredAt.flatMap(PostgresTimestamp.parse) {
                    Text("Numbers as of \(measured.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(video.fromAutocast ? "Posted with Autocast" : "Posted outside Autocast")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.track, in: Capsule())
            }
        }
        .padding(.top, 12)
    }

    private func meta(_ video: PostAnalytics.Video) -> String {
        var parts: [String] = [Platform(rawValue: video.platform)?.displayName ?? video.platform.capitalized]
        if let posted = video.postedAt.flatMap(PostgresTimestamp.parse) {
            parts.append(posted.formatted(date: .abbreviated, time: .shortened))
        }
        if let seconds = video.durationS {
            parts.append(AnalyticsFormat.duration(seconds: Double(seconds)))
        }
        return parts.joined(separator: " · ")
    }

    private func summary(_ data: PostAnalytics) -> some View {
        let video = data.video
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                stat("Views", AnalyticsFormat.number(Double(video.views)), "eye.fill")
                stat("Engagement", video.engagementRate.map(AnalyticsFormat.percent) ?? "—", "hand.tap.fill")
                stat("Likes", AnalyticsFormat.number(Double(video.likes)), "heart.fill")
                stat("Comments", AnalyticsFormat.number(Double(video.comments)), "bubble.right.fill")
                stat("Shares", AnalyticsFormat.number(Double(video.shares)), "arrowshape.turn.up.right.fill")
            }

            VStack(spacing: 0) {
                ForEach(Self.perPostUnavailable, id: \.1) { item in
                    HStack {
                        Text(item.0)
                            .font(.footnote)
                        Spacer()
                        Text("Not available for this platform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .raisedCard(radius: Style.rowCard)
        }
    }

    private func stat(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .raisedCard(radius: Style.card)
    }

    @ViewBuilder
    private func growth(_ data: PostAnalytics) -> some View {
        let days = data.daily.compactMap { day in
            AnalyticsDay.parse(day.day).map { (date: $0, views: day.views) }
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Views over time")
                .font(.headline)
            if days.count >= 2 {
                Chart(days, id: \.date) { day in
                    LineMark(x: .value("Day", day.date, unit: .day), y: .value("Views", day.views))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", day.date, unit: .day), y: .value("Views", day.views))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(24)
                }
                .frame(height: 170)
                Text("Running total, as TikTok reported it on each day Autocast checked.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(days.first.map { "One reading so far, on \(AnalyticsFormat.day($0.date)). Growth appears after the next check, within 6 hours." }
                     ?? "No readings yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }

    private func comparisons(_ data: PostAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(title: "How it compares", subtitle: "Against the median of groups with 3 or more other videos")

            if data.comparisons.isEmpty {
                AnalyticsNotice(
                    symbol: "scalemass",
                    title: "Not enough videos to compare with",
                    detail: "Comparisons appear once there are at least 3 other videos in a group: your account, the same format, the same theme or the same platform."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(data.comparisons.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Divider() }
                        comparisonRow(group, views: data.video.views)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .raisedCard(radius: Style.rowCard)
            }
        }
    }

    private func comparisonRow(_ group: PostAnalytics.Comparison, views: Int) -> some View {
        let ratio = (group.medianViews ?? 0) > 0 ? Double(views) / (group.medianViews ?? 1) : nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.label)
                    .font(.subheadline.weight(.semibold))
                Text("\(group.posts) videos · median \(AnalyticsFormat.number(group.medianViews ?? 0)) views")
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
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(title: "The post")

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
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedCard()
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

    private func actions(_ video: PostAnalytics.Video) -> some View {
        VStack(spacing: 10) {
            Button {
                ask = AnalyticsAsk(text: "Why did my post \"\(title)\" perform the way it did?")
            } label: {
                PrimaryButtonLabel(title: "Ask Autocast why", systemImage: "sparkles")
            }
            .primaryButtonStyle()

            if let share = video.shareUrl, let link = URL(string: share) {
                Link(destination: link) {
                    Text("Open on TikTok")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.track, in: Capsule())
                }
            }
        }
    }
}
