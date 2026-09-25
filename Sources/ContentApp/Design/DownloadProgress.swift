import SwiftUI

/// A download, as a number rather than a spinner.
///
/// Abel, 25 Sep 2026: *"while loading it just spins a native spinner, so that's
/// bad — instead let it download with percent."*
///
/// 🔴 It obeys the rule written at the top of `Loaders.swift`: nothing here
/// claims progress that is not known. A server sending chunked transfer does
/// not say how big the file is, and inventing a percentage out of that is how
/// a ring gets to 90% and sits there. When the length is unknown this shows the
/// megabytes that have actually arrived, which is true and still moves.
struct DownloadProgressView: View {
    /// 0...1, or nil when the server did not say how big the file is.
    let fraction: Double?
    /// Bytes so far — shown instead of a percentage when there is no total.
    var received: Int64 = 0
    var title: String = "Getting your video"
    /// The small form, for a tile rather than a screen.
    var compact = false
    /// Dark screens want white; the default follows the label colour.
    var onDark = false

    private var ringSize: CGFloat { compact ? 34 : 76 }
    private var stroke: CGFloat { compact ? 4 : 6 }
    private var tint: Color { onDark ? .white : Theme.accent }

    var body: some View {
        VStack(spacing: compact ? 0 : 14) {
            ZStack {
                if let fraction {
                    ProgressRing(progress: fraction, lineWidth: stroke, color: tint)
                    Text("\(Int(fraction * 100))%")
                        .font(compact ? .caption2.weight(.bold).monospacedDigit()
                                      : .headline.monospacedDigit())
                        .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .contentTransition(.numericText())
                } else {
                    // No total, so no percentage. The arc says "working" and
                    // the figure underneath says how much has arrived.
                    TurningArc(lineWidth: stroke, color: tint)
                }
            }
            .frame(width: ringSize, height: ringSize)
            .animation(.snappy(duration: 0.45), value: fraction)

            if !compact {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    if fraction == nil, received > 0 {
                        Text(received.formatted(.byteCount(style: .file)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            fraction.map { "\(Int($0 * 100)) percent" }
                ?? received.formatted(.byteCount(style: .file))
        )
    }
}

/// The turning arc used where there is no total to measure against. Borrowed
/// from `BuildingLoader`, so "working, amount unknown" looks the same
/// everywhere in the app.
private struct TurningArc: View {
    var lineWidth: CGFloat = 6
    var color: Color = .accentColor

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
