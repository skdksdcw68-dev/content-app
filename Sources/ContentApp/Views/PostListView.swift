import SwiftUI

/// The queue: a banner saying what the autopilot is cleared to do, the chip
/// row, then the posts it has produced.
struct PostListView: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            AutopilotBanner()
            StatusFilterBar()
            Divider()

            if store.visiblePosts.isEmpty {
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "tray",
                    description: Text(store.statusFilter == nil
                        ? "The autopilot has not planned anything yet."
                        : "No posts with that status.")
                )
            } else {
                List {
                    ForEach(store.visiblePosts) { post in
                        NavigationLink(value: post) {
                            PostRow(post: post)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.skip(post)
                            } label: {
                                Label("Skip", systemImage: "trash")
                            }
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
                }
                .listStyle(.plain)
                .refreshable { await store.refresh() }
            }
        }
        .navigationTitle("Queue")
        .navigationDestination(for: ContentPost.self) { PostDetailView(post: $0) }
        .searchable(text: $store.searchText, prompt: "Search hooks and captions")
    }
}

/// One line at the top saying exactly what the autopilot will do without being
/// asked. This is the thing a person opening the app actually wants to know.
private struct AutopilotBanner: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.settings.isOn ? "bolt.fill" : "pause.circle")
                // Explicit Color on both branches. This one happens to compile
                // with leading dots only because `.green` comes first and
                // forces Color; swapping the branches would break it. See the
                // same fix in PostDetailView.
                .foregroundStyle(store.settings.isOn ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.settings.summary)
                    .font(.footnote.weight(.medium))
                if let next = store.nextScheduled, let at = next.scheduledFor, store.settings.isOn {
                    Text("Next out \(at.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if store.awaitingApprovalCount > 0 {
                Text("\(store.awaitingApprovalCount) to review")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct PostRow: View {
    let post: ContentPost
    @Environment(ContentStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusBadge(status: post.status)
                if let pillar = store.pillar(for: post) {
                    Text(pillar.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(post.effectiveDate.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(post.hook)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            // The rationale, not the script. What matters on a row is why this
            // exists at all -- the script is one tap away.
            Text(post.rationale)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if post.status == .posted, let views = post.views, let likes = post.likes {
                HStack(spacing: 12) {
                    Label(views.formatted(.number.notation(.compactName)), systemImage: "eye")
                    Label(likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        PostListView()
            .environment(ContentStore())
    }
}
