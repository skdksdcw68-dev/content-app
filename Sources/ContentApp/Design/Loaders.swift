import SwiftUI

/// Remi's loaders and motion, in one place.
///
/// Every one of these is lifted from Remi's native app, with the file it came
/// from named. The rule they share, and the reason a spinner is almost never
/// used: a spinner says "waiting", and the thing beside it already says what
/// for. So a list that is loading shows the shape of the list, breathing; a
/// picture being made shows light moving across the space it will fill.
///
/// None of them claims progress that is not known. The ring that turns while a
/// plan is written spins; it does not fill to a number it made up.

// MARK: - The breathing dot

/// One dot, breathing, while something is on its way.
/// Remi: `Coach/CoachParts.swift` -- the coach's thinking dot.
struct BreathingDot: View {
    var size: CGFloat = 10

    @State private var isUp = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .scaleEffect(isUp ? 1 : 0.7)
            .opacity(isUp ? 1 : 0.35)
            // A fixed box, so the row beside it does not shift as it breathes.
            .frame(width: size + 6, height: size + 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isUp = true
                }
            }
            .accessibilityLabel("Working on it")
    }
}

// MARK: - Skeletons

private struct Breathing: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

extension View {
    /// The skeleton's pulse: 1 to 0.55 and back, every 0.9s.
    func breathing() -> some View { modifier(Breathing()) }
}

/// Where a row card will be. Remi: `Home/HomeView.swift` `MealSkeleton`.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 5).frame(width: 150, height: 13)
                RoundedRectangle(cornerRadius: 5).frame(width: 90, height: 11)
                RoundedRectangle(cornerRadius: 5).frame(width: 120, height: 11)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.track)
        .padding(12)
        .raisedCard(radius: Style.rowCard)
        .breathing()
        .accessibilityHidden(true)
    }
}

/// Where a big card will be.
struct SkeletonCard: View {
    var height: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 5).frame(width: 120, height: 13)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        }
        .foregroundStyle(Color.track)
        .padding(18)
        .raisedCard()
        .breathing()
        .accessibilityHidden(true)
    }
}

// MARK: - Rings

/// A track, and an arc from twelve o'clock clockwise. Remi: `Views/Components.swift` `Ring`.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 10
    var color: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(Color.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.snappy(duration: 0.45), value: progress)
    }
}

/// The big wait: a ring, a glyph inside it that changes, a title and one line.
///
/// Remi: `Onboarding/BuildingPlanView.swift` -- same 160pt ring, 12pt stroke,
/// 42pt glyph, symbol replace on each change. One difference, on purpose:
/// Remi's plan is computed instantly and its ring fills on a clock. Writing a
/// month of posts takes an unknown number of seconds, so this arc turns
/// instead of filling. A ring at 90% that then sits there is the fake progress
/// Abel has asked never to see.
struct BuildingLoader: View {
    let title: String
    let detail: String
    var glyphs = ["sparkles", "calendar", "film", "text.bubble"]

    @State private var start = Date.now
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            TimelineView(.periodic(from: start, by: 1.6)) { context in
                let index = Int(context.date.timeIntervalSince(start) / 1.6) % max(1, glyphs.count)
                ring(glyph: glyphs[index])
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 40)
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { spinning = true }
    }

    private func ring(glyph: String) -> some View {
        ZStack {
            Circle()
                .stroke(Color.track, lineWidth: 12)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 270 : -90))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)

            Image(systemName: glyph)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.25), value: glyph)
        }
        .frame(width: 160, height: 160)
        .accessibilityHidden(true)
    }
}

// MARK: - Making

/// A band of light running down the space a picture or video will fill. The
/// one thing on screen that says *being made* rather than *waiting*.
///
/// Remi: `Scan/ScanProgressScreen.swift` `ScanSheen`. Remi's runs white over a
/// dark photo; this runs over a card, so the band is the system's grey, which
/// shows on white in light mode and lifts off the dark card in dark mode.
struct MakingSheen: View {
    var band = Color(uiColor: .systemGray5)

    @State private var sweeping = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [band.opacity(0), band, band.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 130)
            .offset(y: sweeping ? geo.size.height : -130)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Started by itself when it appears, as Remi's is. Started from outside
        // in the same instant it was put on screen, the sweep could land on a
        // view with no earlier position to move from, and sit still.
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { sweeping = true }
        }
    }
}

// MARK: - Entrance

private struct Entrance: ViewModifier {
    let order: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.35).delay(Double(order) * 0.07)) { shown = true }
            }
    }
}

extension View {
    /// Remi's paywall entrance: a fade and a 12-point rise over 0.35s, each
    /// section 70ms after the one before.
    func entrance(_ order: Int) -> some View { modifier(Entrance(order: order)) }
}
