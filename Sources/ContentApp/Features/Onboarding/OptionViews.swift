import SwiftUI

/// The two shapes an onboarding answer takes: a tile when the label stands on
/// its own, a row when it needs a line of explanation. Lifted out of the flow
/// view so the questions and the account screens can live in one folder.

struct OptionTile: View {
    let option: OnboardingQuestion.Option
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: option.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 26, alignment: .leading)

                Text(option.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(isChosen ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Theme.surface))
                    .overlay(shape.strokeBorder(isChosen ? Theme.accent : .clear, lineWidth: 1.5))
            }
            // A small settle on pick, so choosing feels like it landed.
            .scaleEffect(isChosen ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}

/// A row for options that carry a description.
struct DetailedOption: View {
    let option: OnboardingQuestion.Option
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.primary)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? Theme.accent : Color(.tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(isChosen ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Theme.surface))
                    .overlay(shape.strokeBorder(isChosen ? Theme.accent : .clear, lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}
