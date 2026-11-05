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
                if let logo = option.logo {
                    logo.view
                        .frame(width: 26, height: 26)
                        .frame(width: 26, alignment: .leading)
                } else {
                    Image(systemName: option.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .frame(width: 26, alignment: .leading)
                }

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
                if let logo = option.logo {
                    logo.view
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: option.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .frame(width: 24)
                }

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

// MARK: - Formats

/// The look of each format: a colour pair and a mark, so the welcome cards and
/// the format step show the same four. Pictures replace these when the cast and
/// the reference frames are approved; until then a card is never an empty box.
struct FormatLook {
    let colors: [Color]
    let symbol: String

    static func of(_ id: String) -> FormatLook {
        switch id {
        case "didyouknow":
            return FormatLook(colors: [Color(red: 0.16, green: 0.47, blue: 0.96), Color(red: 0.36, green: 0.28, blue: 0.86)], symbol: "lightbulb.max.fill")
        case "scary":
            return FormatLook(colors: [Color(red: 0.30, green: 0.16, blue: 0.48), Color(red: 0.07, green: 0.05, blue: 0.14)], symbol: "moon.stars.fill")
        case "motivation":
            return FormatLook(colors: [Color(red: 0.98, green: 0.55, blue: 0.20), Color(red: 0.86, green: 0.22, blue: 0.36)], symbol: "figure.run")
        default:
            return FormatLook(colors: [Color(red: 0.10, green: 0.66, blue: 0.62), Color(red: 0.12, green: 0.38, blue: 0.62)], symbol: "photo.on.rectangle.angled")
        }
    }
}

/// A format as a card: colour, a large faint mark, its name and a line under it.
struct FormatCardFace: View {
    let id: String
    let label: String
    var detail: String?
    var height: CGFloat = 168

    var body: some View {
        let look = FormatLook.of(id)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: look.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: look.symbol)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.22))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .padding(14)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One format to pick.
struct FormatTile: View {
    let option: OnboardingQuestion.Option
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            FormatCardFace(id: option.id, label: option.label, detail: option.detail)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: isChosen ? 3 : 0)
                }
                .overlay(alignment: .topLeading) {
                    if isChosen {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Theme.accent)
                            .padding(10)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(isChosen ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}
