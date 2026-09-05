import SwiftUI

/// What actually happened, and what the app thinks you should do about it.
///
/// Everything here is computed from posts that have been published. Nothing is
/// projected, and a metric the platform has not sent back reads as a dash --
/// an invented number in an analytics screen is worse than a missing one.
struct InsightsView: View {
    @Environment(ContentStore.self) private var store

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.publishedCount == 0 {
                    emptyState
                } else {
                    VStack(spacing: 16) {
                        metrics
                        RecommendationsCard()
                        TopicsCard()
                        HooksCard()
                        TimesCard()
                        FormatCard()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, Theme.createButtonClearance)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Insights")
            .navigationDestination(for: ContentPost.self) { PostDetailView(post: $0) }
            .refreshable { await store.refresh() }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            MetricTile(
                label: "Views",
                value: (store.totalViews ?? 0).formatted(.number.notation(.compactName)),
                caption: "\(store.publishedCount) posted",
                isAvailable: store.totalViews != nil
            )
            MetricTile(
                label: "Engagement",
                value: (store.averageEngagement ?? 0).formatted(.percent.precision(.fractionLength(1))),
                caption: "likes, saves and shares",
                isAvailable: store.averageEngagement != nil
            )
            MetricTile(
                label: "Saves",
                value: (store.totalSaves ?? 0).formatted(.number.notation(.compactName)),
                caption: "across all posts",
                isAvailable: store.totalSaves != nil
            )
            MetricTile(
                label: "Shares",
                value: (store.totalShares ?? 0).formatted(.number.notation(.compactName)),
                caption: "across all posts",
                isAvailable: store.totalShares != nil
            )
            // The platform does not return either of these on the endpoints
            // Autocast has access to. Shown rather than hidden, so the absence
            // is a stated fact instead of a gap that looks like a bug.
            MetricTile(
                label: "Followers",
                value: "0",
                caption: "not reported yet",
                isAvailable: false
            )
            MetricTile(
                label: "Clicks",
                value: "0",
                caption: "not reported yet",
                isAvailable: false
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing measured yet", systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text("Insights fill in once posts have gone out. Until then there is nothing here that would be true.")
        }
        .padding(.top, 60)
    }
}

// MARK: - Recommendations

private struct RecommendationsCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        let items = store.recommendations
        if !items.isEmpty {
            Card("What to do next", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.symbolName)
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22, height: 22)
                                .background(Theme.softAccent, in: Circle())
                                .accessibilityHidden(true)

                            Text(item.text)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Topics

private struct TopicsCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        let topics = store.topTopics
        if !topics.isEmpty {
            let ceiling = max(1, topics.map(\.views).max() ?? 1)

            Card("Best topics", systemImage: "square.grid.2x2") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(topics) { topic in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(topic.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(topic.views.formatted(.number.notation(.compactName)))
                                    .font(.subheadline.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.secondary)
                            }
                            ProportionBar(fraction: Double(topic.views) / Double(ceiling))
                            Text("\(topic.postCount) \(topic.postCount == 1 ? "post" : "posts")")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Hooks

private struct HooksCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        let hooks = Array(store.bestHooks.prefix(3))
        if !hooks.isEmpty {
            Card("Best hooks", systemImage: "text.quote") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(hooks) { post in
                        NavigationLink(value: post) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(post.hook)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                HStack(spacing: 12) {
                                    if let views = post.views {
                                        Label(views.formatted(.number.notation(.compactName)), systemImage: "eye")
                                    }
                                    if let rate = post.engagementRate {
                                        Text(rate.formatted(.percent.precision(.fractionLength(1))))
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
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Times

private struct TimesCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        let hours = store.bestHours
        if !hours.isEmpty {
            let ceiling = max(1, hours.map(\.averageViews).max() ?? 1)

            Card("Best posting times", systemImage: "clock") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(hours) { hour in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(hour.label)
                                    .font(.subheadline)
                                    .monospacedDigit()
                                Spacer(minLength: 8)
                                Text("\(hour.averageViews.formatted(.number.notation(.compactName))) avg")
                                    .font(.subheadline.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.secondary)
                            }
                            ProportionBar(fraction: Double(hour.averageViews) / Double(ceiling))
                        }
                    }

                    Text("Measured from posts that have actually gone out at these times, so a slot never tried does not appear.")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Format

private struct FormatCard: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        if let best = store.bestFormat {
            Card("Best format", systemImage: "play.rectangle") {
                HStack(spacing: 12) {
                    Image(systemName: best.platform.symbolName)
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Theme.softAccent, in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(best.platform.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("\(best.averageViews.formatted(.number.notation(.compactName))) views a post across \(best.postCount)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }
}

#Preview {
    let store = ContentStore()
    return InsightsView()
        .environment(store)
        .task { await store.connect() }
}
