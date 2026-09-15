import SwiftUI

/// Remi's numbers, written down once.
///
/// Abel's call, 15 Sep 2026: Autocast uses Remi's exact colours, buttons and
/// cards. This is `remi/native/Sources/Remi/Views/Style.swift` brought across
/// nearly verbatim, so the two apps do not re-decide the same things. Remi is
/// black and white on the system's own colours -- the only custom colour is
/// AccentColor (#111111 / #FFFFFF) -- so copying it keeps Dark Mode and
/// Increased Contrast working for free.
///
/// Roles rather than sizes. `Style.stepTitle` survives somebody deciding titles
/// should be a shade larger; `.title2.bold()` repeated forty times does not.
enum Style {

    // MARK: - Space

    /// The screen edge.
    static let gutter: CGFloat = 20
    /// Inside a `List` row, where the system has already inset things.
    static let rowGutter: CGFloat = 16
    /// Between things that belong together.
    static let tight: CGFloat = 8
    /// Between things that do not.
    static let loose: CGFloat = 32

    // MARK: - Shape

    /// Controls, fields, small grouped blocks.
    static let card: CGFloat = 14
    /// Anything that should read as a control rather than a container.
    static let pill: CGFloat = 22
    /// A row card on Home: a post, a video.
    static let rowCard: CGFloat = 20
    /// The big cards on Home.
    static let bigCard: CGFloat = 22

    // MARK: - Type

    static let rowTitle = Font.subheadline
    static let rowTitleStrong = Font.subheadline.weight(.semibold)
    static let rowDetail = Font.caption
    static let sectionHeader = Font.footnote.weight(.semibold)
    static let sectionFooter = Font.footnote
    static let screenTitle = Font.title3.weight(.bold)
    static let stepTitle = Font.title2.weight(.bold)
}

// MARK: - Meaning

extension Color {
    /// Near-black on a light screen, white on a dark one. Lives in AccentColor,
    /// so every control follows it.
    static let brand = Color.accentColor
    /// Something did not work.
    static let urgent = Color(uiColor: .systemRed)
    /// Behind Home's cards: soft grey in light, black in dark.
    static let canvas = Color(uiColor: .systemGroupedBackground)
    /// A card on the canvas: white, or the raised grey of a dark screen.
    static let raised = Color(uiColor: .secondarySystemGroupedBackground)
    /// The empty part of a ring, a skeleton block, a chip.
    static let track = Color(uiColor: .tertiarySystemFill)
}

// MARK: - The primary button

/// The words on the one big button a screen has.
///
/// Black button, white words on a light screen; white button, black words on
/// a dark one. The prominent style draws its label white whatever the tint,
/// which on dark mode's white button is white on white -- so the label takes
/// the screen's own background colour, which is always the opposite.
struct PrimaryButtonLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .fontWeight(.semibold)
        .frame(maxWidth: .infinity, minHeight: 30)
        .foregroundStyle(Color(uiColor: .systemBackground))
    }
}

extension View {
    /// The system's prominent button, large, in the accent -- Remi's big button.
    func primaryButtonStyle(tint: Color = .accentColor) -> some View {
        buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(tint)
    }
}

/// A press you can feel: the card gives a little under the finger. Remi's
/// `PaywallPressStyle`, used for every tappable card.
struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Surfaces

extension View {
    /// Home's card: white on the grey canvas, lifted by a shadow so faint it
    /// only separates.
    func raisedCard(radius: CGFloat = Style.bigCard) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.raised)
                .shadow(color: .black.opacity(0.05), radius: 14, y: 4)
        }
    }

    /// Content inset from the screen edge.
    func screenGutter() -> some View {
        padding(.horizontal, Style.gutter)
    }

    /// A flat card: the app's one control radius, on the app's card colour.
    func cardBackground(_ fill: Color = Color(uiColor: .secondarySystemBackground)) -> some View {
        background {
            RoundedRectangle(cornerRadius: Style.card, style: .continuous).fill(fill)
        }
    }
}

// MARK: - Shared pieces

/// The left edge of a row card when there is no picture: the day, big.
///
/// Remi puts the meal's photo there. A post has no thumbnail on the phone yet
/// (the video sits behind a signed URL), and the day it goes out is the thing
/// you are actually scanning for.
struct DayTile: View {
    let date: Date?
    var timezone: TimeZone = .current
    var size: CGFloat = 96

    var body: some View {
        VStack(spacing: 1) {
            Text(date?.formatted(Date.FormatStyle(timeZone: timezone).month(.abbreviated)).uppercased() ?? "—")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(date?.formatted(Date.FormatStyle(timeZone: timezone).day()) ?? "—")
                .font(.system(size: size * 0.31, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .background(Color.track)
        .accessibilityHidden(true)
    }
}

/// "9:00 AM" on a quiet capsule, as Remi marks a meal's time.
struct TimeChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.track, in: Capsule())
            .fixedSize()
    }
}

/// Autocast's mark: three arcs over a dot, the app icon's tower, drawn so it
/// follows the text colour in either appearance.
struct TowerMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height * 0.66)
            let line = side * 0.08
            let dot = side * 0.075

            context.fill(
                Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)),
                with: .foreground
            )

            for radius in [0.2, 0.34, 0.48] {
                var arc = Path()
                arc.addArc(
                    center: center,
                    radius: side * radius,
                    startAngle: .degrees(215),
                    endAngle: .degrees(325),
                    clockwise: false
                )
                context.stroke(arc, with: .foreground, style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
        }
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}
