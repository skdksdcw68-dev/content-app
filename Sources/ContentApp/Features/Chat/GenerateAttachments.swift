import SwiftUI

/// What you are giving the model, above the field.
///
/// Abel, 25 Sep 2026: "add the image adding thing instead of a + icon as we
/// gave now and the start and end frame thing when it comes to model that
/// supports it."
///
/// A bare `+` makes somebody tap it to find out what it does. A pill that says
/// "Image" does not. And the frames are only offered when the chosen model
/// actually takes a first and last frame -- offering them on a model that
/// ignores them is a promise the video will not keep, which is the same fault
/// as "Your name or logo" asking for neither.
struct GenerateAttachments: View {
    @Binding var choices: GenerateChoices
    /// Opens the photo picker. Which slot it fills is set first.
    let attach: (Slot) -> Void

    enum Slot { case reference, start, end }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Pill(title: "Image", filled: false) { attach(.reference) }

                if BuiltInModels.takesFrames(choices.model) {
                    Pill(title: "Start frame", filled: false) { attach(.start) }

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Pill(title: "End frame", filled: false) { attach(.end) }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }
}

private struct Pill: View {
    let title: String
    let filled: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Color.track, in: Capsule())
        }
        .buttonStyle(SoftPressStyle())
    }
}
