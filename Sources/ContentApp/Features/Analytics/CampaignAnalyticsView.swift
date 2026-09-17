import SwiftUI

/// One campaign, measured over its own dates with the same report as the main
/// screen, filtered to it -- so its totals, trend and top content are the same
/// arithmetic, not a second implementation.
///
/// "What worked" and "what failed" are said only from its own posts' numbers,
/// and only once there are three or more; the next action is a remake of a post
/// that clearly stood out, or an honest "nothing stands out yet".
struct CampaignAnalyticsView: View {
    let campaign: AnalyticsReport.Campaign
    let platform: String?

    @Environment(AppSession.self) private var session
    @State private var report: AnalyticsReport?
    @State private var failed = false
    @State private var metric: AnalyticsMetric = .views
    @State private var planDraft: PlanDraft?
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false

    private var range: (from: Date, to: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = AnalyticsDay.parse(campaign.startsOn) ?? today
        let end = calendar.date(byAdding: .day, value: max(0, campaign.days - 1), to: start) ?? start
        let from = min(start, today)
        return (from, max(from, min(end, today)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if let report {
                    KeyMetricsCard(
                        report: report,
                        metrics: [.views, .likes, .comments, .shares, .engagementRate],
                        selected: $metric,
                        subtitle: AnalyticsFormat.range(range.from, range.to)
                    )
                    .padding(.top, 18)
                    verdict(report)
                        .padding(.top, 28)
                    TopPostsCard(report: report)
                        .padding(.top, 28)
                } else if failed {
                    RetryNotice(title: "Couldn't load this campaign") { Task { await load() } }
                        .padding(.top, 18)
                } else {
                    VStack(spacing: 12) {
                        SkeletonCard(height: 120)
                        SkeletonCard(height: 190)
                    }
                    .padding(.top, 18)
                }
            }
            .screenGutter()
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Campaign")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $planDraft, onDismiss: {
            if proposed != nil { showingPlan = true }
        }) { draft in
            NewPlanSheet(brief: draft.brief) { proposed = $0 }
        }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(campaign.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("\(AnalyticsFormat.range(range.from, range.to)) · \(campaign.published) of \(campaign.posts) posts published · \(campaign.status.capitalized)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private func load() async {
        do {
            report = try await session.analyticsReport(AnalyticsQuery(
                from: range.from, to: range.to, platform: platform, format: nil, pillarId: nil, planId: campaign.id
            ))
            failed = false
        } catch {
            failed = true
        }
    }

    @ViewBuilder
    private func verdict(_ report: AnalyticsReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalyticsSectionTitle(title: "What worked, what didn't")

            if report.top.count < 3 {
                AnalyticsNotice(
                    symbol: "megaphone",
                    title: "Not enough to judge yet",
                    detail: "This campaign has \(report.top.count) published video\(report.top.count == 1 ? "" : "s") with numbers. Autocast compares posts once there are 3 or more."
                )
            } else if let best = report.top.first, let worst = report.top.last {
                let median = report.medianViews ?? 0
                let standsOut = median > 0 && Double(best.views) >= median * 2

                VStack(alignment: .leading, spacing: 14) {
                    outcome("Worked best", best, median: median, tint: .green)
                    Divider()
                    outcome("Did least well", worst, median: median, tint: .secondary)
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recommended next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if standsOut {
                            Text("Make variations of \"\(best.displayTitle)\". It got \(AnalyticsFormat.number(Double(best.views))) views, at least twice this campaign's median.")
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                planDraft = PlanDraft(brief: "Make variations of our best post in \(campaign.title), \"\(best.displayTitle)\": same structure and angle, new examples.")
                            } label: {
                                PrimaryButtonLabel(title: "Plan variations", systemImage: "calendar.badge.plus")
                            }
                            .primaryButtonStyle()
                            .padding(.top, 4)
                        } else {
                            Text("No post stands out clearly yet. Keep the campaign running and compare again after more posts.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .raisedCard()
            }
        }
    }

    private func details(_ video: AnalyticsReport.Video, median: Double) -> String {
        var parts: [String] = ["\(AnalyticsFormat.number(Double(video.views))) views"]
        if let rate = video.engagementRate {
            parts.append("\(AnalyticsFormat.percent(rate)) engagement")
        }
        if median > 0 {
            let ratio = Double(video.views) / median
            parts.append("\(ratio.formatted(.number.precision(.fractionLength(1))))× median")
        }
        if let format = video.format { parts.append(format.capitalized) }
        if let pillar = video.pillar { parts.append(pillar) }
        return parts.joined(separator: " · ")
    }

    private func outcome(_ label: String, _ video: AnalyticsReport.Video, median: Double, tint: Color) -> some View {
        HStack(spacing: 12) {
            AnalyticsThumbnail(url: video.coverUrl, width: 44, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(video.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(details(video, median: median))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
