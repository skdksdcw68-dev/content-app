import SwiftUI

/// What the account is doing, read back from TikTok.
///
/// This is where `user.info.stats` and `video.list` earn their place: the
/// follower count and the per-video numbers. Nothing here is projected or
/// estimated, and a figure the platform did not return shows as a dash rather
/// than a zero -- "not reported" and "nobody did it" are different facts.
struct InsightsView: View {
    @Environment(AppSession.self) private var session

    @State private var metrics: Metrics?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading && metrics == nil {
                    LoadingCard()
                } else if let metrics {
                    AccountNumbers(metrics: metrics)

                    if metrics.recent.isEmpty {
                        NoVideosCard()
                    } else {
                        VideosCard(videos: metrics.recent, totals: metrics.totals)
                    }
                } else {
                    UnavailableCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        metrics = await session.metrics()
    }
}

// MARK: - Pieces

private struct AccountNumbers: View {
    let metrics: Metrics

    var body: some View {
        Card("@\(metrics.username)", systemImage: "person.crop.circle") {
            HStack(spacing: 12) {
                MetricTile(
                    label: "Followers",
                    value: (metrics.followers ?? 0).formatted(.number.notation(.compactName)),
                    caption: "on TikTok",
                    isAvailable: metrics.followers != nil
                )
                MetricTile(
                    label: "Videos",
                    value: (metrics.videoCount ?? 0).formatted(),
                    caption: "public",
                    isAvailable: metrics.videoCount != nil
                )
                MetricTile(
                    label: "Likes",
                    value: (metrics.totalLikes ?? 0).formatted(.number.notation(.compactName)),
                    caption: "lifetime",
                    isAvailable: metrics.totalLikes != nil
                )
            }
        }
    }
}

private struct VideosCard: View {
    let videos: [VideoMetric]
    let totals: Totals

    var body: some View {
        Card("Recent videos", systemImage: "play.rectangle") {
            HStack(spacing: 12) {
                MetricTile(
                    label: "Views",
                    value: totals.views.formatted(.number.notation(.compactName)),
                    caption: "across \(videos.count)"
                )
                MetricTile(
                    label: "Likes",
                    value: totals.likes.formatted(.number.notation(.compactName)),
                    caption: "across \(videos.count)"
                )
            }

            VStack(spacing: 12) {
                ForEach(videos) { video in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title.isEmpty ? "Untitled" : video.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)

                        HStack(spacing: 14) {
                            Label(video.views.formatted(.number.notation(.compactName)), systemImage: "eye")
                            Label(video.likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                            Label(video.comments.formatted(), systemImage: "bubble.right")
                            Label(video.shares.formatted(), systemImage: "arrowshape.turn.up.right")
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Says why it is empty rather than leaving a blank panel that reads as broken.
private struct NoVideosCard: View {
    var body: some View {
        Card("No videos to measure", systemImage: "chart.bar") {
            Text("TikTok only reports numbers for public videos. Anything posted while this app is awaiting review stays private, so it will not appear here until the app is approved and a post goes out publicly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LoadingCard: View {
    var body: some View {
        Card {
            HStack(spacing: 12) {
                ProgressView()
                Text("Asking TikTok")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct UnavailableCard: View {
    var body: some View {
        Card("Nothing to show", systemImage: "chart.bar") {
            Text("Connect a TikTok account and its numbers will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
