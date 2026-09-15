import SwiftUI

/// The intelligence centre: what happened, why, what is changing, and what
/// Autocast should do next.
///
/// Abel's brief (15 Sep 2026) asked for it not to be a statistics dashboard,
/// so the page runs in that order -- overview, trend, top content, what was
/// learned, what to do -- with detail one tap deeper (a post, a campaign).
///
/// Three independent loads, so a slow section never holds the page: the report
/// (overview, trend, top content, timing, campaigns), the learning (findings
/// and recommendations), and Autopilot. All read what the server computed from
/// real readings; nothing here makes a number up, and a metric the platform
/// does not give says so.
struct AnalyticsView: View {
    @Environment(AppSession.self) private var session

    // The range survives leaving and coming back, custom dates included.
    @AppStorage("analytics.range") private var rangeKey = "28"
    @AppStorage("analytics.customFrom") private var customFrom: Double = 0
    @AppStorage("analytics.customTo") private var customTo: Double = 0

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
            let days = Int(rangeKey) ?? 28
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                controls

                if session.connections.isEmpty {
                    noConnection
                        .padding(.top, 20)
                } else if let report {
                    content(report)
                } else if let reportFailed {
                    RetryNotice(title: reportFailed) { reloads += 1 }
                        .padding(.top, 20)
                } else {
                    VStack(spacing: 12) {
                        SkeletonCard(height: 120)
                        SkeletonCard(height: 190)
                        SkeletonRow()
                        SkeletonRow()
                    }
                    .padding(.top, 20)
                }
            }
            .screenGutter()
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Analytics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { exportMenu }
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

    // MARK: - Pieces

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AnalyticsRangeBar(rangeKey: $rangeKey, customLabel: customLabel) {
                    showingCustom = true
                }
            }
            if !session.connections.isEmpty {
                HStack(spacing: 8) {
                    AnalyticsFilterMenu(
                        platforms: connectedPlatforms,
                        filters: report?.filters,
                        platform: $platform,
                        format: $format,
                        pillarId: $pillarId,
                        planId: $planId
                    )
                    Spacer(minLength: 8)
                    if let live {
                        Text("@\(live.username)\(live.followers.map { " · \(AnalyticsFormat.number(Double($0))) followers" } ?? "")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ report: AnalyticsReport) -> some View {
        AnalyticsSectionTitle(title: "Overview", subtitle: overviewSubtitle(report))
            .padding(.top, 20)
            .entrance(0)

        if report.status == "no_videos" {
            AnalyticsNotice(
                symbol: "play.rectangle",
                title: "No public videos yet",
                detail: "TikTok shares numbers for public videos only. Once one is public, Autocast reads it within 6 hours and this page fills in."
            )
            .padding(.top, 12)
        }

        MetricGrid(report: report, selected: $metric)
            .padding(.top, 12)
            .entrance(1)

        TrendCard(report: report, metric: metric)
            .padding(.top, 14)
            .entrance(2)

        TopContentSection(report: report)
            .padding(.top, 28)

        LearnedSection(learning: learning, failed: learningFailed, videos: report.videos) {
            Task { await loadLearning() }
        }
        .padding(.top, 28)

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
        .padding(.top, 28)

        BestTimeSection(bestTime: report.bestTime, timezone: report.timezone)
            .padding(.top, 28)

        CompareSection(breakdowns: report.breakdowns)
            .padding(.top, 28)

        CampaignsSection(report: report, platform: platform)
            .padding(.top, 28)

        AutopilotSection(report: autopilot, failed: autopilotFailed) {
            Task { await loadAutopilot() }
        }
        .padding(.top, 28)

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
        .padding(.top, 28)
    }

    private func overviewSubtitle(_ report: AnalyticsReport) -> String {
        let current = AnalyticsFormat.range(query.from, query.to)
        let previous: String
        if let from = AnalyticsDay.parse(report.range.prevFrom), let to = AnalyticsDay.parse(report.range.prevTo) {
            previous = " vs \(AnalyticsFormat.range(from, to))"
        } else {
            previous = ""
        }
        var line = current + previous
        if let started = report.historyStartDate, started > query.from {
            line += ". Autocast started reading on \(AnalyticsFormat.day(started)), so earlier days may be incomplete."
        }
        return line
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
            NavigationLink { ProfileView() } label: {
                PrimaryButtonLabel(title: "Connect TikTok")
            }
            .primaryButtonStyle()
            .padding(.top, 6)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .raisedCard()
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
        .disabled(exporting || report == nil || session.connections.isEmpty)
        .accessibilityLabel("Export analytics")
    }

    // MARK: - Loading

    private func loadReport() async {
        guard !session.connections.isEmpty, session.brand != nil else { return }
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
        guard !session.connections.isEmpty, session.brand != nil else { return }
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
        guard !session.connections.isEmpty, session.brand != nil else { return }
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
        guard !session.connections.isEmpty else { return }
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
