import SwiftUI

/// One look on the grid: its picture with its name over it, and one line.
///
/// Shaped like `StyleTile` so the two steps read as a family, but here the
/// picture IS the answer -- a look is something you recognise, not something
/// you read -- so the picture fills the tile and the words sit on it.
///
/// The pictures are the same barista poured in twelve looks
/// (`look-<id>` in the asset catalogue), so two tiles differ in the look and
/// nothing else. Until one exists the tile wears a cover of its own rather
/// than a grey hole.
struct LookTile: View {
    let look: SeriesLook
    let isChosen: Bool
    let choose: () -> Void

    private static let height: CGFloat = 132

    var body: some View {
        Button(action: choose) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = UIImage(named: look.artName) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        StyleCover(slug: look.id, symbol: "paintpalette")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .clipped()

                // Under the words, so white type reads on any picture.
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.74)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(look.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(look.tagline)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isChosen ? Theme.accent : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if isChosen {
                    ZStack {
                        Circle().fill(Theme.accent)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                    }
                    .frame(width: 24, height: 24)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel("\(look.name). \(look.tagline)")
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}
