import SwiftUI

/// The calendar: what is booked, when, and what is still empty.
///
/// Day, week and month are the same list over a wider window rather than three
/// different layouts. A month grid of coloured squares looks like a planner but
/// answers fewer questions than a list that says what each post is.
struct PlanView: View {
    /// How far ahead the list looks.
    enum Span: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case month = "Month"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .day:   return 1
            case .week:  return 7
            case .month: return 30
            }
        }
    }

    @Environment(ContentStore.self) private var store
    @State private var span: Span = .week

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Span", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

                Divider()

                if days.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Plan")
            .navigationDestination(for: ContentPost.self) { PostDetailView(post: $0) }
            .toolbar {
                generateMenu
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        PostListView()
                    } label: {
                        Label("All posts", systemImage: "list.bullet")
                    }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    // MARK: - Pieces

    private var list: some View {
        List {
            ForEach(days) { day in
                Section {
                    ForEach(day.posts) { post in
                        NavigationLink(value: post) {
                            PlanRow(post: post)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.skip(post)
                            } label: {
                                Label("Skip", systemImage: "trash")
                            }

                            // Moving a post is the most common edit on a
                            // calendar, so it is one swipe rather than a trip
                            // into the detail view.
                            Button {
                                moveByADay(post)
                            } label: {
                                Label("Later", systemImage: "arrow.right.to.line")
                            }
                            .tint(Theme.accent)
                        }
                        .swipeActions(edge: .leading) {
                            if post.isAwaitingApproval {
                                Button {
                                    store.approve(post)
                                } label: {
                                    Label("Approve", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                        }
                    }
                } header: {
                    PlanDayHeader(day: day)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing planned", systemImage: "calendar")
        } description: {
            Text(emptyStateMessage)
        } actions: {
            Button {
                Task { await store.generate(days: span.days) }
            } label: {
                if store.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Text(generateLabel(days: span.days))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isGenerating)
        }
    }

    private var generateMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Generate today") { generate(days: 1) }
                Button("Generate 7 days") { generate(days: 7) }
                Button("Generate 30 days") { generate(days: 30) }
            } label: {
                if store.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Generate", systemImage: "sparkles")
                }
            }
            .disabled(store.isGenerating)
        }
    }

    // MARK: - Data

    /// One entry per day that actually has something in it, soonest first.
    /// Empty days are left out rather than rendered as blank rows -- the count
    /// of empty days is what the Generate button is for.
    private var days: [PlanDay] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: span.days, to: start) else { return [] }

        let inRange = store.posts.filter { post in
            guard let date = post.postedAt ?? post.scheduledFor else { return false }
            return date >= start && date < end
        }

        return Dictionary(grouping: inRange) { post in
            calendar.startOfDay(for: post.postedAt ?? post.scheduledFor ?? Date())
        }
        .map { date, posts in
            PlanDay(
                id: date,
                posts: posts.sorted {
                    ($0.postedAt ?? $0.scheduledFor ?? .distantFuture)
                        < ($1.postedAt ?? $1.scheduledFor ?? .distantFuture)
                }
            )
        }
        .sorted { $0.id < $1.id }
    }

    private func generate(days: Int) {
        Task { await store.generate(days: days) }
    }

    /// Why the window is empty, which is a different sentence depending on
    /// whether the autopilot is even running.
    private var emptyStateMessage: String {
        guard store.settings.isOn else {
            return "Autopilot is off, so nothing is being planned. Turn it on in Profile, or generate a batch by hand."
        }
        let window = span.days == 1 ? "The next day is" : "The next \(span.days) days are"
        return "\(window) empty. Generate a batch to fill them."
    }

    private func generateLabel(days: Int) -> String {
        switch days {
        case 1:  return "Generate today"
        case 7:  return "Generate 7 days"
        default: return "Generate \(days) days"
        }
    }

    /// Pushes a post 24 hours out. The store refuses if that lands inside the
    /// quiet window, and sets `lastError` saying so.
    private func moveByADay(_ post: ContentPost) {
        guard let current = post.scheduledFor,
              let moved = Calendar.current.date(byAdding: .day, value: 1, to: current)
        else { return }
        store.reschedule(post, to: moved)
    }
}

/// One day's worth of the schedule.
struct PlanDay: Identifiable, Hashable {
    let id: Date
    let posts: [ContentPost]
}

private struct PlanDayHeader: View {
    let day: PlanDay

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(day.posts.count)")
                .monospacedDigit()
        }
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.id) { return "Today" }
        if calendar.isDateInTomorrow(day.id) { return "Tomorrow" }
        return day.id.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

private struct PlanRow: View {
    let post: ContentPost
    @Environment(ContentStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The time is the anchor on a calendar, so it leads the row and
            // is monospaced to keep the column straight.
            VStack(alignment: .leading, spacing: 2) {
                if let at = post.postedAt ?? post.scheduledFor {
                    Text(at.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                } else {
                    Text("--")
                        .font(.caption.weight(.medium))
                }
                Image(systemName: post.status.symbolName)
                    .font(.caption2)
                    .foregroundStyle(StatusBadge.tint(for: post.status))
                    .accessibilityLabel(post.status.displayName)
            }
            .frame(width: 58, alignment: .leading)
            .foregroundStyle(Color.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(post.hook)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if let pillar = store.pillar(for: post) {
                    Text(pillar.name)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }

                if post.isAwaitingApproval {
                    Text("Waiting on you")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.softAccent, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let store = ContentStore()
    return PlanView()
        .environment(store)
        .task { await store.connect() }
}
