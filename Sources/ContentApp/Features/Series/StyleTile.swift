import SwiftUI

/// One content style as a tile, and the cover it wears when its photograph
/// does not exist yet.
///
/// Shared: the series flow and onboarding show the same 37 styles, so they
/// show them the same way. Lifted out of SeriesFlowView on 24 Sep 2026 when
/// onboarding gained its own "what kind of videos?" step (Abel: "make the
/// onboarding of choosing a content").

/// The cover a style wears until its photograph exists.
///
/// Not a placeholder: a deliberate two-tone wash with the style's own symbol
/// over it, coloured from the slug so the same style is always the same colour
/// and no two neighbours collide. Black and white surfaces everywhere else in
/// the app, so this stays low and desaturated rather than becoming the
/// coloured tiles Abel called childish on 22 Sep.
struct StyleCover: View {
    let slug: String
    let symbol: String

    /// Stable across launches: `hashValue` is seeded per process and would
    /// repaint every style a different colour each time the app opened.
    private var hue: Double {
        var total = 0
        for byte in slug.utf8 { total = (total &* 31 &+ Int(byte)) % 3600 }
        return Double(total) / 3600
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.30, brightness: 0.34),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }
}

/// A style on the grid: its picture (or its cover until there is one), its
/// name, what it is for, and one line.
struct StyleTile: View {
    let template: ContentTemplate
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let image = UIImage(named: template.artName) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // A cover of its own rather than a grey hole. The
                        // photograph is better and is coming, but a style
                        // without one still has to look like somebody meant
                        // it (Abel, 23 Sep 2026: "why does some of them
                        // doesn't have images").
                        StyleCover(slug: template.slug, symbol: template.symbol)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // What it is for, on the tile, now that the shelf label
                    // above it is gone.
                    Text(template.category.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(template.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            }
            .background(Color.raised)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isChosen ? Theme.accent : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel("\(template.name). \(template.tagline)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
