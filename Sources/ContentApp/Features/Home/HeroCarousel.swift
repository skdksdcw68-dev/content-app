import SwiftUI

/// What Autocast does, in pictures, on the screen you open first.
///
/// Always promotion. The carousel it replaced led with whatever was missing --
/// "Connect the account it posts to" -- which made the first thing on Home a
/// list of what was not set up. Now every slide sells a real feature and opens
/// it, and the only setup slide left is an invitation to connect, shown until
/// there is an account.
///
/// The pictures are Abel's (see the prompts in the plan). Until a file exists
/// the card draws a dark gradient with the slide's symbol, so the carousel can
/// ship before the art does.
struct HeroCarousel: View {
    let hasAccount: Bool
    let hasPlan: Bool

    @State private var page = 0

    private var slides: [HeroSlide] {
        var out: [HeroSlide] = []

        if !hasAccount {
            out.append(HeroSlide(
                id: "connect",
                images: ["hero-connect", "promo-connect"],
                symbol: "link",
                eyebrow: "Start here",
                headline: "Connect TikTok, YouTube or Instagram and it posts for you",
                destination: .profile
            ))
        }

        out.append(HeroSlide(
            id: "plan",
            images: ["hero-plan", "promo-plan"],
            symbol: "calendar",
            eyebrow: "Plan",
            headline: "A month of posts from one sentence",
            destination: .create
        ))
        out.append(HeroSlide(
            id: "autopilot",
            images: ["hero-autopilot", "promo-auto"],
            symbol: "paperplane.fill",
            eyebrow: "Autopilot",
            headline: "It posts on time, even with the app closed",
            destination: hasPlan ? .plan : .create
        ))
        out.append(HeroSlide(
            id: "make",
            images: ["hero-make", "promo-make"],
            symbol: "film",
            eyebrow: "Make",
            headline: "Describe a video and it makes it",
            destination: .create
        ))
        out.append(HeroSlide(
            id: "analytics",
            images: ["hero-analytics"],
            symbol: "chart.bar.fill",
            eyebrow: "Analytics",
            headline: "See which videos worked",
            destination: .analytics
        ))
        out.append(HeroSlide(
            id: "brands",
            images: ["hero-brands"],
            symbol: "square.stack.3d.up.fill",
            eyebrow: "Every app",
            headline: "Market all your apps from one place",
            destination: .brand
        ))

        return out
    }

    var body: some View {
        VStack(spacing: 6) {
            TabView(selection: $page) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    HeroCard(slide: slide)
                        // Room for the card's shadow, which the pager clips.
                        .padding(.bottom, 14)
                        .tag(index)
                }
            }
            // The page style gives the swipe for free. Drawing it by hand is
            // what makes an app look hand-drawn.
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 210)

            PageDots(count: slides.count, current: page)
        }
        .sensoryFeedback(.selection, trigger: page)
        // A slide disappearing when its job is done must not leave the page
        // index past the end.
        .onChange(of: slides.count) { _, count in
            if page >= count { page = max(0, count - 1) }
        }
    }
}

struct HeroSlide: Identifiable, Hashable {
    enum Destination: Hashable { case create, plan, analytics, brand, profile }

    let id: String
    /// The new picture first, then the older one it replaces.
    let images: [String]
    let symbol: String
    let eyebrow: String
    let headline: String
    let destination: Destination
}

private struct HeroCard: View {
    let slide: HeroSlide

    private var artwork: UIImage? {
        slide.images.lazy.compactMap { UIImage(named: $0) }.first
    }

    var body: some View {
        NavigationLink {
            switch slide.destination {
            case .create:    CreateView().pushedPage()
            case .plan:      PlanView()
            case .analytics: AnalyticsView().pushedPage()
            case .brand:     BrandView()
            case .profile:   ProfileView().pushedPage()
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .overlay { background }

                // Remi's camera shade, so white words read on any picture.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(slide.eyebrow)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(slide.headline)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 196)
            .clipShape(RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous)
                    .fill(Color.raised)
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
            }
            .contentShape(RoundedRectangle(cornerRadius: Style.bigCard, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
    }

    @ViewBuilder
    private var background: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            // Remi's scan card with no photo: two greys, dark in both schemes,
            // so the white words always read.
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [Color(white: 0.16), Color(white: 0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: slide.symbol)
                    .font(.system(size: 84, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.12))
                    .padding(22)
            }
        }
    }
}

/// Small and quiet. The current page is a capsule, the others are dots.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary.opacity(0.75) : Color(uiColor: .systemGray4))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy(duration: 0.25), value: current)
        .accessibilityHidden(true)
    }
}
