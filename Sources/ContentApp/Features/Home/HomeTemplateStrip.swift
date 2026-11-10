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
        let route: AppRoute
        /// A symbol in place of the words (Photo to video).
        var symbol: String?
    }

    private let formats: [Format] = [
        Format(
            id: "scary", slug: "scary", title: "Scary story", caption: "SHE HEARD IT AGAIN",
            colors: [Color(red: 0.08, green: 0.07, blue: 0.10), Color(red: 0.22, green: 0.12, blue: 0.30)],
            route: .makeVideo("a scary story video")
        ),
        Format(
            id: "motivation", slug: "motivation", title: "Motivation reel", caption: "NOBODY SAW THE FIRST 20 TRIES",
            colors: [Color(red: 0.09, green: 0.15, blue: 0.29), Color(red: 0.16, green: 0.35, blue: 0.60)],
            route: .makeVideo("a motivational video")
        ),
        Format(
            id: "animate", slug: "animate", title: "Photo to video", caption: "",
            colors: [Color(red: 0.23, green: 0.17, blue: 0.14), Color(red: 0.40, green: 0.30, blue: 0.24)],
            route: .chatOpening("Turn a picture of mine into a short video"), symbol: "play.fill"
        ),
        Format(
            id: "thumbnail", slug: "thumbnail", title: "YouTube thumbnail", caption: "I TRIED IT FOR 30 DAYS",
            colors: [Color(red: 0.54, green: 0.16, blue: 0.08), Color(red: 0.91, green: 0.27, blue: 0.17)],
            route: .chatOpening("Make a YouTube thumbnail")
        ),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(formats) { format in
                    Button { session.push(format.route) } label: {
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
            } else if let symbol = format.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 40)
            } else {
                Text(format.caption)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 40)
            }

            Text(format.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(12)
        }
        .frame(width: 128, height: 204)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(format.title). Make this")
    }
}
