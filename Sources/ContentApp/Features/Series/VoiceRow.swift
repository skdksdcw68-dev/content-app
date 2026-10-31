import SwiftUI

/// One voice on the voiceover step: the same card as every other option, with
/// its sample's play button INSIDE it, between the words and the check.
///
/// Abel, 31 Oct 2026: "the voice play button is outside the cover, right?
/// Maybe put it inside." Outside, it read as a second control floating next to
/// the list rather than part of the voice it plays.
struct VoiceRow: View {
    let voice: SeriesVoice
    let isChosen: Bool
    let isPlaying: Bool
    let choose: () -> Void
    let play: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: choose) {
                HStack(alignment: .center, spacing: 13) {
                    Image(systemName: voice.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                        Text(voice.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if isPlaying {
                            // Says the sample is running without pretending to
                            // know how far: it streams, and its length is not
                            // known until it has loaded.
                            Label("Playing", systemImage: "waveform")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .symbolEffect(.variableColor.iterative, isActive: true)
                                .padding(.top, 2)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)

            if voice.sample != nil {
                Button(action: play) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isPlaying ? Theme.onAccent : Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(isPlaying ? Theme.accent : Theme.accent.opacity(0.14)))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressButtonStyle())
                .accessibilityLabel(isPlaying ? "Stop \(voice.name)" : "Hear \(voice.name)")
            }

            Button(action: choose) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? Theme.accent : Color(.tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            shape.fill(isChosen ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Theme.surface))
                .overlay(shape.strokeBorder(isChosen ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .animation(.snappy(duration: 0.2), value: isPlaying)
    }
}
