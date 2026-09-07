import SwiftUI
import PhotosUI

/// The month, before you agree to it.
///
/// This is the screen the product is for. A list of ideas is a notepad; a month
/// with a date and a time against every line is a thing that can run without
/// you -- and the only honest way to hand someone an unattended publish key is
/// to show them, in full, exactly what it intends to do first.
///
/// So every post shows four things and not three: what is said, what is shown,
/// when it goes out, and why it exists. The last one is the one that makes this
/// reviewable rather than merely long.
struct PlanView: View {
    /// What the writer reported about the month it just produced. Present only
    /// when this screen was pushed straight after generating -- reaching it
    /// from Home shows the plan without the commentary, because by then the
    /// interesting question is what is going out, not how it was written.
    var notice: PlanProposal?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDiscard = false
    @State private var addingTo: PlannedPost?
    @State private var pickingVideo = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var approving: PendingPost?

    private var plan: ContentPlan? { session.plan }
    private var posts: [PlannedPost] { session.planPosts }

    /// The queue entry each planned post produced, if it has produced one yet.
    /// Built once per redraw rather than searched per row, so a thirty-day plan
    /// does not do thirty linear scans every time anything changes.
    private var queued: [UUID: PendingPost] {
        Dictionary(session.posts.map { ($0.postId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Grouped by the day they fall on rather than by `day_index`, because two
    /// posts a day should sit under one heading.
    ///
    /// A named type rather than the tuple this obviously wants to be: Swift key
    /// paths cannot address tuple elements, so `ForEach(days, id: \.key)` does
    /// not compile.
    private struct PlanDay: Identifiable {
        let id: Date
        let posts: [PlannedPost]
    }

    private var days: [PlanDay] {
        let calendar = calendarInBrandTime()
        let grouped = Dictionary(grouping: posts) { post in
            post.scheduledFor.map { calendar.startOfDay(for: $0) } ?? .distantPast
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { PlanDay(id: $0.key, posts: $0.value) }
    }

    var body: some View {
        Group {
            if let plan {
                month(plan)
            } else {
                NoPlanYet()
            }
        }
        .navigationTitle(plan?.isRunning == true ? "Your plan" : "Proposed plan")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await session.refreshPlan()
            await session.refreshPosts()
        }
        .photosPicker(isPresented: $pickingVideo, selection: $pickerItem, matching: .videos)
        .task(id: pickerItem) { await attachPicked() }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
        .confirmationDialog(
            "Throw this plan away?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
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

    // MARK: - The list
    //
    // Split into three small functions rather than one nested expression. The
    // one-expression version failed to compile at all: "the compiler is unable
    // to type-check this expression in reasonable time". A List holding a
    // ForEach holding a Section holding a ForEach holding a view with two
    // trailing closures is more than the type checker will attempt, and it says
    // so only after four minutes on a build machine.

    private func month(_ plan: ContentPlan) -> some View {
        List {
            Section {
                PlanSummary(plan: plan, posts: posts, withVideo: withVideo)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if let notice, notice.needsAttention {
                Section {
                    WritingNotice(notice: notice)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            ForEach(days) { day in
                section(day, running: plan.isRunning)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if plan.isProposal {
                DecisionBar(
                    working: session.isWorking,
                    approve: { Task { await approve() } },
                    discard: { confirmingDiscard = true }
                )
            }
        }
    }

    private func section(_ day: PlanDay, running: Bool) -> some View {
        Section {
            ForEach(day.posts) { post in
                row(post, running: running)
            }
        } header: {
            Text(dayHeading(day.id))
        }
    }

    private func row(_ post: PlannedPost, running: Bool) -> some View {
        PlannedPostRow(
            post: post,
            timezone: brandTimeZone,
            queued: queued[post.id],
            // A proposal has nothing to attach media to yet. Agreeing to the
            // month comes first.
            canAttach: running,
            // Offered only when there is something to generate with. A button
            // whose only outcome is "connect a generator first" is a button
            // that teaches people to distrust the buttons.
            canGenerate: session.hasWorkingGenerator,
            addVideo: {
                addingTo = post
                pickingVideo = true
            },
            generate: { Task { await session.generateMedia(for: post.id) } },
            review: { approving = queued[post.id] }
        )
    }

    private var withVideo: Int {
        let byPost = queued
        return posts.reduce(into: 0) { total, post in
            if byPost[post.id] != nil { total += 1 }
        }
    }

    private func approve() async {
        if await session.activatePlan() { dismiss() }
    }

    /// Puts a video against the day it was picked for.
    ///
    /// The caption comes from what the plan already wrote, so filling in a slot
    /// is one gesture rather than a picker followed by a form. It can still be
    /// changed on the approval sheet, which is where every other choice about
    /// this post is made.
    private func attachPicked() async {
        guard let pickerItem, let target = addingTo else { return }
        defer {
            self.pickerItem = nil
            addingTo = nil
        }

        do {
            guard let movie = try await pickerItem.loadTransferable(type: Movie.self) else { return }
            let data = try Data(contentsOf: movie.url)
            try? FileManager.default.removeItem(at: movie.url)

            await session.addVideo(
                data: data,
                filename: movie.url.lastPathComponent,
                caption: target.script,
                postID: target.id
            )
        } catch {
            session.lastError = "That video could not be read."
        }
    }

    // MARK: - Dates in the brand's own zone

    private var brandTimeZone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    private func calendarInBrandTime() -> Calendar {
        var calendar = Calendar.current
        calendar.timeZone = brandTimeZone
        return calendar
    }

    /// "Today", "Tomorrow", then the date. The first two days are the ones a
    /// person is actually deciding about.
    private func dayHeading(_ date: Date) -> String {
        let calendar = calendarInBrandTime()
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }

        let formatter = DateFormatter()
        formatter.timeZone = brandTimeZone
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date)
    }
}

// MARK: - Summary

private struct PlanSummary: View {
    let plan: ContentPlan
    let posts: [PlannedPost]
    /// How many days already have something to publish.
    let withVideo: Int

    private var waiting: Int { max(0, posts.count - withVideo) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if !plan.title.isEmpty {
                    Text(plan.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(plan.isRunning
                     ? "Running. \(withVideo) of \(posts.count) days have a video."
                     : "\(posts.count) posts written. Nothing is scheduled until you approve it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The honest caveat, said here rather than discovered later.
                // Approving sets the times; it does not make the videos,
                // because nothing in this app makes videos yet.
                Label {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var caveat: String {
        guard plan.isRunning else {
            return "Approving sets the times. Each day still needs a video before it can go out."
        }
        if waiting == 0 {
            return "Every day has a video. Approved ones go out on their own."
        }
        return "\(waiting) still need a video. Make it or add your own, approve it once, and it posts itself at the time shown."
    }
}

// MARK: - One post

private struct PlannedPostRow: View {
    let post: PlannedPost
    let timezone: TimeZone
    /// The queue entry this day produced, once a video has been attached to it.
    let queued: PendingPost?
    let canAttach: Bool
    let canGenerate: Bool
    let addVideo: () -> Void
    let generate: () -> Void
    let review: () -> Void

    @State private var expanded = false

    /// The planner does not carry the failure text, so this says what is true
    /// generally rather than inventing a specific reason.
    private var failureNote: String {
        "That did not come out. Try again, or add your own video."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(time)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)

                if let pillar = post.pillar?.name {
                    Text(pillar)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.softAccent, in: Capsule())
                }

                Spacer(minLength: 0)

                if post.status == .scheduled && queued == nil {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(post.hook)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if !post.script.isEmpty {
                Text(post.script)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if expanded {
                if !post.concept.isEmpty {
                    Detail(icon: "video", title: "Shows", text: post.concept)
                }
                if !post.rationale.isEmpty {
                    Detail(icon: "quote.opening", title: "Why", text: post.rationale)
                }
            }

            // Where this day actually stands. Until there is a video there is
            // nothing to publish, and the row should say that rather than
            // looking finished because it has words in it.
            if canAttach {
                action
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) { expanded.toggle() }
        }
        .accessibilityHint(expanded ? "Collapse details" : "Show what it films and why")
    }

    @ViewBuilder
    private var action: some View {
        if let queued {
            if queued.needsYou {
                Button(action: review) {
                    Label("Approve it", systemImage: "hand.raised")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                // A row inside a List already has a tap; a button inside it
                // needs its own hit test or the row swallows the press.
                .buttonBorderShape(.capsule)
            } else {
                Label(queued.statusLine, systemImage: statusSymbol(queued))
                    .font(.caption)
                    .foregroundStyle(queued.state == .failed ? Color.red : Color.secondary)
            }
        } else if post.status == .sourcing {
            // Minutes, not seconds, and it finishes without the app open. The
            // row says which of those is happening rather than showing a
            // spinner that looks like the screen is stuck.
            Label("Being made — this takes a few minutes", systemImage: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if post.status == .failed {
            Label(failureNote, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                if canGenerate {
                    Button(action: generate) {
                        Label("Make it", systemImage: "wand.and.stars")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
                }

                Button(action: addVideo) {
                    Label(canGenerate ? "Use my own" : "Add video", systemImage: "video.badge.plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
            }
        }
    }

    private func statusSymbol(_ queued: PendingPost) -> String {
        switch queued.state {
        case .published: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .pending:   return "clock"
        default:         return "paperplane"
        }
    }

    private var time: String {
        guard let when = post.scheduledFor else { return "--:--" }
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: when)
    }
}

/// The property is `text`, not `body`: a View cannot have a stored property
/// called body, and the compiler's complaint about it is not obvious.
private struct Detail: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(working ? "Scheduling…" : "Approve plan")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
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
        ContentUnavailableView {
            Label("No plan yet", systemImage: "calendar")
        } description: {
            Text("Ask in Chat for a month of content and it will be written here for you to look over.")
        }
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
        Card("Worth knowing", systemImage: "exclamationmark.bubble") {
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
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
