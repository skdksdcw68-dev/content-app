import SwiftUI

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
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDiscard = false

    private var plan: ContentPlan? { session.plan }
    private var posts: [PlannedPost] { session.planPosts }

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
                List {
                    Section { PlanSummary(plan: plan, posts: posts) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    ForEach(days) { day in
                        Section {
                            ForEach(day.posts) { post in
                                PlannedPostRow(post: post, timezone: brandTimeZone)
                            }
                        } header: {
                            Text(dayHeading(day.id))
                        }
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
            } else {
                NoPlanYet()
            }
        }
        .navigationTitle(plan?.isRunning == true ? "Your plan" : "Proposed plan")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.refreshPlan() }
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

    private func approve() async {
        if await session.activatePlan() { dismiss() }
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

    private var scheduled: Int { posts.filter { $0.status == .scheduled }.count }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if !plan.title.isEmpty {
                    Text(plan.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(plan.isRunning
                     ? "Running. \(scheduled) of \(posts.count) posts have a time and the scheduler is counting toward them."
                     : "\(posts.count) posts written. Nothing is scheduled until you approve it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The honest caveat, said here rather than discovered later.
                // Approving this schedules the times; it does not make the
                // videos, because nothing in this app makes videos yet.
                Label {
                    Text("Approving sets the times. You still add the video for each post before it can go out.")
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
}

// MARK: - One post

private struct PlannedPostRow: View {
    let post: PlannedPost
    let timezone: TimeZone

    @State private var expanded = false

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

                if post.status == .scheduled {
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
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) { expanded.toggle() }
        }
        .accessibilityHint(expanded ? "Collapse details" : "Show what it films and why")
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
