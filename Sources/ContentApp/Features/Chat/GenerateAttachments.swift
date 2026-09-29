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

    /// Worn when chat is generating: "Video" or "Image" as an accented chip
    /// whose × puts the composer back to plain chat. A tag, not words in the
    /// field (Abel, 26 Sep 2026: "let it be like a tag or a different tag not
    /// a text actually").
    var tag: String? = nil
    var onClearTag: () -> Void = {}

    /// Opens the photo picker. Which slot it fills is set first. Declared
    /// last so a call site can hand it as the trailing closure.
    let attach: (Slot) -> Void

    enum Slot { case reference, start, end }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let tag {
                    HStack(spacing: 6) {
                        Image(systemName: tag == "Image" ? "photo" : "video")
                            .font(.system(size: 12, weight: .semibold))
                        Text(tag)
                            .font(.subheadline.weight(.semibold))
                        Button(action: onClearTag) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back to chat")
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Theme.accent, in: Capsule())
                }

                Pill(title: "Image", picture: nil) { attach(.reference) } clear: {}

                // Frames are a video's. In image mode the "Image" pill is the
                // one way in, and a "Start frame" on a picture is a word that
                // means nothing there.
                if choices.isVideo, BuiltInModels.takesFrames(choices.model) {
                    Pill(title: "Start frame", picture: choices.startFrame?.preview) {
                        attach(.start)
                    } clear: {
                        choices.startFrame = nil
                    }

                    // The last frame only where the model has one to give:
                    // Kling 2.5 Turbo does; Wan and Veo start from a picture
                    // and choose their own ending.
                    if choices.takesEndFrame {
                        // Swaps them, which is what the arrows mean and what
                        // ElevenLabs does with the same control.
                        Button {
                            let first = choices.startFrame
                            choices.startFrame = choices.endFrame
                            choices.endFrame = first
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(choices.startFrame == nil && choices.endFrame == nil)

                        Pill(title: "End frame", picture: choices.endFrame?.preview) {
                            attach(.end)
                        } clear: {
                            choices.endFrame = nil
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }
}

/// Empty it shows a plus and its name; filled it shows the picture and an ×,
/// which is how somebody can tell at a glance which slot has what in it.
private struct Pill: View {
    let title: String
    let picture: UIImage?
    let tap: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: tap) {
                HStack(spacing: 6) {
                    if let picture {
                        Image(uiImage: picture)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text(title)
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if picture != nil {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.leading, picture == nil ? 13 : 6)
        .padding(.trailing, 13)
        .frame(height: 34)
        .background(Color.track, in: Capsule())
    }
}
