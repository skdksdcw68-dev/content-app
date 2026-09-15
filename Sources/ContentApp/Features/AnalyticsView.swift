import SwiftUI
import Charts

/// What the account is doing, laid out the way TikTok Studio lays it out.
///
/// Abel sent Studio's Analytics as the reference (15 Sep 2026): Overview,
/// Content and Followers, range chips across the top, key-metric tiles you tap
/// to change the chart, top posts with filters. This keeps that shape and only
/// what TikTok actually shares with an app -- per-video views, likes, comments
/// and shares, and the follower count. Studio's viewers, profile views,
/// gender, age, locations and traffic sources are TikTok's alone, so they are
/// not here at all rather than drawn as dashes that never fill.
///
/// "Best time to post" stands where Studio has "Most active times", and says
/// plainly what it is: how this brand's own videos did by the hour they went
/// out, not when followers are online.
///
/// History comes from `analytics_for` (0038), fed by every reading of
/// `fetch-metrics` -- each time this tab opens and every six hours on its own.
struct AnalyticsView: View {
    @Environment(AppSession.self) private var session

    @State private var metrics: Metrics?
    @State private var history: AnalyticsHistory?
    @State private var isLoading = true
    @State private var tab: AnalyticsTab = .overview
    @State private var range: AnalyticsRange = .week
    @State private var metric: OverviewMetric = .views
    @State private var topBy: OverviewMetric = .views
    @State private var bestBy: BestBy = .hours

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
                Picker("Section", selection: $tab) {
                    ForEach(AnalyticsTab.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: tab)

                if session.connections.isEmpty {
                    AnalyticsEmpty(
                        title: "Connect TikTok to see your numbers",
                        detail: "Views, likes, followers and your best time to post, for every app you market."
                    )
                    .entrance(0)
                } else {
                    ChipRow(options: AnalyticsRange.allCases, selected: $range) { $0.title }

                    if isLoading && metrics == nil && history == nil {
                        SkeletonCard(height: 170)
                        SkeletonRow()
                        SkeletonRow()
                    } else {
                        switch tab {
                        case .overview:  overview
                        case .content:   content
                        case .followers: followers
                        }
                    }
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
    }

    // MARK: - Tabs

    @ViewBuilder
    private var overview: some View {
        KeyMetricsCard(history: history, range: range, selected: $metric)
            .entrance(0)

        if let metrics {
            AccountCard(metrics: metrics, avatar: session.connections.first?.avatarURL)
                .entrance(1)
        }
    }

    @ViewBuilder
    private var content: some View {
        TopPostsCard(videos: videos, sortBy: $topBy)
            .entrance(0)

        AllPostsLink()
            .entrance(1)
    }

    @ViewBuilder
    private var followers: some View {
        FollowersCard(
            series: MetricSeries(history?.followers ?? []),
            live: metrics?.followers,
            range: range
        )
        .entrance(0)

        BestTimeCard(
            hours: history?.bestHours ?? [],
            days: history?.bestDays ?? [],
            by: $bestBy
        )
        .entrance(1)
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

// MARK: - Choices

enum AnalyticsTab: String, CaseIterable, Identifiable {
    case overview, content, followers

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview:  "Overview"
        case .content:   "Content"
        case .followers: "Followers"
        }
    }
}

/// Studio's ranges. History only starts on the day Autocast began reading, so
/// a long range simply has fewer days in it -- never invented ones.
enum AnalyticsRange: Int, CaseIterable, Identifiable {
    case week = 7
    case fourWeeks = 28
    case twoMonths = 60
    case year = 365

    var id: Int { rawValue }
    var title: String { "\(rawValue) days" }

    /// "Sep 9 – Sep 15", the way Studio heads its key metrics.
    var span: String {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -(rawValue - 1), to: end) ?? end
        let style = Date.FormatStyle().month(.abbreviated).day()
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }
}

enum OverviewMetric: String, CaseIterable, Identifiable {
    case views, likes, comments, shares

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .views:    "eye.fill"
        case .likes:    "heart.fill"
        case .comments: "bubble.right.fill"
        case .shares:   "arrowshape.turn.up.right.fill"
        }
    }

    func series(in history: AnalyticsHistory?) -> MetricSeries {
        switch self {
        case .views:    MetricSeries(history?.views ?? [])
        case .likes:    MetricSeries(history?.likes ?? [])
        case .comments: MetricSeries(history?.comments ?? [])
        case .shares:   MetricSeries(history?.shares ?? [])
        }
    }

    func value(of video: VideoStat) -> Int {
        switch self {
        case .views:    video.views
        case .likes:    video.likes
        case .comments: video.comments
        case .shares:   video.shares
        }
    }
}

enum BestBy: String, CaseIterable, Identifiable {
    case hours, days

    var id: String { rawValue }
    var title: String { self == .hours ? "Hours" : "Days" }
}

/// A running total by day, and what changed between days.
struct MetricSeries {
    struct Day: Identifiable {
        let date: Date
        let value: Int
        var id: Date { date }
    }

    let points: [Day]

    init(_ raw: [AnalyticsHistory.Point]) {
        points = raw
            .compactMap { point in point.date.map { Day(date: $0, value: point.value) } }
            .sorted { $0.date < $1.date }
    }

    var latest: Int? { points.last?.value }

    /// Gained across the range. The server sends one day before the range, so
    /// the first day in it has something to be compared with. Nil with fewer
    /// than two readings: one reading says where it is, not how it moved.
    var gained: Int? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        return last.value - first.value
    }

    /// The change from each day to the next.
    var daily: [Day] {
        zip(points.dropFirst(), points).map { next, previous in
            Day(date: next.date, value: next.value - previous.value)
        }
    }
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

private func compact(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName))
}

// MARK: - Chips

/// Studio's range and filter chips, in Remi's colours: the chosen one black
/// with white words (white with black in dark mode), the rest on the quiet grey.
private struct ChipRow<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selected: Option
    let title: (Option) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    let isOn = option == selected
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selected = option }
                    } label: {
                        Text(title(option))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? Color(uiColor: .systemBackground) : Color.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(isOn ? Color.accentColor : Color.track, in: Capsule())
                    }
                    .buttonStyle(SoftPressStyle())
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: - Overview

private struct KeyMetricsCard: View {
    let history: AnalyticsHistory?
    let range: AnalyticsRange
    @Binding var selected: OverviewMetric

    @State private var revealed = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Key metrics")
                    .font(.title3.bold())
                Text(range.span)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(OverviewMetric.allCases) { option in
                    MetricChoice(
                        metric: option,
                        series: option.series(in: history),
                        isSelected: option == selected
                    ) {
                        withAnimation(.snappy(duration: 0.25)) { selected = option }
                    }
                }
            }

            let daily = selected.series(in: history).daily
            if daily.count >= 2 {
                Chart(daily) { day in
                    LineMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value(selected.title, revealed ? day.value : 0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    PointMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value(selected.title, revealed ? day.value : 0)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(24)
                }
                .frame(height: 170)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// One key metric. Chosen, it takes Remi's selection style -- the accent
/// border and a faint accent wash -- and the chart below follows it.
private struct MetricChoice: View {
    let metric: OverviewMetric
    let series: MetricSeries
    let isSelected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                Text(metric.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(series.gained.map(compact) ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)

                Text(series.latest.map { "\(compact($0)) total" } ?? "Not reported yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: Style.card, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Style.card, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(uiColor: .separator),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Style.card, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

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
                    Text("TikTok · all time")
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
            Text(value.map(compact) ?? "—")
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

// MARK: - Content

private struct TopPostsCard: View {
    let videos: [VideoStat]
    @Binding var sortBy: OverviewMetric

    private var ranked: [VideoStat] {
        videos.sorted { sortBy.value(of: $0) > sortBy.value(of: $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your top posts")
                .font(.title3.bold())

            ChipRow(options: OverviewMetric.allCases, selected: $sortBy) { "Most \($0.title.lowercased())" }

            if ranked.isEmpty {
                VStack(spacing: 8) {
                    EmptyArt(name: "empty-analytics", size: 96)
                    Text("No top posts yet")
                        .font(.headline)
                    Text("TikTok shares numbers for public videos only. Posts made while Autocast is in review stay private.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(ranked.prefix(10).enumerated()), id: \.element.id) { index, video in
                        if index > 0 { Divider() }
                        RankedRow(rank: index + 1, video: video, metric: sortBy)
                    }
                }

                Text("All time, as TikTok reports it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }
}

private struct RankedRow: View {
    let rank: Int
    let video: VideoStat
    let metric: OverviewMetric

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(rank == 1 ? Color.primary : Color.secondary)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title.isEmpty ? "Untitled" : video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let posted = video.postedAt {
                    Text(posted.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: metric.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(compact(metric.value(of: video)))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 10)
    }
}

private struct AllPostsLink: View {
    var body: some View {
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
    }
}

// MARK: - Followers

private struct FollowersCard: View {
    let series: MetricSeries
    let live: Int?
    let range: AnalyticsRange

    @State private var revealed = false

    private var total: Int? { live ?? series.latest }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Key metrics")
                    .font(.title3.bold())
                Text(range.span)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                tile("Total followers", total.map(compact) ?? "—", "All time")
                tile("Net followers", series.gained.map(signed) ?? "—", "In \(range.title)")
            }

            if series.points.count >= 2 {
                Chart(series.points) { day in
                    LineMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Followers", revealed ? day.value : 0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    PointMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Followers", revealed ? day.value : 0)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(24)
                }
                .frame(height: 170)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.8)) { revealed = true }
                }
            } else {
                Text("The chart fills in as Autocast checks your account, every 6 hours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(compact(value))" : compact(value)
    }

    private func tile(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay {
            RoundedRectangle(cornerRadius: Style.card, style: .continuous)
                .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
        }
    }
}

/// When this brand's videos did best, by the hour or weekday they went out.
private struct BestTimeCard: View {
    let hours: [AnalyticsHistory.Slot]
    let days: [AnalyticsHistory.Slot]
    @Binding var by: BestBy

    /// Below this, one lucky video decides the answer, and a chart would state
    /// a coincidence as a finding.
    private static let minimumVideos = 3

    private var slots: [AnalyticsHistory.Slot] { by == .hours ? hours : days }
    private var videoCount: Int { hours.reduce(0) { $0 + $1.posts } }
    private var best: AnalyticsHistory.Slot? {
        slots.filter { $0.avgViews > 0 }.max { $0.avgViews < $1.avgViews }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Best time to post")
                    .font(.title3.bold())
                Text("From when your own videos went out and how they did. TikTok doesn't share when your followers are online.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ChipRow(options: BestBy.allCases, selected: $by) { $0.title }

            if videoCount < Self.minimumVideos {
                Text(videoCount == 0
                     ? "Shows once \(Self.minimumVideos) public videos have numbers."
                     : "Shows once \(Self.minimumVideos) public videos have numbers. So far: \(videoCount).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            } else {
                Chart(slots, id: \.slot) { slot in
                    BarMark(
                        x: .value(by.title, slot.slot),
                        y: .value("Average views", slot.avgViews)
                    )
                    .foregroundStyle(slot.slot == best?.slot ? Color.accentColor : Color.accentColor.opacity(0.22))
                    .cornerRadius(4)
                }
                .chartXScale(domain: by == .hours ? 0...23 : 1...7)
                .chartXAxis {
                    AxisMarks(values: by == .hours ? [0, 4, 8, 12, 16, 20] : [1, 2, 3, 4, 5, 6, 7]) { value in
                        AxisValueLabel {
                            if let number = value.as(Int.self) {
                                Text(by == .hours ? Self.hourLabel(number) : Self.dayLabel(number))
                            }
                        }
                    }
                }
                .frame(height: 160)

                if let best {
                    Text("Best so far: \(by == .hours ? Self.hourLabel(best.slot) : Self.dayLabel(best.slot)) · \(compact(best.avgViews)) average views, \(best.posts == 1 ? "from 1 video" : "across \(best.posts) videos")")
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }

    /// Studio's axis: 12a, 4a, 8a, 12p, 4p, 8p.
    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:        "12a"
        case 1..<12:   "\(hour)a"
        case 12:       "12p"
        default:       "\(hour - 12)p"
        }
    }

    private static func dayLabel(_ weekday: Int) -> String {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : "—"
    }
}

// MARK: - Empty

private struct AnalyticsEmpty: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            EmptyArt(name: "empty-analytics", size: 120)

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
