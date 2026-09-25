import SwiftUI

/// Ideas for the next video, and the measured reason each one is here.
///
/// Abel, 25 Sep 2026: "depending on the kind of videos the user makes, the
/// captions, the hashtags -- understand what videos he's making and give the
/// user inspirational videos to post, like VidIQ."
///
/// The card is built around the sentence that makes it worth reading. VidIQ
/// shows a score and leaves you to guess; every idea here carries the finding
/// it came from -- "videos under 20 seconds get 2.4x the views on this
/// account, over 14 posts" -- so a suggestion can be argued with. When there
/// are no numbers yet the card says so in those words rather than dressing a
/// guess up as a finding.

// MARK: - The shelf on Home

/// One row of ideas, the way the recent videos sit above it.
struct InspirationShelf: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(session.inspiration.prefix(8)) { idea in
                    IdeaCard(idea: idea)
                }
            }
            // Lets the row run to the screen's edges while the gutter stays
            // on everything else, exactly as the video row does.
            .padding(.horizontal, Style.gutter)
        }
        .padding(.horizontal, -Style.gutter)
    }
}

/// The placeholder while the first set is being written, so the shelf does not
/// appear out of nowhere under a heading that was already there.
struct InspirationSkeleton: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous)
                        .fill(Color.track)
                        .frame(width: 240, height: 168)
                }
            }
            .padding(.horizontal, Style.gutter)
        }
        .padding(.horizontal, -Style.gutter)
        .breathing()
    }
}

// MARK: - One idea

struct IdeaCard: View {
    let idea: InspirationIdea
    @Environment(AppSession.self) private var session

    var body: some View {
        Button { session.make(idea) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: idea.measured ? "chart.line.uptrend.xyaxis" : "sparkles")
                        .font(.caption2.weight(.semibold))
                    Text(idea.measured ? "From your numbers" : "A starting point")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(idea.measured ? Theme.accent : Color.secondary)

                Text(idea.hook)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(idea.because)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if let seconds = idea.seconds {
                        FactTag(text: "\(seconds)s")
                    }
                    if let format = idea.format, !format.isEmpty {
                        FactTag(text: format)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "wand.and.stars")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(14)
            .frame(width: 240, height: 168, alignment: .topLeading)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
        .contextMenu {
            Button { session.make(idea) } label: {
                Label("Make this video", systemImage: "wand.and.stars")
            }
            Button(role: .destructive) { session.dismiss(idea) } label: {
                Label("Not for me", systemImage: "hand.thumbsdown")
            }
        }
        .accessibilityLabel("\(idea.hook). \(idea.because)")
    }
}

/// A small fact beside an idea: how long, what format.
private struct FactTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.track, in: Capsule())
    }
}

// MARK: - The whole feed

/// Every idea standing, one under the other, with the angle shown in full.
struct InspirationView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        List {
            if session.inspiration.isEmpty && !session.isFindingIdeas {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing yet")
                            .font(.headline)
                        Text("Post a few videos and this fills with ideas drawn from which of yours did well. Pull down to look again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                }
            }

            ForEach(session.inspiration) { idea in
                Section {
                    IdeaRow(idea: idea)
                }
            }
        }
        .listStyle(.insetGrouped)
        .tabChrome(title: "Ideas", mode: .inline)
        .overlay {
            if session.inspiration.isEmpty && session.isFindingIdeas {
                ProgressView("Reading your posts")
                    .font(.subheadline)
            }
        }
        .refreshable { await session.refreshInspiration(force: true) }
        .task { await session.refreshInspiration() }
    }
}

private struct IdeaRow: View {
    let idea: InspirationIdea
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: idea.measured ? "chart.line.uptrend.xyaxis" : "sparkles")
                Text(idea.measured ? "From your numbers" : "A starting point")
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(idea.measured ? Theme.accent : Color.secondary)

            Text(idea.hook)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(idea.angle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // The sentence that earns the suggestion. Kept verbatim from the
            // insight it came from, never re-worded on the way here.
            Text(idea.because)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !idea.hashtags.isEmpty {
                Text(idea.hashtags.joined(separator: " "))
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button { session.make(idea) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("Make it")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(SoftPressStyle())

                Button { session.dismiss(idea) } label: {
                    Text("Not for me")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Color.track, in: Capsule())
                }
                .buttonStyle(SoftPressStyle())

                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }
}
