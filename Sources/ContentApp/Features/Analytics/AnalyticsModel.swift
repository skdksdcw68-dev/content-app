import SwiftUI

/// The metrics Analytics knows about, whether or not a platform gives them.
///
/// All thirteen from the brief are listed, so the screen can say which ones a
/// platform does not share instead of silently leaving them out -- "Not
/// available for this platform" is information, a missing tile is a mystery.
enum AnalyticsMetric: String, CaseIterable, Identifiable {
    case views
    case likes
    case comments
    case shares
    case followersGained = "followers_gained"
    case engagementRate = "engagement_rate"
    case reach
    case saves
    case avgWatchTime = "avg_watch_time"
    case avgRetention = "avg_retention"
    case profileVisits = "profile_visits"
    case linkClicks = "link_clicks"
    case conversions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .views:           "Views"
        case .likes:           "Likes"
        case .comments:        "Comments"
        case .shares:          "Shares"
        case .followersGained: "Followers gained"
        case .engagementRate:  "Engagement rate"
        case .reach:           "Reach"
        case .saves:           "Saves"
        case .avgWatchTime:    "Average watch time"
        case .avgRetention:    "Average retention"
        case .profileVisits:   "Profile visits"
        case .linkClicks:      "Link / CTA clicks"
        case .conversions:     "Conversions"
        }
    }

    var symbol: String {
        switch self {
        case .views:           "eye.fill"
        case .likes:           "heart.fill"
        case .comments:        "bubble.right.fill"
        case .shares:          "arrowshape.turn.up.right.fill"
        case .followersGained: "person.fill.badge.plus"
        case .engagementRate:  "hand.tap.fill"
        case .reach:           "dot.radiowaves.left.and.right"
        case .saves:           "bookmark.fill"
        case .avgWatchTime:    "clock.fill"
        case .avgRetention:    "chart.line.downtrend.xyaxis"
        case .profileVisits:   "person.crop.circle"
        case .linkClicks:      "link"
        case .conversions:     "cart.fill"
        }
    }

    var isPercent: Bool { self == .engagementRate }
}

/// How much a figure can be trusted.
enum MetricStatus: Equatable {
    /// Counted from the platform's own numbers.
    case actual
    /// Worked out from actual numbers (engagement rate). Never estimated.
    case derived
    /// The platform does not give this to apps.
    case unavailable
    /// Cannot be split by a content filter (followers belong to the account).
    case filtered
    /// Autocast was not reading yet for part of the range.
    case insufficient
}

struct MetricReading {
    let metric: AnalyticsMetric
    let status: MetricStatus
    let current: Double?
    let previous: Double?
    /// Set when the total could only be counted from Autocast's first reading,
    /// not from the start of the range.
    var since: Date? = nil

    /// +0.342 for +34.2%. Nil when there is nothing to compare with.
    var change: Double? {
        guard let current, let previous, previous != 0 else { return nil }
        return (current - previous) / abs(previous)
    }

    var absoluteChange: Double? {
        guard let current, let previous else { return nil }
        return current - previous
    }
}

/// Both a period's totals and one bucket of the trend carry the same counts.
protocol GainRow {
    var views: Int? { get }
    var likes: Int? { get }
    var comments: Int? { get }
    var shares: Int? { get }
    var followers: Int? { get }
    var videos: Int { get }
    var unknown: Int { get }
    var accounts: Int { get }
    var followersUnknown: Int { get }
}

extension AnalyticsReport.Totals: GainRow {}
extension AnalyticsReport.Bucket: GainRow {}

extension GainRow {
    /// The value, only when every video in scope was measured for the whole
    /// stretch. A partial sum would undercount and look like a drop.
    func value(of metric: AnalyticsMetric) -> Double? {
        switch metric {
        case .views:    return complete(views)
        case .likes:    return complete(likes)
        case .comments: return complete(comments)
        case .shares:   return complete(shares)
        case .followersGained:
            guard accounts > 0, followersUnknown == 0, let followers else { return nil }
            return Double(followers)
        case .engagementRate:
            guard videos > 0, unknown == 0, let views, views > 0 else { return nil }
            return Double((likes ?? 0) + (comments ?? 0) + (shares ?? 0)) / Double(views)
        default:
            return nil
        }
    }

    private func complete(_ number: Int?) -> Double? {
        guard videos > 0, unknown == 0, let number else { return nil }
        return Double(number)
    }
}

struct TrendPoint: Identifiable {
    let id: Int
    let date: Date
    let endDate: Date
    let value: Double
    let previous: Double?
}

extension AnalyticsReport {
    func reading(_ metric: AnalyticsMetric) -> MetricReading {
        let raw = availability[metric.rawValue] ?? "unavailable"
        if raw == "unavailable" {
            return MetricReading(metric: metric, status: .unavailable, current: nil, previous: nil)
        }
        if metric == .followersGained && filtered {
            return MetricReading(metric: metric, status: .filtered, current: nil, previous: nil)
        }
        guard let totalsNow = totals.current, let current = totalsNow.value(of: metric) else {
            return MetricReading(metric: metric, status: .insufficient, current: nil, previous: nil)
        }
        let partial: Bool
        let from: String?
        if metric == .followersGained {
            partial = (totalsNow.followersPartial ?? 0) > 0
            from = totalsNow.followersCountedFrom
        } else {
            partial = (totalsNow.partialVideos ?? 0) > 0
            from = totalsNow.countedFrom
        }
        return MetricReading(
            metric: metric,
            status: raw == "derived" ? .derived : .actual,
            current: current,
            // A partial total is not the whole period, so it is not compared.
            previous: partial ? nil : totals.previous?.value(of: metric),
            since: partial ? from.flatMap(PostgresTimestamp.parse) : nil
        )
    }

    var isAvailableAnywhere: Bool { availability.values.contains { $0 != "unavailable" } }

    /// The trend for one metric: complete buckets only, each with the matching
    /// bucket of the previous period when that one is complete too.
    func trend(_ metric: AnalyticsMetric) -> [TrendPoint] {
        var previousByIndex: [Int: Double] = [:]
        for bucket in series where bucket.period == "previous" {
            if let value = bucket.value(of: metric) { previousByIndex[bucket.idx] = value }
        }
        let now = Date()
        return series.compactMap { bucket in
            guard bucket.period == "current",
                  let start = AnalyticsDay.parse(bucket.start),
                  let end = AnalyticsDay.parse(bucket.end),
                  start <= now,
                  let value = bucket.value(of: metric)
            else { return nil }
            return TrendPoint(id: bucket.idx, date: start, endDate: end, value: value, previous: previousByIndex[bucket.idx])
        }
    }

    var historyStartDate: Date? { historyStarts.flatMap(PostgresTimestamp.parse) }

    func platformName(_ raw: String) -> String {
        Platform(rawValue: raw)?.displayName ?? raw.capitalized
    }

    /// "TikTok", "TikTok and Reels", or "this platform".
    var platformNames: String {
        let names = platforms.map(platformName)
        return names.isEmpty ? "this platform" : ListFormatter.localizedString(byJoining: names)
    }
}

enum AnalyticsFormat {
    static func number(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.notation(.compactName))
    }

    static func value(_ value: Double, _ metric: AnalyticsMetric) -> String {
        metric.isPercent ? percent(value) : number(value)
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }

    static func signedPercent(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + percent(value)
    }

    /// "+34.2% vs previous period". Nil when there is nothing honest to say.
    static func change(_ reading: MetricReading) -> String? {
        guard let current = reading.current, let previous = reading.previous else { return nil }
        if reading.metric.isPercent {
            let points = (current - previous) * 100
            return "\(points >= 0 ? "+" : "")\(points.formatted(.number.precision(.fractionLength(1)))) pts vs previous period"
        }
        if previous == 0 {
            return current == 0 ? "Same as previous period" : "+\(number(current)) vs 0 in previous period"
        }
        let pct = (current - previous) / abs(previous)
        let absolute = current - previous
        return "\(signedPercent(pct)) (\(absolute >= 0 ? "+" : "")\(number(absolute))) vs previous period"
    }

    static func changeColor(_ reading: MetricReading) -> Color {
        guard let delta = reading.absoluteChange, delta != 0 else { return .secondary }
        return delta > 0 ? .green : .red
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func day(_ iso: String?) -> String? {
        guard let date = iso.flatMap(PostgresTimestamp.parse) ?? AnalyticsDay.parse(iso) else { return nil }
        return day(date)
    }

    static func range(_ from: Date, _ to: Date) -> String {
        Calendar.current.isDate(from, inSameDayAs: to) ? day(from) : "\(day(from)) – \(day(to))"
    }

    /// A 3-hour block starting at `hour`: "6 PM – 9 PM".
    static func hourBlock(_ hour: Int) -> String {
        "\(clock(hour)) – \(clock((hour + 3) % 24))"
    }

    static func clock(_ hour: Int) -> String {
        let components = DateComponents(hour: hour)
        guard let date = Calendar.current.date(from: components) else { return "\(hour):00" }
        return date.formatted(.dateTime.hour())
    }

    /// ISO weekday, 1 = Monday.
    static func weekday(_ iso: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols.indices.contains(iso % 7) ? symbols[iso % 7] : "—"
    }

    static func confidence(_ raw: String?) -> String {
        switch raw {
        case "high":   "High"
        case "medium": "Medium"
        case "low":    "Low"
        default:       "Not enough data"
        }
    }

    static func duration(seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int(seconds / 60)
        let rest = Int(seconds.truncatingRemainder(dividingBy: 60))
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }
}

/// A confidence label that looks the same everywhere it appears.
struct ConfidenceBadge: View {
    let confidence: String?

    private var tint: Color {
        switch confidence {
        case "high":   .green
        case "medium": .orange
        default:       .secondary
        }
    }

    var body: some View {
        Text("Confidence: \(AnalyticsFormat.confidence(confidence))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// A section's heading on the canvas, Remi's `title2.bold` with an optional line.
struct AnalyticsSectionTitle<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension AnalyticsSectionTitle where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// An honest empty state: what is missing and what to do about it.
struct AnalyticsNotice: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }
}

/// Wrappers so a sheet or a push can be driven by a value.
struct AnalyticsAsk: Identifiable, Hashable {
    let id = UUID()
    let text: String
}

struct PlanDraft: Identifiable {
    let id = UUID()
    let brief: String
}

struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
