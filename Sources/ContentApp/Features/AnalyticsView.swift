import SwiftUI
import TipKit

/// Analytics, laid out the way TikTok Studio lays it out (Abel's screenshots,
/// 17 Sep 2026) -- tabs that stay put while the page scrolls, the range pills
/// under them, then cards -- in Remi's black and white, with one tab Studio
/// does not have: what Autocast learned and what it would do next.
///
/// Every figure comes from the server's report, computed from readings that
/// were actually taken. What TikTok only gives Business accounts says so in
/// its own card instead of showing dashes.
///
/// Three independent loads, so a slow section never holds the page.
struct AnalyticsView: View {
    @Environment(AppSession.self) private var session

    enum Page: String, CaseIterable, Hashable {
        case overview, content, viewers, followers, autocast

        var title: String {
            switch self {
            case .overview:  "Overview"
            case .content:   "Content"
            case .viewers:   "Viewers"
            case .followers: "Followers"
            case .autocast:  "Insights"
            }
        }
    }

    // The range survives leaving and coming back, custom dates included.
    @AppStorage("analytics.range") private var rangeKey = "7"
    @AppStorage("analytics.customFrom") private var customFrom: Double = 0
    @AppStorage("analytics.customTo") private var customTo: Double = 0

    @State private var page: Page = .overview
    @State private var platform: String?
    @State private var format: String?
    @State private var pillarId: UUID?
    @State private var planId: UUID?
    @State private var metric: AnalyticsMetric = .views

    @State private var report: AnalyticsReport?
    @State private var reportFailed: String?
    @State private var learning: LearningState?
    @State private var learningFailed = false
    @State private var autopilot: AutopilotReport?
    @State private var autopilotFailed = false
    @State private var live: Metrics?
    /// Bumped after a fresh reading from TikTok, so every section reloads.
    @State private var reloads = 0

    @State private var showingCustom = false
    @State private var exporting = false
    @State private var exported: ExportedFile?
    @State private var acting: UUID?
    @State private var planDraft: PlanDraft?
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false
    @State private var ask: AnalyticsAsk?
    @State private var applied = 0
    @State private var tips = TipGroup(.ordered) {
        PostsLibraryTip()
        RangeTip()
        FilterTip()
        ExportTip()
    }

    private struct LoadKey: Equatable {
        let query: AnalyticsQuery
        let brand: UUID?
        let reloads: Int
    }

    private var query: AnalyticsQuery {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var from: Date
        var to = today
        if rangeKey == "custom", customFrom > 0, customTo > 0 {
            from = Date(timeIntervalSince1970: customFrom)
            to = Date(timeIntervalSince1970: customTo)
        } else {
            let days = Int(rangeKey) ?? 7
            from = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        }
        if from > to { from = to }
        return AnalyticsQuery(from: from, to: to, platform: platform, format: format, pillarId: pillarId, planId: planId)
    }

    private var loadKey: LoadKey {
        LoadKey(query: query, brand: session.brand?.id, reloads: reloads)
    }

    private var customLabel: String? {
        guard customFrom > 0, customTo > 0 else { return nil }
        return AnalyticsFormat.range(Date(timeIntervalSince1970: customFrom), Date(timeIntervalSince1970: customTo))
    }

    private var connectedPlatforms: [String] {
        report?.platforms ?? Array(Set(session.connections.map { $0.platform.rawValue })).sorted()
    }

    private var hasAccount: Bool { !session.connections.isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        if hasAccount {
                            AnalyticsRangeBar(rangeKey: $rangeKey, customLabel: customLabel) {
                                showingCustom = true
                            }
                            .padding(.horizontal, -Style.gutter)
                            .popoverTip(tips.currentTip as? RangeTip, arrowEdge: .top)
                        }
                        pageBody
                    }
                    .screenGutter()
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                } header: {
                    UnderlineTabs(items: Page.allCases, selection: $page) { $0.title }
                }
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Analytics")
        .toolbar {
            if hasAccount {
                // Your posts, as a profile grid -- top left, where Abel asked.
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { PostsLibraryView() } label: {
                        Image(systemName: "square.grid.3x3")
                    }
                    .accessibilityLabel("Your posts")
                    .popoverTip(tips.currentTip as? PostsLibraryTip, arrowEdge: .top)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AnalyticsFilterMenu(
                        platforms: connectedPlatforms,
                        filters: report?.filters,
                        platform: $platform,
                        format: $format,
                        pillarId: $pillarId,
                        planId: $planId
                    )
                    .popoverTip(tips.currentTip as? FilterTip, arrowEdge: .top)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    exportMenu
                        .popoverTip(tips.currentTip as? ExportTip, arrowEdge: .top)
                }
            }
        }
        // Saved numbers first, which is instant; then a fresh reading from
        // TikTok, after which every section reloads.
        .task(id: loadKey) { await loadReport() }
        .task(id: loadKey) { await loadLearning() }
        .task(id: loadKey) { await loadAutopilot() }
        .task(id: session.brand?.id) { await readLive() }
        .refreshable { await readLive() }
        .onChange(of: session.brand?.id) { _, _ in
            report = nil
            learning = nil
            autopilot = nil
            live = nil
            format = nil
            pillarId = nil
            planId = nil
        }
        .sheet(isPresented: $showingCustom) {
            CustomRangeSheet(
                start: customFrom > 0 ? Date(timeIntervalSince1970: customFrom) : query.from,
                end: customTo > 0 ? Date(timeIntervalSince1970: customTo) : query.to
            ) { start, end in
                customFrom = start.timeIntervalSince1970
                customTo = end.timeIntervalSince1970
                rangeKey = "custom"
            }
        }
        .sheet(item: $exported) { file in
            ExportedSheet(file: file)
        }
        .sheet(item: $planDraft, onDismiss: {
            if proposed != nil { showingPlan = true }
        }) { draft in
            NewPlanSheet(brief: draft.brief) { proposed = $0 }
        }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed)
        }
        .navigationDestination(item: $ask) { question in
            ChatView(opening: question.text)
        }
        .sensoryFeedback(.success, trigger: applied)
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageBody: some View {
        if !hasAccount {
            noConnection
        } else if let report {
            if let note = pageNote(report) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch page {
            case .overview:  overview(report)
            case .content:   content(report)
            case .viewers:   viewers(report)
            case .followers: followers(report)
            case .autocast:  insights(report)
            }
        } else if let reportFailed {
            RetryNotice(title: reportFailed) { reloads += 1 }
        } else {
            SkeletonCard(height: 220)
            SkeletonCard(height: 120)
        }
    }

    @ViewBuilder
    private func overview(_ report: AnalyticsReport) -> some View {
        if report.status == "no_videos" {
            AnalyticsNotice(
                symbol: "play.rectangle",
                title: "No public videos yet",
                detail: "TikTok shares numbers for public videos only. Once one is public, Autocast reads it within 6 hours."
            )
        }
        ViewsHeroCard(report: report, range: AnalyticsFormat.range(query.from, query.to))
            .entrance(0)
        KeyMetricsCard(
            report: report,
            metrics: [.views, .likes, .comments, .shares, .engagementRate, .followersGained],
            selected: $metric,
            subtitle: rangeLine(report)
        )
        .entrance(1)
        TopPostsPreview(report: report) {
            withAnimation(.snappy(duration: 0.25)) { page = .content }
        }
        .entrance(2)
        LearningProgressCard(videos: report.videos)
            .entrance(3)
        BusinessOnlyCard(
            title: "Reach, watch time and audience",
            detail: "Unique viewers, profile views, average watch time, traffic sources, gender, age and location."
        )
        .entrance(4)
    }

    @ViewBuilder
    private func content(_ report: AnalyticsReport) -> some View {
        PostsGridCard(report: report)
            .entrance(0)
        ViewsShareCard(report: report)
            .entrance(1)
        TopPostsCard(report: report)
            .entrance(2)
        CampaignsSection(report: report, platform: platform)
            .padding(.top, 8)
        allPostsLink
    }

    @ViewBuilder
    private func viewers(_ report: AnalyticsReport) -> some View {
        BusinessOnlyCard(
            title: "Total and new viewers",
            detail: "How many different people watched, and how many had never seen you before."
        )
        .entrance(0)
        BestTimeCard(bestTime: report.bestTime, timezone: report.timezone)
            .entrance(1)
        BusinessOnlyCard(
            title: "Viewer insights",
            detail: "Gender, age and locations of the people who watched."
        )
        .entrance(2)
    }

    @ViewBuilder
    private func followers(_ report: AnalyticsReport) -> some View {
        FollowersCard(
            report: report,
            total: live?.followers ?? report.followersTotal,
            subtitle: followersSubtitle(report)
        )
        .entrance(0)
        BusinessOnlyCard(
            title: "Follower insights",
            detail: "Gender, age and locations of your followers.",
            needsFollowers: true
        )
        .entrance(1)
        BusinessOnlyCard(
            title: "When followers are online",
            detail: "The hours of the day your followers are on TikTok."
        )
        .entrance(2)
    }

    @ViewBuilder
    private func insights(_ report: AnalyticsReport) -> some View {
        LearnedSection(learning: learning, failed: learningFailed, videos: report.videos) {
            Task { await loadLearning() }
        }
        RecommendationsSection(
            learning: learning,
            failed: learningFailed,
            busy: acting,
            act: { recommendation, action in Task { await act(recommendation, action) } },
            ask: { recommendation in
                ask = AnalyticsAsk(text: "Why do you recommend \"\(recommendation.title)\"? Show me the numbers behind it.")
            },
            retry: { Task { await loadLearning() } }
        )
        .padding(.top, 12)
        CompareSection(breakdowns: report.breakdowns)
            .padding(.top, 12)
        AutopilotSection(report: autopilot, failed: autopilotFailed) {
            Task { await loadAutopilot() }
        }
        .padding(.top, 12)
    }

    // MARK: - Pieces

    private func rangeLine(_ report: AnalyticsReport) -> String {
        let current = AnalyticsFormat.range(query.from, query.to)
        guard let from = AnalyticsDay.parse(report.range.prevFrom),
              let to = AnalyticsDay.parse(report.range.prevTo) else { return current }
        return "\(current) · vs \(AnalyticsFormat.range(from, to))"
    }

    private func followersSubtitle(_ report: AnalyticsReport) -> String {
        guard let live else { return rangeLine(report) }
        return "@\(live.username) · \(rangeLine(report))"
    }

    /// One quiet line when the page is narrowed or starts before the history.
    private func pageNote(_ report: AnalyticsReport) -> String? {
        var parts: [String] = []
        if report.filtered || platform != nil {
            parts.append("Filtered.")
        }
        if let started = report.historyStartDate, started > query.from {
            parts.append("Autocast started reading your numbers on \(AnalyticsFormat.day(started)); earlier days aren't counted.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var allPostsLink: some View {
        NavigationLink { PostsLibraryView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: Circle())
                Text("Your posts")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .raisedCard(radius: 18)
        }
        .buttonStyle(SoftPressStyle())
    }

    private var noConnection: some View {
        VStack(spacing: 10) {
            EmptyArt(name: "empty-analytics", size: 120)
            Text("Connect an account to see analytics")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("Views, what worked, what Autocast learned and what to post next, for every app you market.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink { ProfileView().pushedPage() } label: {
                PrimaryButtonLabel(title: "Connect TikTok")
            }
            .primaryButtonStyle()
            .padding(.top, 6)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .raisedCard(radius: 18)
    }

    private var exportMenu: some View {
        Menu {
            Button { Task { await export("csv") } } label: {
                Label("Export CSV", systemImage: "tablecells")
            }
            Button { Task { await export("pdf") } } label: {
                Label("Export PDF report", systemImage: "doc.richtext")
            }
        } label: {
            if exporting {
                BreathingDot(size: 8)
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(exporting || report == nil)
        .accessibilityLabel("Export analytics")
    }

    // MARK: - Loading

    private func loadReport() async {
        guard hasAccount, session.brand != nil else { return }
        do {
            let fresh = try await session.analyticsReport(query)
            guard !Task.isCancelled else { return }
            report = fresh
            reportFailed = nil
        } catch {
            guard !Task.isCancelled else { return }
            if report == nil { reportFailed = "Couldn't load analytics. \(error.localizedDescription)" }
        }
    }

    private func loadLearning() async {
        guard hasAccount, session.brand != nil else { return }
        do {
            let fresh = try await session.learning()
            guard !Task.isCancelled else { return }
            learning = fresh
            learningFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            if learning == nil { learningFailed = true }
        }
    }

    private func loadAutopilot() async {
        guard hasAccount, session.brand != nil else { return }
        do {
            let fresh = try await session.autopilotReport(from: query.from, to: query.to)
            guard !Task.isCancelled else { return }
            autopilot = fresh
            autopilotFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            if autopilot == nil { autopilotFailed = true }
        }
    }

    /// A reading straight from TikTok: saves history, relearns, then reloads.
    private func readLive() async {
        guard hasAccount else { return }
        live = await session.metrics()
        reloads += 1
    }

    private func act(_ recommendation: Recommendation, _ action: String) async {
        acting = recommendation.id
        defer { acting = nil }
        guard let outcome = await session.act(on: recommendation, action) else { return }
        if action == "apply" { applied += 1 }
        if action == "plan" {
            planDraft = PlanDraft(brief: outcome.brief ?? recommendation.title)
        }
        await loadLearning()
    }

    private func export(_ file: String) async {
        exporting = true
        defer { exporting = false }
        if let url = await session.exportAnalytics(query, as: file) {
            exported = ExportedFile(url: url)
        }
    }
}

/// The finished file, ready to share or save.
private struct ExportedSheet: View {
    let file: ExportedFile

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: file.url.pathExtension.lowercased() == "pdf" ? "doc.richtext.fill" : "tablecells.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.top, 24)
            Text(file.url.lastPathComponent)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("Your current range and filters.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ShareLink(item: file.url) {
                PrimaryButtonLabel(title: "Share or save", systemImage: "square.and.arrow.up")
            }
            .primaryButtonStyle()
        }
        .screenGutter()
        .padding(.bottom, 16)
        .presentationDetents([.height(280)])
    }
}
