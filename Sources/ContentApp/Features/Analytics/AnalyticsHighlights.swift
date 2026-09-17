import SwiftUI
import Charts

/// The cards from the approved mockup (17 Sep 2026): the big number at the top
/// of Overview, the top three with "See all", how far learning has got, and
/// Content's grid of posts with each one's share of the views.

// MARK: - The big number

struct ViewsHeroCard: View {
    let report: AnalyticsReport
    let range: String

    private var reading: MetricReading { report.reading(.views) }

    private var badge: String? {
        if let since = reading.since { return "Since \(AnalyticsFormat.day(since))" }
        return AnalyticsFormat.change(reading)
    }

    private var detail: String {
        var parts = ["\(report.videos) public \(report.videos == 1 ? "video" : "videos")"]
        if let followers = report.followersTotal {
            parts.append("\(AnalyticsFormat.number(Double(followers))) followers")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let points = report.trend(.views)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Views · \(range)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(reading.since == nil ? AnalyticsFormat.changeColor(reading) : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.track, in: Capsule())
                }
            }
            Text(reading.current.map { AnalyticsFormat.number($0) } ?? "—")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if points.count >= 2 {
                Chart(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Views", point.value))
                        .foregroundStyle(Color.track)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Views", point.value))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 72)
                .padding(.top, 8)
                .accessibilityHidden(true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: 18)
    }
}

// MARK: - Top three

struct TopPostsPreview: View {
    let report: AnalyticsReport
    let seeAll: () -> Void

    private var ranked: [AnalyticsReport.Video] {
        Array(report.top.sorted { $0.views > $1.views }.prefix(3))
    }

    var body: some View {
        if !ranked.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Top posts")
                        .font(.title3.bold())
                    Spacer()
                    Button("See all", action: seeAll)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, video in
                    NavigationLink {
                        AnalyticsPostView(videoId: video.videoId, title: video.displayTitle)
                    } label: {
                        RankedPostRow(
                            rank: index + 1,
                            video: video,
                            sort: .views,
                            platformName: report.platformName(video.platform),
                            showsRelative: report.videos >= 3
                        )
                    }
                    .buttonStyle(SoftPressStyle())
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedCard(radius: 18)
        }
    }
}

// MARK: - How far learning has got

/// Shown until there are enough videos to learn from. Counting up to 10 says
/// what is missing without dressing one video up as a pattern.
struct LearningProgressCard: View {
    let videos: Int
    private let needed = 10

    var body: some View {
        if videos < needed {
            VStack(alignment: .leading, spacing: 12) {
                Label("What Autocast learned", systemImage: "sparkles")
                    .font(.title3.bold())
                Text("Patterns start once Autocast has read \(needed) public videos. It never calls one video a pattern.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(videos), total: Double(needed))
                    .tint(Color.accentColor)
                Text("\(videos) of \(needed) videos")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedCard(radius: 18)
        }
    }
}

// MARK: - Content grid

enum GridSort: String, CaseIterable, Hashable {
    case views, engagement, newest

    var title: String {
        switch self {
        case .views:      "Views"
        case .engagement: "Engagement"
        case .newest:     "Newest"
        }
    }
}

/// Studio's posts, three across: the cover, its rank and its views.
struct PostsGridCard: View {
    let report: AnalyticsReport

    @State private var sort: GridSort = .views

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    private var sorted: [AnalyticsReport.Video] {
        switch sort {
        case .views:      report.top.sorted { $0.views > $1.views }
        case .engagement: report.top.sorted { ($0.engagementRate ?? 0) > ($1.engagementRate ?? 0) }
        case .newest:     report.top.sorted { ($0.postedAt ?? "") > ($1.postedAt ?? "") }
        }
    }

    var body: some View {
        AnalyticsCard(
            title: "Posts",
            subtitle: report.top.isEmpty ? nil
                : (report.topScope == "posted_in_range" ? "Posted in this range" : "Nothing was posted in this range, so this is all time"),
            info: "Each video's lifetime numbers, as TikTok reports them. TikTok only shares numbers for public videos."
        ) {
            if report.top.isEmpty {
                Text("Publish a public video and Autocast shows it here within the hour.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SoftChips(items: GridSort.allCases, selection: $sort) { $0.title }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(sorted.prefix(12).enumerated()), id: \.element.id) { index, video in
                        NavigationLink {
                            AnalyticsPostView(videoId: video.videoId, title: video.displayTitle)
                        } label: {
                            cell(video, rank: index + 1)
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
            }
        }
    }

    private func cell(_ video: AnalyticsReport.Video, rank: Int) -> some View {
        Color.track
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let url = video.coverUrl.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.track
                    }
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .topLeading) {
                Text("\(rank)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.black)
                    .frame(width: 20, height: 20)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(7)
            }
            .overlay(alignment: .bottomLeading) {
                Label(label(video), systemImage: sort == .engagement ? "hand.tap.fill" : "play.fill")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(video.displayTitle), \(label(video))")
    }

    private func label(_ video: AnalyticsReport.Video) -> String {
        if sort == .engagement {
            return video.engagementRate.map(AnalyticsFormat.percent) ?? "—"
        }
        return AnalyticsFormat.number(Double(video.views))
    }
}

// MARK: - Share of views

/// Of all the views these posts have, how much each one has.
struct ViewsShareCard: View {
    let report: AnalyticsReport

    private var ranked: [AnalyticsReport.Video] {
        report.top.sorted { $0.views > $1.views }
    }

    var body: some View {
        let total = ranked.reduce(0) { $0 + $1.views }
        if ranked.count >= 2, total > 0 {
            AnalyticsCard(
                title: "Where views came from",
                info: "Each post's lifetime views as a share of all the posts listed here."
            ) {
                VStack(spacing: 14) {
                    ForEach(ranked.prefix(6)) { video in
                        let fraction = Double(video.views) / Double(total)
                        PercentBarRow(
                            label: video.displayTitle,
                            value: AnalyticsFormat.percent(fraction),
                            fraction: fraction
                        )
                    }
                }
            }
        }
    }
}
