import SwiftUI

/// How Analytics moves. Netro, 29 Sep 2026: "Make the charts to actually alive
/// and very smooth." The rules every piece in this file keeps:
///
/// - A line draws itself in from the left. It never rises out of zero, which
///   reads as every day having been zero a moment ago.
/// - The same days under a different metric morph into their new shape; a
///   different set of days draws in afresh, because morphing one week's
///   Monday into another month's 3rd means nothing.
/// - A number counts up once, the first time it is shown. After that it only
///   rolls between real values: anything in between would be a figure that
///   was never measured.
/// - Reduce Motion gets the finished picture straight away: no drawing,
///   counting or pulsing.
enum AnalyticsMotion {
    /// A metric, or a refreshed report, easing into its new shape.
    static var morph: Animation { .smooth(duration: 0.5) }
    /// A report landing on the page.
    static var land: Animation { .smooth(duration: 0.45) }
    /// The scrub line and its callout following the finger.
    static var glide: Animation { .spring(response: 0.28, dampingFraction: 0.82) }
    /// Digits rolling from one real value to the next.
    static var roll: Animation { .snappy(duration: 0.3) }
    /// A line drawing itself in.
    static var draw: Animation { .easeInOut(duration: 0.9) }
    /// Bars, rings and markers coming to rest.
    static var settle: Animation { .spring(response: 0.5, dampingFraction: 0.72) }

    /// Applies a change with no animation, even inside an animated update --
    /// how Reduce Motion gets the finished picture at once.
    @MainActor
    static func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

// MARK: - Drawing in

/// Hides everything right of an edge that travels across, feathered so a line
/// looks drawn rather than wiped. A mask, not moving data: every point is at
/// its real height from the first frame.
struct DrawIn: ViewModifier {
    /// 0 hides everything, 1 shows everything. The caller animates it.
    let progress: CGFloat
    /// False once the drawing is done: the mask comes off, so a callout or a
    /// label that reaches outside the plot is never clipped.
    let isDrawing: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isDrawing {
            content.mask(alignment: .leading) {
                RevealEdge(progress: progress)
            }
        } else {
            content
        }
    }
}

private struct RevealEdge: View {
    let progress: CGFloat

    private let feather: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle()
                    .frame(width: proxy.size.width)
                LinearGradient(
                    colors: [Color.black, Color.black.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: feather)
            }
            .offset(x: (progress - 1) * (proxy.size.width + feather))
        }
    }
}

// MARK: - The point still being counted

/// A slow ring around the newest point while it is still being counted --
/// today's bucket, or a video read within the last two hours. Nothing pulses
/// when nothing new is arriving, and under Reduce Motion it is a still halo.
struct LivePointHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 2.4

    var body: some View {
        Group {
            if reduceMotion {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 20, height: 20)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    ring(at: timeline.date)
                }
            }
        }
        .frame(width: 36, height: 36)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ring(at date: Date) -> some View {
        let phase: Double = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.period) / Self.period
        let eased: Double = 1 - (1 - phase) * (1 - phase)
        return Circle()
            .fill(Color.accentColor)
            .frame(width: 10, height: 10)
            .scaleEffect(CGFloat(1 + 2.2 * eased))
            .opacity(0.3 * (1 - phase))
    }
}

// MARK: - Refreshing

/// A hairline with light running along it: another range is on its way, and
/// the dimmed numbers under it are the old ones until it lands.
struct RefreshLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 1.3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.track)
                if reduceMotion {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.45))
                } else {
                    TimelineView(.animation) { timeline in
                        runner(width: proxy.size.width, at: timeline.date)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }

    private func runner(width: CGFloat, at date: Date) -> some View {
        let phase: Double = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.period) / Self.period
        let eased: Double = phase * phase * (3 - 2 * phase)
        let length: CGFloat = width * 0.35
        return Capsule()
            .fill(Color.accentColor)
            .frame(width: length)
            .offset(x: -length + (width + length) * CGFloat(eased))
    }
}

// MARK: - Bars

/// A share of a whole as a capsule that grows out from the left the first
/// time it is shown, a beat after the one above it, and settles with a small
/// spring. Later changes ease to the new length.
struct GrowingBar: View {
    let fraction: Double
    /// The shortest it draws, so a tiny share is still a visible mark.
    var minimum: CGFloat = 4
    /// Its place in a list: each bar starts a beat after the one before.
    var order: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.track)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: length(in: proxy.size.width))
            }
            // A spring can overshoot; the track is the bar's edge.
            .clipShape(Capsule())
        }
        .animation(reduceMotion ? nil : AnalyticsMotion.morph, value: fraction)
        .onAppear(perform: grow)
        .accessibilityHidden(true)
    }

    private func length(in width: CGFloat) -> CGFloat {
        let shown: Double = (grown || reduceMotion) ? min(1, max(0, fraction)) : 0
        return max(minimum, width * CGFloat(shown))
    }

    private func grow() {
        guard !grown else { return }
        if reduceMotion {
            AnalyticsMotion.instantly { grown = true }
            return
        }
        withAnimation(AnalyticsMotion.settle.delay(0.15 + Double(order) * 0.06)) {
            grown = true
        }
    }
}

// MARK: - Numbers

/// How a figure is written, so the frames of a count look like the number
/// they are counting to.
enum FigureStyle: Equatable {
    case number
    case signedNumber
    case percent

    init(_ metric: AnalyticsMetric) {
        self = metric.isPercent ? .percent : .number
    }

    func text(_ value: Double) -> String {
        switch self {
        case .number:
            return AnalyticsFormat.number(value)
        case .signedNumber:
            return (value.rounded() > 0 ? "+" : "") + AnalyticsFormat.number(value)
        case .percent:
            return AnalyticsFormat.percent(value)
        }
    }
}

/// The number a tile shows, when it is one, and how it is written.
struct TileFigure {
    let value: Double?
    let style: FigureStyle
}

/// A figure that counts up from zero the first time it is shown, then rolls
/// its digits to each new value -- up when it went up, down when it went down.
/// Nil reads "—", never zero.
struct RollingFigure: View {
    let value: Double?
    let style: FigureStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The first count: when it began and what it counts to. Made with the
    /// view, so the very first frame already starts from zero.
    @State private var count: Count?

    private struct Count {
        let start: Date
        let target: Double
    }

    private static let countDuration: Double = 0.8

    init(value: Double?, style: FigureStyle = .number) {
        self.value = value
        self.style = style
        let target: Double = value ?? 0
        _count = State(initialValue: target == 0 ? nil : Count(start: Date(), target: target))
    }

    var body: some View {
        Group {
            if let count, !reduceMotion, value == count.target {
                TimelineView(.animation) { timeline in
                    Text(style.text(count.target * Self.eased(from: count.start, to: timeline.date)))
                }
            } else {
                Text(value.map { style.text($0) } ?? "—")
                    .contentTransition(transition)
            }
        }
        .animation(AnalyticsMotion.roll, value: value)
        .task {
            guard count != nil else { return }
            try? await Task.sleep(for: .seconds(Self.countDuration))
            count = nil
        }
    }

    private var transition: ContentTransition {
        if reduceMotion { return .opacity }
        return .numericText(value: value ?? 0)
    }

    private static func eased(from start: Date, to now: Date) -> Double {
        let t: Double = min(1, max(0, now.timeIntervalSince(start) / countDuration))
        let rest: Double = 1 - t
        return 1 - rest * rest * rest
    }
}
