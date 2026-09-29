import SwiftUI
import Charts

/// Key metrics and their chart, in one card -- Studio's arrangement. Tapping a
/// tile moves the chart to it. Metrics a platform does not give are not tiles;
/// the Overview says once, in its own card, where they come from.
///
/// While a finger is on the chart, the chosen tile reads out the bucket under
/// it -- that bucket's real value, and its dates in place of the caption --
/// and eases back to the range's total when the finger lifts.
struct KeyMetricsCard: View {
    let report: AnalyticsReport
    let metrics: [AnalyticsMetric]
    @Binding var selected: AnalyticsMetric
    let subtitle: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bucket under the finger; nil when nothing is held.
    @State private var scrub: TrendPoint?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var readings: [MetricReading] {
        metrics.map(report.reading).filter { $0.status != .unavailable }
    }

    /// A new metric morphs the same days into their new shape.
    private var morph: Animation? {
        reduceMotion ? nil : AnalyticsMotion.morph
    }

    var body: some View {
        AnalyticsCard(
            title: "Key metrics",
            subtitle: subtitle,
            info: "What was gained in this range, compared with the same number of days just before it. Only days Autocast was already reading count; anything earlier is left out, never shown as zero."
        ) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(readings, id: \.metric) { reading in
                    tile(reading)
                }
            }
            .sensoryFeedback(.selection, trigger: selected)

            TrendChart(report: report, metric: selected, scrubbed: $scrub)
        }
    }

    private func tile(_ reading: MetricReading) -> some View {
        let isSelected: Bool = reading.metric == selected
        let held: TrendPoint? = isSelected ? scrub : nil
        let figure: Double? = held?.value ?? reading.current
        return KeyTile(
            title: reading.metric.title,
            value: figure.map { AnalyticsFormat.value($0, reading.metric) } ?? "—",
            caption: caption(reading),
            captionColor: color(reading),
            isSelected: isSelected,
            figure: TileFigure(value: figure, style: FigureStyle(reading.metric)),
            scrubCaption: held.map { AnalyticsFormat.bucket($0) }
        ) {
            withAnimation(morph) { selected = reading.metric }
        }
    }

    private func caption(_ reading: MetricReading) -> String {
        switch reading.status {
        case .filtered:
            return "Not with a content filter"
        case .insufficient:
            return "Not enough history yet"
        default:
            if let since = reading.since {
                return "Since \(AnalyticsFormat.day(since)), when Autocast started reading"
            }
            return AnalyticsFormat.change(reading) ?? "No earlier period yet"
        }
    }

    private func color(_ reading: MetricReading) -> Color {
        reading.status == .actual || reading.status == .derived ? AnalyticsFormat.changeColor(reading) : .secondary
    }
}

/// Followers: the live total and what changed in the range.
struct FollowersCard: View {
    let report: AnalyticsReport
    let total: Int?
    let subtitle: String

    /// The bucket under the finger, read out by the net tile while held.
    @State private var scrub: TrendPoint?

    private var net: MetricReading { report.reading(.followersGained) }

    private var netValue: Double? { scrub?.value ?? net.current }

    private var netCaption: String {
        guard net.current != nil else { return "Not enough history yet" }
        if let since = net.since { return "Since \(AnalyticsFormat.day(since))" }
        return AnalyticsFormat.change(net) ?? "In this range"
    }

    var body: some View {
        AnalyticsCard(
            title: "Key metrics",
            subtitle: subtitle,
            info: "Total is what TikTok reports right now. Net is the change across the range, from Autocast's own readings."
        ) {
            HStack(spacing: 12) {
                KeyTile(
                    title: "Total followers",
                    value: total.map { AnalyticsFormat.number(Double($0)) } ?? "—",
                    caption: "All time",
                    figure: TileFigure(value: total.map { Double($0) }, style: .number)
                )
                KeyTile(
                    title: "Net followers",
                    value: netValue.map { FigureStyle.signedNumber.text($0) } ?? "—",
                    caption: netCaption,
                    captionColor: net.current == nil || net.since != nil ? .secondary : AnalyticsFormat.changeColor(net),
                    isSelected: true,
                    figure: TileFigure(value: netValue, style: .signedNumber),
                    scrubCaption: scrub.map { AnalyticsFormat.bucket($0) }
                )
            }
            TrendChart(report: report, metric: .followersGained, scrubbed: $scrub)
        }
    }
}

/// A metric over time against the period before it. Only complete buckets are
/// drawn: a day Autocast was not yet reading has no honest value.
///
/// Netro, 29 Sep 2026: "Make the charts to actually alive and very smooth."
/// So the line draws itself in from the left, a new metric morphs the same
/// days into their new shape, the finger gets a line and a callout that glide
/// after it, and the bucket still being counted breathes.
struct TrendChart: View {
    let report: AnalyticsReport
    let metric: AnalyticsMetric
    /// The bucket under the finger, for the figure above the chart to read out.
    @Binding var scrubbed: TrendPoint?

    var body: some View {
        let points = report.trend(metric)
        Group {
            if points.count < 2 {
                AnalyticsEmptyChart(historyStarts: report.historyStartDate, metric: metric, status: report.reading(metric).status)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    // Overlapping, so the old range fades out under the new
                    // one drawing in, instead of stacking above it.
                    ZStack {
                        TrendPlot(points: points, metric: metric, scrubbed: $scrubbed)
                            .id(drawKey)
                            .transition(.opacity)
                    }
                    legend(hasPrevious: points.contains { $0.previous != nil })
                }
            }
        }
    }

    /// A new range is a different set of days, so it draws in afresh; a new
    /// metric over the same days morphs in place.
    private var drawKey: String {
        "\(report.range.from)|\(report.range.to)"
    }

    private var grain: String {
        switch report.range.grain {
        case "week":  "by week"
        case "month": "by 30 days"
        default:      "by day"
        }
    }

    private func legend(hasPrevious: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(Color.accentColor).frame(width: 14, height: 3)
                Text("This period")
            }
            if hasPrevious {
                HStack(spacing: 5) {
                    Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 14, height: 3)
                    Text("Before")
                }
            }
            Spacer(minLength: 0)
            Text(grain)
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// The chart itself. Its own view, so a new range gets a fresh one that
/// draws in, while a new metric on the same days morphs in place.
private struct TrendPlot: View {
    let points: [TrendPoint]
    let metric: AnalyticsMetric
    @Binding var scrubbed: TrendPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date?
    /// How far the line has drawn in, 0 to 1.
    @State private var drawn: CGFloat = 0
    @State private var isDrawing = true
    /// Peak, lowest and the breathing point wait until the line reaches them.
    @State private var settled = false

    var body: some View {
        let selected: TrendPoint? = nearest(to: selectedDate)
        chart(selected: selected)
            .frame(height: 200)
            .onAppear(perform: drawIn)
            .onChange(of: selected) { _, point in
                scrubbed = point
            }
            .onChange(of: metric) { _, _ in
                selectedDate = nil
            }
            .onDisappear {
                scrubbed = nil
            }
            .sensoryFeedback(.selection, trigger: selected?.id)
    }

    private func chart(selected: TrendPoint?) -> some View {
        let label: String = metric.title
        let scrubbing: Bool = selected != nil
        let shown: Bool = settled || reduceMotion
        let markerOpacity: Double = shown ? (scrubbing ? 0.3 : 1) : 0
        return Chart {
            previousLine(label: label, dimmed: scrubbing)
            currentLine(label: label, selectedID: selected?.id)
            markers(label: label, opacity: markerOpacity)
            openBucket(label: label, shown: shown)
            selection(selected, label: label)
        }
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartPlotStyle { plot in
            plot.modifier(DrawIn(progress: drawn, isDrawing: isDrawing && !reduceMotion))
        }
        .animation(reduceMotion ? nil : AnalyticsMotion.glide, value: selected?.id)
    }

    // MARK: Marks

    private var previousPoints: [TrendPoint] {
        points.compactMap { point in
            point.previous.map { TrendPoint(id: point.id, date: point.date, endDate: point.endDate, value: $0, previous: nil) }
        }
    }

    private var peak: TrendPoint? {
        points.max { $0.value < $1.value }
    }

    private var low: TrendPoint? {
        points.min { $0.value < $1.value }
    }

    /// The area fades up behind the line as it draws.
    private var areaFill: LinearGradient {
        let strength: Double = reduceMotion ? 1 : Double(drawn)
        return LinearGradient(
            colors: [Color.accentColor.opacity(0.16 * strength), Color.accentColor.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ChartContentBuilder
    private func previousLine(label: String, dimmed: Bool) -> some ChartContent {
        ForEach(previousPoints) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value(label, point.value),
                series: .value("Period", "Previous")
            )
            .foregroundStyle(Color.secondary.opacity(dimmed ? 0.25 : 0.45))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private func currentLine(label: String, selectedID: Int?) -> some ChartContent {
        ForEach(points) { point in
            AreaMark(
                x: .value("Date", point.date),
                y: .value(label, point.value)
            )
            .foregroundStyle(areaFill)
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Date", point.date),
                y: .value(label, point.value),
                series: .value("Period", "Current")
            )
            .foregroundStyle(Color.accentColor)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
            .symbol {
                TrendDot(dimmed: selectedID != nil && selectedID != point.id)
            }
        }
    }

    @ChartContentBuilder
    private func markers(label: String, opacity: Double) -> some ChartContent {
        if points.count >= 3, let peak, peak.value > 0 {
            PointMark(x: .value("Date", peak.date), y: .value(label, peak.value))
                .foregroundStyle(Color.accentColor.opacity(opacity))
                .symbolSize(50)
                .annotation(position: .top, spacing: 4) {
                    MarkerLabel(text: "Peak", opacity: opacity)
                }
        }

        if points.count >= 3, let low, let peak, low.id != peak.id {
            PointMark(x: .value("Date", low.date), y: .value(label, low.value))
                .foregroundStyle(Color.secondary.opacity(opacity))
                .symbolSize(34)
                .annotation(position: .bottom, spacing: 4) {
                    MarkerLabel(text: "Lowest", opacity: opacity)
                }
        }
    }

    /// The bucket that holds today is still being counted: it breathes, and
    /// only once the line has reached it.
    @ChartContentBuilder
    private func openBucket(label: String, shown: Bool) -> some ChartContent {
        if shown, let last = points.last, last.isOpen {
            PointMark(x: .value("Date", last.date), y: .value(label, last.value))
                .foregroundStyle(Color.clear)
                .annotation(position: .overlay, alignment: .center, spacing: 0) {
                    LivePointHalo()
                }
        }
    }

    @ChartContentBuilder
    private func selection(_ selected: TrendPoint?, label: String) -> some ChartContent {
        if let selected {
            RuleMark(x: .value("Date", selected.date))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    TrendCallout(point: selected, metric: metric)
                }

            PointMark(x: .value("Date", selected.date), y: .value(label, selected.value))
                .symbol {
                    SelectedDot()
                }
        }
    }

    // MARK: Behaviour

    private func nearest(to date: Date?) -> TrendPoint? {
        guard let date else { return nil }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// Draws the line in once; the mask comes off when it is done and the
    /// markers settle in. Reduce Motion gets it finished at once.
    private func drawIn() {
        guard isDrawing else { return }
        if reduceMotion {
            AnalyticsMotion.instantly {
                drawn = 1
                isDrawing = false
                settled = true
            }
            return
        }
        withAnimation(AnalyticsMotion.draw.delay(0.12)) {
            drawn = 1
        } completion: {
            isDrawing = false
            withAnimation(AnalyticsMotion.settle) {
                settled = true
            }
        }
    }
}

/// A point on the line: dims while the finger is on another one.
private struct TrendDot: View {
    let dimmed: Bool

    var body: some View {
        Circle()
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .background(Circle().fill(Color.raised))
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.35 : 1)
    }
}

/// The point under the finger, bigger than the rest, with a soft ring.
private struct SelectedDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 11, height: 11)
            .overlay {
                Circle().strokeBorder(Color.raised, lineWidth: 2)
            }
            .background {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 26, height: 26)
            }
    }
}

private struct MarkerLabel: View {
    let text: String
    let opacity: Double

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .opacity(opacity)
    }
}

/// What the finger is on: the bucket's dates, its real value, and the same
/// bucket of the period before.
private struct TrendCallout: View {
    let point: TrendPoint
    let metric: AnalyticsMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AnalyticsFormat.bucket(point))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(AnalyticsFormat.value(point.value, metric))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .contentTransition(.numericText(value: point.value))
            if let previous = point.previous {
                Text("Before: \(AnalyticsFormat.value(previous, metric))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .allowsHitTesting(false)
    }
}

private struct AnalyticsEmptyChart: View {
    let historyStarts: Date?
    let metric: AnalyticsMetric
    let status: MetricStatus

    private var message: String {
        switch status {
        case .unavailable:
            return "\(metric.title) is not available for this platform."
        case .filtered:
            return "\(metric.title) belongs to the account, so it can't be split by a content filter."
        default:
            if let historyStarts {
                return "The chart fills in as Autocast reads your numbers. It started on \(AnalyticsFormat.day(historyStarts)) and checks every 6 hours."
            }
            return "No readings yet. Autocast checks your numbers every 6 hours once an account is connected."
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(.horizontal, 12)
    }
}
