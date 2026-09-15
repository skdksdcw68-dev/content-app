import SwiftUI
import Charts

// MARK: - Top content

struct TopContentSection: View {
    let report: AnalyticsReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(
                title: "Top content",
                subtitle: report.topScope == "posted_in_range"
                    ? "Posted in this range, ranked by views"
                    : "Nothing was posted in this range, so this is all time"
            )

            if report.top.isEmpty {
                AnalyticsNotice(
                    symbol: "play.rectangle",
                    title: "No videos with numbers yet",
                    detail: "TikTok shares numbers for public videos only. Publish publicly and Autocast starts measuring within 6 hours."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(report.top.prefix(8)) { video in
                        NavigationLink {
                            AnalyticsPostView(videoId: video.videoId, title: video.displayTitle)
                        } label: {
                            TopContentRow(
                                video: video,
                                platformName: report.platformName(video.platform),
                                showsRelative: report.videos >= 3
                            )
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
            }
        }
    }
}

struct AnalyticsThumbnail: View {
    let url: String?
    var width: CGFloat = 56
    var height: CGFloat = 74

    var body: some View {
        Group {
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Color.track
            Image(systemName: "play.fill")
                .font(.system(size: width * 0.28))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct TopContentRow: View {
    let video: AnalyticsReport.Video
    let platformName: String
    let showsRelative: Bool

    private var meta: String {
        var parts = [platformName]
        if let day = AnalyticsFormat.day(video.postedAt) { parts.append(day) }
        if let seconds = video.durationS { parts.append(AnalyticsFormat.duration(seconds: Double(seconds))) }
        if let format = video.format { parts.append(format.capitalized) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            AnalyticsThumbnail(url: video.coverUrl)

            VStack(alignment: .leading, spacing: 5) {
                Text(video.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label(AnalyticsFormat.number(Double(video.views)), systemImage: "eye")
                    if let rate = video.engagementRate {
                        Label(AnalyticsFormat.percent(rate), systemImage: "hand.tap")
                    }
                    Label(AnalyticsFormat.number(Double(video.shares)), systemImage: "arrowshape.turn.up.right")
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 6) {
                if showsRelative, let relative = video.relative {
                    Text("\(relative.formatted(.number.precision(.fractionLength(1))))× avg")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(relative >= 1 ? Color.green : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((relative >= 1 ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .raisedCard(radius: Style.rowCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }
}

// MARK: - What Autocast learned

struct LearnedSection: View {
    let learning: LearningState?
    let failed: Bool
    let videos: Int
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(title: "What Autocast learned", subtitle: "Patterns across several posts, never one post")

            if failed {
                RetryNotice(title: "Couldn't load what Autocast learned", retry: retry)
            } else if let learning {
                if learning.insights.isEmpty {
                    if videos < 10 {
                        AnalyticsNotice(
                            symbol: "brain",
                            title: "Not enough data yet",
                            detail: "Publish a few more posts and Autocast will begin identifying reliable patterns. It needs 10 public videos with numbers; so far it has \(videos)."
                        )
                    } else {
                        AnalyticsNotice(
                            symbol: "brain",
                            title: "No reliable pattern yet",
                            detail: "Across \(videos) videos, no difference was big enough, and still true without your single biggest video, to call it a pattern."
                        )
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(learning.insights) { insight in
                            LearnedInsightCard(insight: insight)
                        }
                    }
                }
            } else {
                SkeletonRow()
            }
        }
    }
}

private struct LearnedInsightCard: View {
    let insight: Insight

    private var period: String? {
        guard let start = insight.periodStart.flatMap(PostgresTimestamp.parse),
              let end = insight.periodEnd.flatMap(PostgresTimestamp.parse) else { return nil }
        return AnalyticsFormat.range(start, end)
    }

    private var scope: String {
        let platforms = insight.platforms.map { Platform(rawValue: $0)?.displayName ?? $0.capitalized }
        let types = insight.contentTypes.map { $0.capitalized }
        return (platforms + types).joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(insight.statement)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                ConfidenceBadge(confidence: insight.confidence)
            }

            if insight.confidence == "low" {
                Text("Early signal, not proven. Worth testing.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }

            Text("Based on \(insight.sampleSize) posts · \(AnalyticsFormat.signedPercent(insight.lift)) \(insight.metric)")
                .font(.footnote.weight(.semibold).monospacedDigit())

            if let winner = insight.evidence.winner, let loser = insight.evidence.loser {
                Text("\(winner.label.capitalized): median \(AnalyticsFormat.number(winner.medianViews)) views across \(winner.posts). \(loser.label.capitalized): median \(AnalyticsFormat.number(loser.medianViews)) across \(loser.posts).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let without = insight.evidence.liftWithoutTopVideo {
                Text("Still \(AnalyticsFormat.signedPercent(without)) without your single biggest video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                if let period { Text(period) }
                if !scope.isEmpty { Text("·"); Text(scope) }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }
}

// MARK: - Autocast recommends

struct RecommendationsSection: View {
    let learning: LearningState?
    let failed: Bool
    let busy: UUID?
    let act: (Recommendation, String) -> Void
    let ask: (Recommendation) -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(title: "Autocast recommends", subtitle: "Only from what your numbers showed")

            if failed {
                RetryNotice(title: "Couldn't load recommendations", retry: retry)
            } else if let learning {
                if learning.recommendations.isEmpty {
                    AnalyticsNotice(
                        symbol: "lightbulb",
                        title: "No recommendations yet",
                        detail: "Recommendations come only from patterns Autocast has measured. As soon as one holds up, it appears here with the reason."
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(learning.recommendations) { recommendation in
                            RecommendationCard(
                                recommendation: recommendation,
                                isBusy: busy == recommendation.id,
                                act: act,
                                ask: ask
                            )
                        }
                    }
                }
            } else {
                SkeletonRow()
            }
        }
    }
}

private struct RecommendationCard: View {
    let recommendation: Recommendation
    let isBusy: Bool
    let act: (Recommendation, String) -> Void
    let ask: (Recommendation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(recommendation.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                ConfidenceBadge(confidence: recommendation.confidence)
            }

            Text("Because: \(recommendation.because)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
        .disabled(isBusy)
        .opacity(isBusy ? 0.6 : 1)
    }

    @ViewBuilder
    private var actions: some View {
        switch recommendation.status {
        case "applied":
            HStack {
                Label("Applied · your next plans use it", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Undo") { act(recommendation, "reopen") }
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.semibold))
        case "planned":
            HStack {
                Label("Added to a plan", systemImage: "calendar.badge.checkmark")
                    .foregroundStyle(.primary)
                Spacer()
                Button("Undo") { act(recommendation, "reopen") }
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.semibold))
        default:
            HStack(spacing: 8) {
                Button { act(recommendation, "apply") } label: {
                    Text("Apply")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(SoftPressStyle())

                Button { act(recommendation, "plan") } label: {
                    Text("Add to plan")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.track, in: Capsule())
                }
                .buttonStyle(SoftPressStyle())

                Spacer(minLength: 0)

                if isBusy { BreathingDot(size: 8) }

                Menu {
                    Button { ask(recommendation) } label: {
                        Label("Ask Autocast why", systemImage: "sparkles")
                    }
                    Button(role: .destructive) { act(recommendation, "ignore") } label: {
                        Label("Ignore", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.track, in: Circle())
                }
                .accessibilityLabel("More options")
            }
        }
    }
}

struct RetryNotice: View {
    let title: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Try again", action: retry)
                .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .raisedCard(radius: Style.rowCard)
    }
}

// MARK: - Best time to post

struct BestTimeSection: View {
    let bestTime: AnalyticsReport.BestTime
    let timezone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(title: "Best time to post", subtitle: "From when your own videos went out and how they did")

            if bestTime.videos < bestTime.minimum {
                AnalyticsNotice(
                    symbol: "clock",
                    title: "Not enough data yet",
                    detail: "Autocast needs more posts before making reliable timing recommendations: at least \(bestTime.minimum) videos with numbers. So far: \(bestTime.videos)."
                )
            } else if bestTime.bestHours == nil && bestTime.bestDay == nil {
                AnalyticsNotice(
                    symbol: "clock",
                    title: "No clear best time",
                    detail: "Across \(bestTime.videos) videos, no time of day or weekday did 15% better than your usual."
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if let hours = bestTime.bestHours {
                        pick(AnalyticsFormat.hourBlock(hours.slot), hours)
                    }
                    if let day = bestTime.bestDay {
                        pick("\(AnalyticsFormat.weekday(day.slot))s", day)
                    }
                    hourChart
                    Text("Times are in your brand's timezone, \(timezone). TikTok doesn't share when your followers are online.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .raisedCard()
            }
        }
    }

    private func pick(_ title: String, _ pick: AnalyticsReport.Pick) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.bold())
                Spacer(minLength: 8)
                ConfidenceBadge(confidence: pick.confidence)
            }
            Text("\(opportunity(pick.lift)) · \(AnalyticsFormat.signedPercent(pick.lift)) median views across \(pick.posts) videos")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func opportunity(_ lift: Double) -> String {
        lift >= 0.5 ? "Strong opportunity" : lift >= 0.25 ? "Good opportunity" : "Slight edge"
    }

    private var hourChart: some View {
        let best = bestTime.bestHours?.slot
        return Chart(bestTime.hours, id: \.slot) { slot in
            BarMark(
                x: .value("Time", AnalyticsFormat.clock(slot.slot)),
                y: .value("Median views", slot.medianViews)
            )
            .foregroundStyle(slot.slot == best ? Color.accentColor : Color.accentColor.opacity(0.22))
            .cornerRadius(4)
        }
        .frame(height: 120)
    }
}

// MARK: - Compare

struct CompareSection: View {
    let breakdowns: [AnalyticsReport.Group]

    @State private var dimension = ""

    private static let order = ["platform", "format", "pillar", "campaign"]

    /// Only dimensions with at least two groups of three or more posts: fewer
    /// than that is a comparison of anecdotes.
    private var meaningful: [String] {
        Self.order.filter { name in
            breakdowns.filter { $0.dimension == name && $0.posts >= 3 }.count >= 2
        }
    }

    private var active: String {
        meaningful.contains(dimension) ? dimension : (meaningful.first ?? "")
    }

    private func title(_ name: String) -> String {
        switch name {
        case "platform": "Platform"
        case "format":   "Format"
        case "pillar":   "Theme"
        default:         "Campaign"
        }
    }

    var body: some View {
        if !meaningful.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AnalyticsSectionTitle(title: "Compare", subtitle: "Median views per post, groups of 3 or more")

                VStack(alignment: .leading, spacing: 14) {
                    if meaningful.count > 1 {
                        Picker("Compare by", selection: Binding(get: { active }, set: { dimension = $0 })) {
                            ForEach(meaningful, id: \.self) { name in
                                Text(title(name)).tag(name)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    let groups = breakdowns
                        .filter { $0.dimension == active && $0.posts >= 3 }
                        .sorted { ($0.medianViews ?? 0) > ($1.medianViews ?? 0) }
                    let top = groups.first?.medianViews ?? 1

                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(group.label.map { Platform(rawValue: $0)?.displayName ?? $0.capitalized } ?? "—")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(AnalyticsFormat.number(group.medianViews ?? 0)) · \(group.posts) posts")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.track)
                                    Capsule().fill(Color.accentColor)
                                        .frame(width: max(6, proxy.size.width * CGFloat((group.medianViews ?? 0) / max(top, 1))))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
                .padding(18)
                .raisedCard()
            }
        }
    }
}

// MARK: - Campaigns

struct CampaignsSection: View {
    let report: AnalyticsReport
    let platform: String?

    var body: some View {
        if !report.campaigns.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AnalyticsSectionTitle(title: "Campaigns", subtitle: "Each plan, measured on its own")

                VStack(spacing: 10) {
                    ForEach(report.campaigns) { campaign in
                        NavigationLink {
                            CampaignAnalyticsView(campaign: campaign, platform: platform)
                        } label: {
                            AnalyticsCampaignRow(campaign: campaign)
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
            }
        }
    }
}

private struct AnalyticsCampaignRow: View {
    let campaign: AnalyticsReport.Campaign

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 38, height: 38)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(campaign.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(campaign.published) of \(campaign.posts) published · from \(AnalyticsFormat.day(campaign.startsOn) ?? campaign.startsOn)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let views = campaign.views, campaign.videos > 0 {
                    Text(AnalyticsFormat.number(Double(views)))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                    Text("views")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No numbers yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .raisedCard(radius: Style.rowCard)
    }
}

// MARK: - Autopilot

struct AutopilotSection: View {
    let report: AutopilotReport?
    let failed: Bool
    let retry: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(title: "Autopilot", subtitle: "Is it making your content operation better?")

            if failed {
                RetryNotice(title: "Couldn't load Autopilot", retry: retry)
            } else if let report {
                if report.jobs == 0 && report.published == 0 && report.planned == 0 {
                    AnalyticsNotice(
                        symbol: "paperplane",
                        title: report.isOn ? "Nothing made in this range" : "Autopilot is off",
                        detail: report.isOn
                            ? "Autopilot is on but had nothing scheduled to make in these dates. Plan a week and it starts each video a day ahead."
                            : "Turn it on in You and Autocast makes each day's video ahead of time. Its results will show here."
                    )
                } else {
                    card(report)
                }
            } else {
                SkeletonCard(height: 110)
            }
        }
    }

    private func card(_ report: AutopilotReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: columns, spacing: 10) {
                stat("Made", "\(report.succeeded)", "of \(report.jobs) attempts")
                stat("Published", "\(report.published)", "in this range")
                stat("Waiting for you", "\(report.waitingApproval)", "to approve")
                stat("Success rate",
                     report.successRate.map(AnalyticsFormat.percent) ?? "—",
                     report.successRate == nil ? "Nothing finished yet" : "\(report.failed) failed")
                stat("Generation time",
                     report.avgGenerationSeconds.map { AnalyticsFormat.duration(seconds: $0) } ?? "—",
                     report.avgGenerationSeconds == nil ? "Nothing finished yet" : "average")
                stat("Cost",
                     report.costCents.map { (Double($0) / 100).formatted(.number.precision(.fractionLength(2))) } ?? "—",
                     report.costCents == nil ? "Not reported by the provider" : "reported on \(report.costReportedJobs) jobs")
            }

            if !report.failureReasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why jobs failed")
                        .font(.footnote.weight(.semibold))
                    ForEach(report.failureReasons, id: \.code) { reason in
                        HStack {
                            Text(failureLabel(reason.code))
                                .font(.footnote)
                            Spacer()
                            Text("\(reason.count)")
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            compare(report)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }

    @ViewBuilder
    private func compare(_ report: AutopilotReport) -> some View {
        if let auto = report.compare["autopilot"], let manual = report.compare["manual"],
           auto.posts >= 3, manual.posts >= 3,
           let autoMedian = auto.medianViews, let manualMedian = manual.medianViews {
            VStack(alignment: .leading, spacing: 4) {
                Text("Autopilot vs your own videos")
                    .font(.footnote.weight(.semibold))
                Text("Autopilot: median \(AnalyticsFormat.number(autoMedian)) views across \(auto.posts). Yours: median \(AnalyticsFormat.number(manualMedian)) across \(manual.posts).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Autopilot vs your own videos: not enough published videos to compare yet. It needs 3 of each with numbers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.track.opacity(0.5), in: RoundedRectangle(cornerRadius: Style.card, style: .continuous))
    }

    private func failureLabel(_ code: String) -> String {
        switch code {
        case "no_credits":    "Out of generator credits"
        case "bad_key":       "Generator sign-in not accepted"
        case "no_models":     "No model could make it"
        case "provider_down": "Generator was down"
        case "refused":       "Generator refused the request"
        case "bad_output":    "Result was unusable"
        default:              "No reason recorded"
        }
    }
}
