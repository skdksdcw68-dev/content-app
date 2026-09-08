import SwiftUI

/// What this app can do, said by the app, on the screen you open first.
///
/// Every one of these is a real feature with a real destination -- the card
/// takes you to the thing it describes. Nothing here is an advertisement for
/// something that does not exist, which is the difference between a product
/// showing you around and a product selling to you.
///
/// The order is not fixed. What it shows depends on what is missing: no account
/// leads with connecting one, no generator leads with adding one, and once
/// everything is set up it settles into the features somebody might not have
/// found yet.
struct PromoCarousel: View {
    let hasAccount: Bool
    let hasGenerator: Bool
    let hasPlan: Bool

    @State private var page = 0

    private var slides: [Promo] {
        var out: [Promo] = []

        // What is missing comes first, because a tour of features you cannot
        // use yet is not a tour, it is a list of things that do not work.
        if !hasAccount {
            out.append(Promo(
                id: "connect",
                image: "promo-connect",
                eyebrow: "Start here",
                headline: "Connect the account it posts to",
                destination: .profile
            ))
        }

        if !hasPlan {
            out.append(Promo(
                id: "plan",
                image: "promo-plan",
                eyebrow: "Plan a month",
                headline: "Thirty posts, laid out with a time on each",
                destination: .create
            ))
        }

        if !hasGenerator {
            out.append(Promo(
                id: "make",
                image: "promo-make",
                eyebrow: "It films them too",
                headline: "Describe the shot once and it makes the video",
                destination: .profile
            ))
        }

        out.append(Promo(
            id: "auto",
            image: "promo-auto",
            eyebrow: "Autopilot",
            headline: "Approve once. It goes out on time, app closed.",
            destination: hasPlan ? .plan : .create
        ))

        if hasPlan {
            out.append(Promo(
                id: "plan-running",
                image: "promo-plan",
                eyebrow: "Your month",
                headline: "See what is going out and when",
                destination: .plan
            ))
        }

        return out
    }

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $page) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, promo in
                    PromoCard(promo: promo).tag(index)
                }
            }
            // The page style is what gives the swipe and the dots. Drawing
            // either by hand is the thing that makes an app look hand-drawn.
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 132)

            if slides.count > 1 {
                Dots(count: slides.count, current: page)
            }
        }
        // A slide disappearing when its job is done -- connecting an account,
        // adding a generator -- must not leave the page index past the end.
        .onChange(of: slides.count) { _, count in
            if page >= count { page = max(0, count - 1) }
        }
    }
}

// MARK: - One slide

struct Promo: Identifiable, Hashable {
    enum Destination: Hashable { case create, plan, profile }

    let id: String
    let image: String
    let eyebrow: String
    let headline: String
    let destination: Destination
}

private struct PromoCard: View {
    let promo: Promo

    var body: some View {
        NavigationLink {
            switch promo.destination {
            case .create:  CreateView()
            case .plan:    PlanView()
            case .profile: ProfileView()
            }
        } label: {
            HStack(spacing: 0) {
                // Bled to the card edge rather than inset as a chip. The
                // reference gives its artwork a full third of the card and no
                // padding of its own -- a picture with a margin on all four
                // sides reads as an icon, and an icon does not carry a card.
                PromoArtwork(name: promo.image)

                VStack(alignment: .leading, spacing: 5) {
                    Text(promo.eyebrow)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(promo.headline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The picture, or something reasonable when there is not one yet.
///
/// Artwork is added to the catalog by hand, so a missing file has to be a
/// slightly plainer card rather than a blank rectangle or a crash. This checks
/// before it draws, which also means the carousel can ship before the art does.
private struct PromoArtwork: View {
    let name: String

    private var artwork: UIImage? { UIImage(named: name) }

    var body: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                // The images are pale 3D renders on near-white; this is the
                // same idea with no file, so the layout is honest either way.
                LinearGradient(
                    colors: [Theme.softAccent, Color(.tertiarySystemGroupedBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: 132, height: 132)
        .clipped()
    }
}

/// The page dots, drawn small and quiet.
private struct Dots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary.opacity(0.7) : Color(.tertiaryLabel))
                    .frame(width: index == current ? 16 : 6, height: 6)
                    .animation(.snappy(duration: 0.2), value: current)
            }
        }
        .accessibilityHidden(true)
    }
}
