import SwiftUI

/// The command centre for today.
///
/// The order of the cards is the answer to "what do I need to know": what the
/// app noticed, how today is going, what is next, what to do about it, and how
/// the last few did. Anything that needs a person is at the top.
struct HomeView: View {
    var onCreate: () -> Void

    @Environment(ContentStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    InsightCard()
                    TodayCard()
                    UpcomingCard()
                    QuickCreateCard(onCreate: onCreate)
                    RecentPerformanceCard()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                // The Create button floats over this scroll view, so the last
                // card needs room or it cannot be reached.
                .padding(.bottom, Theme.createButtonClearance)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Home")
            .navigationDestination(for: ContentPost.self) { PostDetailView(post: $0) }
            .refreshable { await store.refresh() }
        }
    }
}

// MARK: - What the app noticed

/// One line, in the app's own words, about the thing most worth knowing.
/// The accent appears here and nowhere else on the screen, which is what makes
/// it read as the AI layer rather than as decoration.
private struct InsightCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        let insight = store.homeInsight

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.softAccent, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Autocast noticed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(insight.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Today

private struct TodayCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        Card("Today", systemImage: "sun.max") {
            if let completion = store.todayCompletion {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(store.todayPostedCount) of \(store.todaysPosts.count) out")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(completion.formatted(.percent.precision(.fractionLength(0))))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }

                    ProportionBar(fraction: completion)

                    ForEach(store.todaysPosts) { post in
                        NavigationLink(value: post) {
                            TodayRow(post: post)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Nothing is scheduled for today.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

private struct TodayRow: View {
    let post: ContentPost

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: post.status.symbolName)
                .font(.caption)
                .foregroundStyle(StatusBadge.tint(for: post.status))
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(post.hook)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let at = post.postedAt ?? post.scheduledFor {
                Text(at.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Upcoming

private struct UpcomingCard: View {
    @Environment(ContentStore.self) private var store

    /// Three is enough to know the shape of the week. The rest is Plan's job,
    /// and the link at the bottom says so.
    private var preview: [ContentPost] {
        Array(store.upcomingPosts.prefix(3))
    }

    var body: some View {
        Card("Coming up", systemImage: "calendar") {
            if preview.isEmpty {
                Text("Nothing planned yet. Generate a week in Plan, or ask for something with Create.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) {
                    ForEach(preview) { post in
                        NavigationLink(value: post) {
                            UpcomingRow(post: post)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct UpcomingRow: View {
    let post: ContentPost
    @Environment(ContentStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                StatusBadge(status: post.status)
                Spacer(minLength: 4)
                if let at = post.scheduledFor {
                    Text(at.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }

            Text(post.hook)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // The rationale, not the script. What matters before you open it
            // is why it exists at all.
            Text(post.rationale)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Quick create

private struct QuickCreateCard: View {
    var onCreate: () -> Void

    var body: some View {
        Card("Make something", systemImage: "wand.and.stars") {
            Text("Ask for a specific video, post or campaign instead of waiting for the next planned one.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onCreate) {
                Label("Create", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Recent performance

private struct RecentPerformanceCard: View {
    @Environment(ContentStore.self) private var store

    private var recent: [ContentPost] {
        Array(store.recentlyPosted.prefix(2))
    }

    var body: some View {
        Card("Recent performance", systemImage: "chart.line.uptrend.xyaxis") {
            if recent.isEmpty {
                Text("Nothing has been published yet, so there is nothing to measure.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) {
                    ForEach(recent) { post in
                        NavigationLink(value: post) {
                            RecentRow(post: post)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct RecentRow: View {
    let post: ContentPost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(post.hook)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .multilineTextAlignment(.leading)

            HStack(spacing: 14) {
                if let views = post.views {
                    Label(views.formatted(.number.notation(.compactName)), systemImage: "eye")
                }
                if let likes = post.likes {
                    Label(likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                }
                if let rate = post.engagementRate {
                    Text(rate.formatted(.percent.precision(.fractionLength(1))))
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(Color.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#Preview {
    let store = ContentStore()
    return HomeView(onCreate: {})
        .environment(store)
        .task { await store.connect() }
}
