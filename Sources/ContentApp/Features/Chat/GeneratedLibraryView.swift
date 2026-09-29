import SwiftUI

/// Everything that was made, on one shelf.
///
/// Abel, 29 Sep 2026: "after you generate with the chat, there is no 'Video'
/// or 'Generation' or 'Library' called or a badge. We probably need that
/// thing." A picture made on Tuesday used to be somewhere inside a
/// conversation you would have to remember and scroll to. This is every
/// picture, video and sound from every conversation, newest first, three
/// across -- the way a camera roll is laid out, because that is the shape
/// people already know how to look through.
///
/// Not the same screen as `LibraryView`, which is the posts: videos on their
/// way to TikTok, YouTube and Instagram. This is what was GENERATED, whether
/// or not it was ever posted.
struct GeneratedLibraryView: View {
    @Environment(AppSession.self) private var session

    /// Nil until the first read comes back, so the grid can draw its shape.
    @State private var items: [Artifact]?
    @State private var filter: Shelf = .all
    @State private var viewing: Artifact?

    private enum Shelf: String, CaseIterable, Identifiable {
        case all, videos, images, audio
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:    "All"
            case .videos: "Videos"
            case .images: "Images"
            case .audio:  "Audio"
            }
        }
        func holds(_ artifact: Artifact) -> Bool {
            switch self {
            case .all:    true
            case .videos: artifact.kind == "video"
            case .images: artifact.kind == "image"
            case .audio:  artifact.kind == "audio"
            }
        }
    }

    private var shown: [Artifact] { (items ?? []).filter { filter.holds($0) } }

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                chips
                    .padding(.horizontal, 16)

                if items == nil {
                    LazyVGrid(columns: grid, spacing: 3) {
                        ForEach(0..<9, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.track)
                                .aspectRatio(9 / 16, contentMode: .fit)
                        }
                    }
                    .breathing()
                } else if shown.isEmpty {
                    VStack(spacing: 8) {
                        EmptyArt(name: "empty-posts", size: 96)
                        Text("Nothing here yet")
                            .font(.headline)
                        Text("Everything you make in a chat lands here, from every conversation.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .padding(.horizontal, 32)
                } else {
                    LazyVGrid(columns: grid, spacing: 3) {
                        ForEach(shown) { artifact in
                            Button { viewing = artifact } label: {
                                MadeTile(artifact: artifact)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(label(for: artifact))
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .task { items = await session.library() }
        .refreshable { items = await session.library() }
        .fullScreenCover(item: $viewing) { artifact in
            // A picture can go on to be a reference or be animated, from
            // here as much as from the conversation it was made in: the
            // choice is handed to the video page, which picks it up when it
            // opens.
            MediaViewer(
                artifact: artifact,
                onAnimate: handoff(for: artifact, animating: true),
                onReference: handoff(for: artifact, animating: false)
            )
        }
    }

    /// The viewer's Animate and Use-as-reference buttons, for a picture. A
    /// video has neither, so it gets nil and the buttons are not drawn.
    private func handoff(for artifact: Artifact, animating: Bool) -> ((Artifact) -> Void)? {
        guard artifact.kind == "image" else { return nil }
        return { picked in hand(picked, animating: animating) }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Shelf.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { filter = item }
                    } label: {
                        Text(item.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(filter == item ? Theme.onAccent : Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                filter == item ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.track),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        }
    }

    /// Picture in hand, on to the video page, which sets it up in the
    /// composer as it opens.
    private func hand(_ artifact: Artifact, animating: Bool) {
        session.referenceHandoff = (artifact, animating)
        session.push(.makeVideo(""))
    }

    private func label(for artifact: Artifact) -> String {
        let kind = artifact.kind == "video" ? "Video" : (artifact.kind == "image" ? "Image" : "Audio")
        if let prompt = artifact.body.prompt, !prompt.isEmpty { return "\(kind): \(prompt)" }
        return kind
    }
}

/// One thing that was made, as a tile: its picture, or a video's first frame,
/// or a waveform for a sound.
private struct MadeTile: View {
    let artifact: Artifact

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var picture: UIImage?

    var body: some View {
        // A frame of its own first, and the picture laid over it and clipped:
        // a picture that fills a tile must not decide how big the tile is.
        Color.track
            .aspectRatio(9 / 16, contentMode: .fit)
            .overlay {
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                } else if artifact.kind == "audio" {
                    Image(systemName: "waveform")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if artifact.kind == "video" {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        if let seconds = artifact.body.seconds, seconds > 0 {
                            Text(Self.clock(seconds))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: artifact.id) {
                guard picture == nil, artifact.kind != "audio" else { return }
                // A tile is small: no more pixels than it is drawn with.
                let pixels = 240 * displayScale
                picture = artifact.kind == "video"
                    ? await session.poster(of: artifact, longest: pixels)
                    : await session.picture(of: artifact, longest: pixels)
            }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
