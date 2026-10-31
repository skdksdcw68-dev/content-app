import SwiftUI

/// One caption style on the grid: a dark frame with the style playing on it,
/// a few words at a time, and its name underneath.
///
/// Shaped like `LookTile` so the steps read as a family. The words move
/// because a caption style is timing as much as type -- "one big word at a
/// time" is something you have to watch to choose.
struct CaptionTile: View {
    let caption: SeriesCaption
    let isChosen: Bool
    let choose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 132
    private static let words = ["NEVER", "LOOK", "AT", "THE", "RED", "LANTERN"]

    var body: some View {
        Button(action: choose) {
            ZStack(alignment: .bottomLeading) {
                // A night-blue stand-in for a picture, so white type reads the
                // way it will on a real video.
                RadialGradient(
                    colors: [Color(red: 0.11, green: 0.18, blue: 0.29), .black],
                    center: .center, startRadius: 8, endRadius: 150
                )

                TimelineView(.periodic(from: .now, by: 0.42)) { context in
                    let beat = reduceMotion ? 4 : Int(context.date.timeIntervalSinceReferenceDate / 0.42)
                    sample(at: beat % Self.words.count)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 40)
                }

                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.74)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(caption.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(caption.detail)
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
        .accessibilityLabel("\(caption.name). \(caption.detail)")
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }

    /// The style, on the word being "spoken" now. Close to what the renderer
    /// draws, not identical: it only has to be recognisable at tile size.
    @ViewBuilder
    private func sample(at index: Int) -> some View {
        let words = Self.words
        // The three-word group the current word falls in.
        let group = Array(words[(index / 3) * 3 ..< min((index / 3) * 3 + 3, words.count)])

        switch caption.id {
        case "bold_pop":
            Text(words[index])
                .font(.system(size: 22, weight: .black).italic())
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0, x: 1.5, y: 1.5)
                .shadow(color: .black, radius: 0, x: -1, y: -1)
                .id(index)
                .transition(.scale(scale: 1.15).combined(with: .opacity))
        case "highlight":
            HStack(spacing: 4) {
                ForEach(group, id: \.self) { word in
                    Text(word)
                        .foregroundStyle(word == words[index] ? Color(red: 1, green: 0.88, blue: 0.3) : .white)
                }
            }
            .font(.system(size: 14, weight: .black))
            .shadow(color: .black, radius: 0, x: 1, y: 1)
        case "minimal":
            Text(group.joined(separator: " "))
                .font(.system(size: 9, weight: .regular))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 14)
                .padding(.leading, 12)
        case "subtitle":
            Text(index < 3 ? "Never look at" : "the red lantern.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1, x: 0, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case "boxed":
            Text(group.joined(separator: " "))
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white))
        default:
            Image(systemName: "photo")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
