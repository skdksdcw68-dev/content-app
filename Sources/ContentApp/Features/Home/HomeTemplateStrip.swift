import SwiftUI

/// "Make something" on Home: the proven formats as tall template previews, each
/// one tap away from a chat already asking for that kind of video (Abel,
/// 7 Nov 2026: "more like template previews"). Same starting prompts as the
/// Explore tab, so both doors do the same thing.
struct HomeTemplateStrip: View {
    @Environment(AppSession.self) private var session

    private struct Format: Identifiable {
        let id: String
        /// The format's slug in `ContentTemplate`, for its built-in sample video.
        let slug: String
        let title: String
        let caption: String
        let colors: [Color]
        let prompt: String
    }

    private let formats: [Format] = [
        Format(
            id: "scary", slug: "scary", title: "Scary story", caption: "SHE HEARD IT AGAIN",
            colors: [Color(red: 0.08, green: 0.07, blue: 0.10), Color(red: 0.22, green: 0.12, blue: 0.30)],
            prompt: "a scary story video"
        ),
        Format(
            id: "motivation", slug: "motivation", title: "Motivation reel", caption: "NOBODY SAW THE FIRST 20 TRIES",
            colors: [Color(red: 0.09, green: 0.15, blue: 0.29), Color(red: 0.16, green: 0.35, blue: 0.60)],
            prompt: "a motivational video"
        ),
        Format(
            id: "facts", slug: "facts", title: "Did you know?", caption: "PENS HAVE A HOLE IN THE CAP",
            colors: [Color(red: 0.10, green: 0.28, blue: 0.55), Color(red: 0.05, green: 0.12, blue: 0.28)],
            prompt: "a did you know facts video"
        ),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(formats) { format in
                    Button { session.push(.makeVideo(format.prompt)) } label: {
                        card(format)
                    }
                    .buttonStyle(SoftPressStyle())
                }
            }
            // Runs to the screen's edges while the gutter stays on the rest.
            .padding(.horizontal, Style.gutter)
        }
        .padding(.horizontal, -Style.gutter)
    }

    private func card(_ format: Format) -> some View {
        let video = ContentTemplate.builtInPreview(for: format.slug)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: format.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            if let video {
                // The real sample, muted and looping, hard-coded in the build.
                SampleLoopVideo(url: video)
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            } else {
                Text(format.caption)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(format.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("Make this")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white, in: Capsule())
            }
            .padding(12)
        }
        .frame(width: 128, height: 204)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(format.title). Make this")
    }
}
