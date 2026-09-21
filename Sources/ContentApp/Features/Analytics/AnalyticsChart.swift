import SwiftUI
import Charts

/// Key metrics and their chart, in one card -- Studio's arrangement. Tapping a
/// tile moves the chart to it. Metrics a platform does not give are not tiles;
/// the Overview says once, in its own card, where they come from.
struct KeyMetricsCard: View {
    let report: AnalyticsReport
    let metrics: [AnalyticsMetric]
    @Binding var selected: AnalyticsMetric
    let subtitle: String

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var readings: [MetricReading] {
        metrics.map(report.reading).filter { $0.status != .unavailable }
    }

    var body: some View {
        AnalyticsCard(
            title: "Key metrics",
            subtitle: subtitle,
            info: "What was gained in this range, compared with the same number of days just before it. Only days Autocast was already reading count; anything earlier is left out, never shown as zero."
        ) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(readings, id: \.metric) { reading in
                    KeyTile(
                        title: reading.metric.title,
                        value: reading.current.map { AnalyticsFormat.value($0, reading.metric) } ?? "—",
                        caption: caption(reading),
                        captionColor: color(reading),
                        isSelected: reading.metric == selected
                    ) {
                        withAnimation(.snappy(duration: 0.25)) { selected = reading.metric }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selected)

            TrendChart(report: report, metric: selected)
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

    private var net: MetricReading { report.reading(.followersGained) }

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
                    caption: "All time"
                )
                KeyTile(
                    title: "Net followers",
                    value: net.current.map { value in (value > 0 ? "+" : "") + AnalyticsFormat.number(value) } ?? "—",
                    caption: netCaption,
                    captionColor: net.current == nil || net.since != nil ? .secondary : AnalyticsFormat.changeColor(net),
                    isSelected: true
                )
            }
            TrendChart(report: report, metric: .followersGained)
        }
    }
}

/// A metric over time against the period before it. Only complete buckets are
/// drawn: a day Autocast was not yet reading has no honest value.
struct TrendChart: View {
    let report: AnalyticsReport
    let metric: AnalyticsMetric

    @State private var selectedDate: Date?
    @State private var revealed = false

    var body: some View {
        let points = report.trend(metric)
        Group {
            if points.count < 2 {
                AnalyticsEmptyChart(historyStarts: report.historyStartDate, metric: metric, status: report.reading(metric).status)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    chart(points)
                    legend(hasPrevious: points.contains { $0.previous != nil })
                }
            }
        }
        .onChange(of: metric) { _, _ in selectedDate = nil }
    }

    private var grain: String {
        switch report.range.grain {
        case "week":  "by week"
        case "month": "by 30 days"
        default:      "by day"
        }
    }

    private func chart(_ current: [TrendPoint]) -> some View {
        let previous = current.compactMap { point in
            point.previous.map { TrendPoint(id: point.id, date: point.date, endDate: point.endDate, value: $0, previous: nil) }
        }
        let peak = current.max { $0.value < $1.value }
        let low = current.min { $0.value < $1.value }
        let selected = nearest(to: selectedDate, in: current)
        let label = metric.title

        return Chart {
            ForEach(previous) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(label, point.value),
                    series: .value("Period", "Previous")
                )
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .interpolationMethod(.monotone)
            }

            ForEach(current) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value(label, revealed ? point.value : 0)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Date", point.date),
                    y: .value(label, revealed ? point.value : 0),
                    series: .value("Period", "Current")
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
                .symbol {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .background(Circle().fill(Color.raised))
                        .frame(width: 7, height: 7)
                }
            }

            if current.count >= 3, let peak, peak.value > 0 {
                PointMark(x: .value("Date", peak.date), y: .value(label, revealed ? peak.value : 0))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(50)
                    .annotation(position: .top, spacing: 4) {
                        Text("Peak")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            }

            if current.count >= 3, let low, let peak, low.id != peak.id {
                PointMark(x: .value("Date", low.date), y: .value(label, revealed ? low.value : 0))
                    .foregroundStyle(Color.secondary)
                    .symbolSize(34)
                    .annotation(position: .bottom, spacing: 4) {
                        Text("Lowest")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            }

            if let selected {
                RuleMark(x: .value("Date", selected.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        callout(selected)
                    }
            }
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
        .frame(height: 200)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { revealed = true }
        }
    }

    private func callout(_ point: TrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AnalyticsFormat.range(point.date, point.endDate))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(AnalyticsFormat.value(point.value, metric))
                .font(.subheadline.weight(.bold).monospacedDigit())
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

    private func nearest(to date: Date?, in points: [TrendPoint]) -> TrendPoint? {
        guard let date else { return nil }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
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
