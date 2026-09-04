import SwiftUI

/// One post, with the autopilot's reasoning above the script.
///
/// The rationale card sits first on purpose: the question this screen answers
/// is "why am I looking at this", and only then "what does it say".
struct PostDetailView: View {
    let post: ContentPost
    @Environment(ContentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Re-read from the store so the view follows approvals and publishes
    /// instead of showing the snapshot it was pushed with.
    private var current: ContentPost {
        store.posts.first { $0.id == post.id } ?? post
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let reason = current.failureReason {
                    calloutCard(
                        title: "This did not go out",
                        text: reason,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }

                calloutCard(
                    title: "Why the autopilot picked this",
                    text: current.rationale,
                    systemImage: "sparkles",
                    tint: .accentColor
                )

                if !current.script.isEmpty {
                    section("Script") {
                        Text(current.script)
                            .font(.body)
                        durationFootnote
                    }
                } else {
                    section("Script") {
                        Text("Not written yet. The autopilot writes the script closer to the slot, so it can use whatever has happened by then.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                if !current.caption.isEmpty {
                    section("Caption") {
                        Text(current.caption)
                        if !current.hashtags.isEmpty {
                            Text(current.hashtags.joined(separator: "  "))
                                .font(.footnote)
                                .foregroundStyle(.tint)
                        }
                    }
                }

                if current.status == .posted {
                    section("How it did") {
                        HStack(spacing: 24) {
                            metric("Views", current.views)
                            metric("Likes", current.likes)
                        }
                    }
                }

                actions
            }
            .padding(20)
        }
        .navigationTitle(current.platform.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusBadge(status: current.status)
                if let pillar = store.pillar(for: current) {
                    Text(pillar.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(current.hook)
                .font(.title3.weight(.semibold))

            if let scheduled = current.scheduledFor, current.status != .posted {
                Label(
                    scheduled.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "clock"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Warns before anything is rendered, which is where the failed sample post
    /// went wrong -- a script over the platform limit fails late and wastes the
    /// render.
    @ViewBuilder
    private var durationFootnote: some View {
        let seconds = Int(current.estimatedDuration.rounded())
        HStack(spacing: 4) {
            Image(systemName: current.fitsPlatform ? "waveform" : "exclamationmark.triangle")
            Text("About \(seconds)s spoken \u{2014} \(current.platform.displayName) allows \(Int(current.platform.maxDuration))s")
        }
        .font(.caption)
        .foregroundStyle(current.fitsPlatform ? .secondary : .red)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if current.isAwaitingApproval {
                Button {
                    store.approve(current)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if !current.status.isTerminal {
                Button {
                    Task { await store.publishNow(current) }
                } label: {
                    Label("Post now", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .destructive) {
                    store.skip(current)
                    dismiss()
                } label: {
                    Label("Skip this one", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.top, 4)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func calloutCard(
        title: String,
        text: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value?.formatted(.number.notation(.compactName)) ?? "\u{2014}")
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
