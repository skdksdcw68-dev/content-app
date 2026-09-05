import SwiftUI

/// The command centre for today.
///
/// The order is the answer to "what do I need to know": what the app noticed,
/// how today is going, what is next, and how the work is landing. Anything
/// that needs a person is at the top; the full numbers are one tap down rather
/// than a tab of their own.
struct HomeView: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    InsightCard()
                    TodayCard()
                    UpcomingCard()
                    PerformanceCard()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
/// The accent appears here and almost nowhere else on the screen, which is
/// what makes it read as the AI layer rather than as decoration.
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

    /// Three is enough to know the shape of the week. The rest is Plan's job.
    private var preview: [ContentPost] {
        Array(store.upcomingPosts.prefix(3))
    }

    var body: some View {
        Card("Coming up", systemImage: "calendar") {
            if preview.isEmpty {
                Text("Nothing planned yet. Generate a week in Plan, or ask for something specific in Create.")
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

// MARK: - Performance

/// The summary that replaced the Insights tab. Two numbers, the one topic
/// worth knowing about, and a way through to the full breakdown -- which is
/// about as much analytics as anyone wants on the screen they open first.
private struct PerformanceCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        Card("Performance", systemImage: "chart.line.uptrend.xyaxis") {
            if store.publishedCount == 0 {
                Text("Nothing has been published yet, so there is nothing to measure.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        MetricTile(
                            label: "Views",
                            value: (store.totalViews ?? 0).formatted(.number.notation(.compactName)),
                            caption: "\(store.publishedCount) posted",
                            isAvailable: store.totalViews != nil
                        )
                        MetricTile(
                            label: "Engagement",
                            value: (store.averageEngagement ?? 0).formatted(.percent.precision(.fractionLength(1))),
                            caption: "likes, saves, shares",
                            isAvailable: store.averageEngagement != nil
                        )
                    }

                    if let top = store.topTopics.first {
                        Text("\(top.name) is your strongest subject at \(top.views.formatted(.number.notation(.compactName))) views.")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    NavigationLink {
                        InsightsView()
                    } label: {
                        HStack {
                            Text("All insights")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview {
    let store = ContentStore()
    return HomeView()
        .environment(store)
        .task { await store.connect() }
}
