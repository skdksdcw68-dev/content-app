import SwiftUI

/// The plan as a board: what the campaign is for, and every post in it with
/// its video, words, time and stage. Tapping a post shows exactly what will be
/// published before anything is approved.
///
/// Stages come from `post_board()` -- the rows the pipeline writes -- so a post
/// only says Published when TikTok has said so.
struct PlanView: View {
    /// What the writer reported about the month it just produced. Present only
    /// when this screen was pushed straight after generating.
    var notice: PlanProposal?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    enum Filter: String, CaseIterable, Hashable {
        case all, yours, queued, published, attention

        var title: String {
            switch self {
            case .all:       "All"
            case .yours:     "Your review"
            case .queued:    "Queued"
            case .published: "Published"
            case .attention: "Needs attention"
            }
        }

        func matches(_ post: BoardPost) -> Bool {
            switch self {
            case .all:       true
            case .yours:     post.stage == .readyForReview
            case .queued:    post.stage == .readyToPublish || post.stage.isWorking
            case .published: post.stage == .published
            case .attention: post.stage == .needsAttention || post.stage == .approved
            }
        }
    }

    @State private var board: [BoardPost] = []
    @State private var loaded = false
    @State private var filter: Filter = .all
    @State private var confirmingDiscard = false
    @State private var confirmingDelete = false
    @State private var uploading = false
    @State private var approvingPlan = false

    private var plan: ContentPlan? { session.plan }

    private var timezone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    private struct PlanDay: Identifiable {
        let id: Date
        let posts: [BoardPost]
    }

    private var days: [PlanDay] {
        var calendar = Calendar.current
        calendar.timeZone = timezone
        let shown = board.filter { filter.matches($0) }
        let grouped = Dictionary(grouping: shown) { (post: BoardPost) -> Date in
            guard let when = post.when else { return .distantFuture }
            return calendar.startOfDay(for: when)
        }
        let sortedKeys = grouped.keys.sorted()
        return sortedKeys.map { key in
            let posts = (grouped[key] ?? []).sorted { ($0.when ?? .distantFuture) < ($1.when ?? .distantFuture) }
            return PlanDay(id: key, posts: posts)
        }
    }

    var body: some View {
        Group {
            if let plan {
                month(plan)
            } else {
                NoPlanYet()
            }
        }
        .navigationTitle(plan?.isProposal == true ? "Proposed plan" : "Plan")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { uploading = true } label: {
                    Image(systemName: "video.badge.plus")
                }
                .accessibilityLabel("Upload a video")
                .disabled(plan?.isProposal == true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete plan", systemImage: "trash")
                    }
                    .disabled(plan == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .alert("Delete this plan?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    if await session.deletePlan() { await reload() }
                }
            }
        } message: {
            Text("Posts that already went out stay where they are. Everything still to come is dropped, and nothing more is made or posted.")
        }
        .navigationDestination(isPresented: $uploading) { UploadFlowView() }
        .refreshable { await reload() }
        .task(id: plan?.id) { await reload() }
        .task(id: isMoving) { await watch() }
        .confirmationDialog("Throw this plan away?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                Task {
                    await session.discardPlan()
                    dismiss()
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Nothing has been scheduled yet, so nothing is lost except the writing.")
        }
    }

    private func month(_ plan: ContentPlan) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                PlanHeader(plan: plan, board: board, timezone: timezone)

                // Only the import note. The warnings that used to sit here
                // ("asking for something you have not written down", "posts
                // thrown away") are gone: the writer now takes a second pass
                // at any slot it could not fill honestly, so the month comes
                // back whole instead of annotated (Abel, 23 Sep 2026).
                if let notice, notice.imported == true {
                    WritingNotice(notice: notice)
                }

                if loaded && !board.isEmpty {
                    filters
                }

                boardBody(plan)
            }
            .screenGutter()
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if plan.isProposal {
                DecisionBar(
                    working: approvingPlan,
                    approve: { Task { await approve() } },
                    discard: { confirmingDiscard = true }
                )
            }
        }
    }

    @ViewBuilder
    private func boardBody(_ plan: ContentPlan) -> some View {
        if !loaded {
            SkeletonCard(height: 150)
            SkeletonCard(height: 150)
        } else if board.isEmpty {
            emptyBoard(plan)
        } else if days.isEmpty {
            Text("Nothing here right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else {
            ForEach(days) { day in
                dayBlock(day)
            }
        }
    }

    private func count(_ option: Filter) -> Int {
        option == .all ? board.count : board.filter { option.matches($0) }.count
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases.filter { $0 == .all || count($0) > 0 }, id: \.self) { option in
                    filterChip(option)
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func filterChip(_ option: Filter) -> some View {
        let on = filter == option
        let label = option == .all ? option.title : "\(option.title) · \(count(option))"
        return Button {
            withAnimation(.snappy(duration: 0.2)) { filter = option }
        } label: {
            Text(label)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(on ? Color.accentColor : Color.track, in: Capsule())
                .foregroundStyle(on ? Theme.onAccent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func dayBlock(_ day: PlanDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dayHeading(day.id))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            ForEach(day.posts) { post in
                NavigationLink {
                    PostDetailView(postID: post.id)
                } label: {
                    PostPreviewCard(post: post, timezone: timezone)
                }
                .buttonStyle(SoftPressStyle())
            }
        }
    }

    private func emptyBoard(_ plan: ContentPlan) -> some View {
        VStack(spacing: 12) {
            EmptyArt(name: "empty-plan", size: 110)
            Text("No posts in this plan yet")
                .font(.headline)
            Text("Upload one of your videos and Autocast writes the post, puts it at the next open time and checks it with TikTok.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { uploading = true } label: {
                PrimaryButtonLabel(title: "Upload a video", systemImage: "video.badge.plus")
            }
            .primaryButtonStyle()
            .disabled(plan.isProposal)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .raisedCard(radius: Style.rowCard)
    }

    // MARK: - Loading

    private func reload() async {
        await session.refreshPlan()
        guard let plan = session.plan else {
            board = []
            loaded = true
            return
        }
        do {
            board = try await session.board(plan: plan.id)
        } catch {
            session.lastError = session.readableMessage(error)
        }
        loaded = true
    }

    /// True while anything on the board is being made, published or checked,
    /// or is due within ten minutes.
    private var isMoving: Bool {
        board.contains { post in
            post.stage.isWorking
                || (post.stage == .readyToPublish && (post.when ?? .distantFuture).timeIntervalSinceNow < 600)
        }
    }

    private func watch() async {
        guard isMoving else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if let plan = session.plan, let fresh = try? await session.board(plan: plan.id) {
                board = fresh
            }
            if !isMoving { return }
        }
    }

    private func approve() async {
        approvingPlan = true
        defer { approvingPlan = false }
        if await session.activatePlan() { await reload() }
    }

    private func dayHeading(_ date: Date) -> String {
        if date == .distantFuture { return "No time yet" }
        var calendar = Calendar.current
        calendar.timeZone = timezone
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date)
    }
}

// MARK: - Header

/// Name, objective, platform, duration, frequency, pillars, and where the
/// posts are: the campaign at a glance.
private struct PlanHeader: View {
    let plan: ContentPlan
    let board: [BoardPost]
    let timezone: TimeZone

    private var pillars: [String] {
        var seen: [String] = []
        for post in board {
            if let name = post.pillar, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private var objective: String {
        if let objective = plan.objective, !objective.isEmpty { return objective }
        return plan.brief
    }

    private var startLabel: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timezone
        guard let date = parser.date(from: plan.startsOn) else { return plan.startsOn }
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }

    private var platforms: String {
        var names: [String] = []
        for value in plan.platforms ?? ["tiktok"] {
            switch value {
            case "reels":  names.append("Instagram")
            case "shorts": names.append("YouTube")
            default:       names.append("TikTok")
            }
        }
        return names.joined(separator: " · ")
    }

    private var statusText: String {
        switch plan.status {
        case .active:           return "Running"
        case .paused:           return "Paused"
        case .draft, .proposed: return "Waiting for your approval"
        default:                return plan.status.rawValue.capitalized
        }
    }

    private var statusTint: Color {
        switch plan.status {
        case .active: return .green
        case .paused, .draft, .proposed: return .orange
        default: return .secondary
        }
    }

    private func tally(_ test: (BoardPost) -> Bool) -> String {
        String(board.filter(test).count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(statusTint.opacity(0.12), in: Capsule())

            Text(plan.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            if !objective.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Objective").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(objective).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }

            FlowLayout(spacing: 6) {
                FactChip(text: platforms, symbol: "music.note")
                FactChip(text: "\(plan.days) days from \(startLabel)", symbol: "calendar")
                FactChip(text: "\(plan.postsPerDay) a day", symbol: "repeat")
                ForEach(pillars, id: \.self) { name in
                    FactChip(text: name, symbol: "square.stack")
                }
            }

            if !board.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    stat(String(board.count), "posts")
                    stat(tally { $0.stage == .readyForReview }, "for review")
                    stat(tally { $0.stage == .readyToPublish || $0.stage.isWorking }, "queued")
                    stat(tally { $0.stage == .published }, "published")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.bigCard)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The decision

/// Pinned rather than placed at the end of the list. Thirty days is a long
/// scroll, and burying the only two actions at the bottom of it means deciding
/// requires a journey.
private struct DecisionBar: View {
    let working: Bool
    let approve: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(role: .destructive, action: discard) {
                Text("Discard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(working)

            Button(action: approve) {
                HStack(spacing: 6) {
                    if working {
                        ProgressView().controlSize(.small).tint(Theme.onAccent)
                    }
                    Text(working ? "Scheduling…" : "Approve plan")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .disabled(working)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct NoPlanYet: View {
    var body: some View {
        VStack(spacing: 10) {
            EmptyArt(name: "empty-plan", size: 140)
                .padding(.bottom, 6)

            Text("No plan yet")
                .font(.title3.bold())

            Text("Ask for a month and it gets written here, with a time against every day, for you to look over before anything is scheduled.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
    }
}

// MARK: - What the writer wants you to know

/// Why the month is short, when it is.
///
/// The failure this reports is specific and would otherwise be invisible: a
/// theme like "Reader stories: what people wrote in" is a promise the account
/// cannot keep with no quotes on file, so the writer either invents one -- which
/// is caught and thrown away -- or writes around it. Either way the person sees
/// fewer posts than they asked for and deserves to know which theme did it.
private struct WritingNotice: View {
    let notice: PlanProposal

    var body: some View {
        Card(notice.imported == true ? "From your file" : "Worth knowing",
             systemImage: notice.imported == true ? "doc.text" : "exclamationmark.bubble") {
            if notice.imported == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text(importLine)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your words, as written — nothing was added. Times from the file are kept; the rest use your usual hours. Check them, then approve.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let themes = notice.unsupportedThemes, !themes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(themes.count == 1
                         ? "\(themes[0]) is asking for something you have not written down."
                         : "\(themes.joined(separator: " and ")) are asking for things you have not written down.")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("It will not make up a customer quote or a change you never mentioned, so it writes around those days instead. Add what is true under You → Your brand, or turn the theme off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let invented = notice.invented, invented > 0 {
                Label(
                    invented == 1
                        ? "One post was thrown away for inventing something."
                        : "\(invented) posts were thrown away for inventing something.",
                    systemImage: "trash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let facts = notice.factsUsed, facts < 4 {
                Label(
                    "It had \(facts) thing\(facts == 1 ? "" : "s") to go on. Four or five makes a visible difference.",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var importLine: String {
        let found = notice.found ?? notice.planned
        let days = "\(notice.days) day\(notice.days == 1 ? "" : "s")"
        if notice.dropped > 0 {
            return "\(notice.planned) of \(found) posts placed across \(days). \(notice.dropped) had no free slot."
        }
        return "\(notice.planned) post\(notice.planned == 1 ? "" : "s") placed across \(days)."
    }
}
