import SwiftUI
import Charts

/// What the account is doing, read back from the platform, over time.
///
/// It replaces the Library tab (Abel, 15 Sep 2026: "instead of library the
/// analytics is better"). Nothing from Library is lost -- "All posts" at the
/// bottom opens the same list.
///
/// Two sources. The live numbers come from `fetch-metrics` when the tab opens;
/// the history comes from `analytics_for`, fed by every one of those readings
/// and by a cron every six hours (0037). Nothing is projected or estimated: a
/// figure the platform did not return is a dash, and a chart with fewer than
/// two days says so instead of drawing one point as a line.
struct AnalyticsView: View {
    @Environment(AppSession.self) private var session

    @State private var metrics: Metrics?
    @State private var history: AnalyticsHistory?
    @State private var isLoading = true
    @State private var range: AnalyticsRange = .week

    /// The saved readings when there are any, because they know when each
    /// video went out; otherwise what TikTok just said.
    private var videos: [VideoStat] {
        if let saved = history?.videos, !saved.isEmpty {
            return saved.map(VideoStat.init)
        }
        return (metrics?.recent ?? []).map(VideoStat.init)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if session.connections.isEmpty {
                    AnalyticsEmpty(
                        title: "Connect TikTok to see your numbers",
                        detail: "Followers, views and what worked, for every app you market."
                    )
                    .entrance(0)
                } else if isLoading && metrics == nil && history == nil {
                    SkeletonCard(height: 44)
                    SkeletonCard(height: 160)
                    SkeletonRow()
                    SkeletonRow()
                } else {
                    if let metrics {
                        AccountCard(metrics: metrics, avatar: session.connections.first?.avatarURL)
                            .entrance(0)
                    }

                    ViewsChartCard(points: history?.views ?? [], range: $range)
                        .entrance(1)

                    if let top = videos.max(by: { $0.views < $1.views }), top.views > 0 {
                        TopVideoCard(video: top)
                            .entrance(2)
                    }

                    if videos.isEmpty {
                        AnalyticsEmpty(
                            title: "Post your first video to see what works",
                            detail: "View counts appear once videos are public. Posts made while Autocast is in review with TikTok stay private."
                        )
                        .entrance(3)
                    } else {
                        HStack {
                            Text("Every video")
                                .font(.title2.bold())
                            Spacer()
                        }
                        .padding(.top, 10)

                        ForEach(videos) { video in
                            VideoRow(video: video)
                        }
                    }

                    NavigationLink { LibraryView() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .frame(width: 38, height: 38)
                                .background(Color.accentColor, in: Circle())
                            Text("All posts")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .raisedCard(radius: Style.rowCard)
                    }
                    .buttonStyle(SoftPressStyle())
                    .padding(.top, 6)
                }
            }
            .screenGutter()
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Analytics")
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: range) { _, newRange in
            Task { history = await session.analytics(days: newRange.rawValue) }
        }
        .sensoryFeedback(.selection, trigger: range)
    }

    private func load() async {
        guard !session.connections.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        // Live first: it also writes today's reading, so the history fetched
        // straight after already includes it.
        metrics = await session.metrics()
        history = await session.analytics(days: range.rawValue)
    }
}

enum AnalyticsRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var short: String { self == .week ? "7D" : "30D" }
    var phrase: String { self == .week ? "this week" : "this month" }
}

/// One video, from whichever source had it.
struct VideoStat: Identifiable, Hashable {
    let id: String
    let title: String
    let views: Int
    let likes: Int
    let comments: Int
    let shares: Int
    let postedAt: Date?

    init(_ saved: AnalyticsHistory.Video) {
        id = saved.id
        title = saved.title
        views = saved.views
        likes = saved.likes
        comments = saved.comments
        shares = saved.shares
        postedAt = saved.postedAt.flatMap(PostgresTimestamp.parse)
    }

    init(_ live: VideoMetric) {
        id = live.id
        title = live.title
        views = live.views
        likes = live.likes
        comments = live.comments
        shares = live.shares
        postedAt = nil
    }
}

// MARK: - Cards

private struct AccountCard: View {
    let metrics: Metrics
    let avatar: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AsyncImage(url: avatar) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("@\(metrics.username)")
                        .font(.headline)
                    Text("TikTok")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                stat("Followers", metrics.followers)
                Divider().frame(height: 34)
                stat("Likes", metrics.totalLikes)
                Divider().frame(height: 34)
                stat("Videos", metrics.videoCount)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }

    /// A dash when the platform did not say. "Not reported" and "nobody did
    /// it" are different facts.
    private func stat(_ label: String, _ value: Int?) -> some View {
        VStack(spacing: 3) {
            Text(value.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ViewsChartCard: View {
    let points: [AnalyticsHistory.Point]
    @Binding var range: AnalyticsRange

    @State private var revealed = false

    private struct Dated: Identifiable {
        let date: Date
        let value: Int
        var id: Date { date }
    }

    private var dated: [Dated] {
        points.compactMap { point in point.date.map { Dated(date: $0, value: point.value) } }
    }

    private var latest: Int { dated.last?.value ?? 0 }
    private var growth: Int { latest - (dated.first?.value ?? latest) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Views")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(dated.isEmpty ? "—" : latest.formatted(.number.notation(.compactName)))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if growth > 0 {
                        Text("+\(growth.formatted(.number.notation(.compactName))) \(range.phrase)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Spacer(minLength: 8)

                Picker("Range", selection: $range) {
                    ForEach(AnalyticsRange.allCases) { option in
                        Text(option.short).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }

            if dated.count >= 2 {
                Chart(dated) { point in
                    AreaMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Views", revealed ? point.value : 0)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Views", revealed ? point.value : 0)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                .frame(height: 160)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.8)) { revealed = true }
                }
            } else {
                Text("The chart fills in as Autocast checks your videos, every 6 hours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            }
        }
        .padding(18)
        .raisedCard()
    }
}

private struct TopVideoCard: View {
    let video: VideoStat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.orange)
                Text("Top video")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(video.title.isEmpty ? "Untitled" : video.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 16) {
                count("eye.fill", video.views)
                count("heart.fill", video.likes)
                count("bubble.right.fill", video.comments)
                count("arrowshape.turn.up.right.fill", video.shares)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }

    private func count(_ symbol: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value.formatted(.number.notation(.compactName)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}

/// One video, in Remi's `MealCard` shape.
private struct VideoRow: View {
    let video: VideoStat

    var body: some View {
        HStack(spacing: 0) {
            DayTile(date: video.postedAt, size: 84)

            VStack(alignment: .leading, spacing: 7) {
                Text(video.title.isEmpty ? "Untitled" : video.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label(video.views.formatted(.number.notation(.compactName)), systemImage: "eye")
                    Label(video.likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                    Label(video.comments.formatted(), systemImage: "bubble.right")
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        .raisedCard(radius: Style.rowCard)
    }
}

private struct AnalyticsEmpty: View {
    let title: String
    let detail: String

    private var art: String {
        UIImage(named: "empty-analytics") != nil ? "empty-analytics" : "empty-insights"
    }

    var body: some View {
        VStack(spacing: 10) {
            EmptyArt(name: art, size: 120)

            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .raisedCard()
    }
}
