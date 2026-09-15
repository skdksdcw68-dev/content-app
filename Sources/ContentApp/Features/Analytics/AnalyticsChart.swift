import SwiftUI
import Charts

/// The key numbers, as tiles. Tapping one moves the chart to it.
///
/// Only metrics the platform gives get a tile. The rest are listed once,
/// folded, each saying it is not available -- visible, but not a wall of dashes.
struct MetricGrid: View {
    let report: AnalyticsReport
    @Binding var selected: AnalyticsMetric

    @State private var showingUnavailable = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var readings: [MetricReading] { AnalyticsMetric.allCases.map(report.reading) }
    private var shown: [MetricReading] { readings.filter { $0.status != .unavailable } }
    private var unavailable: [MetricReading] { readings.filter { $0.status == .unavailable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(shown, id: \.metric) { reading in
                    MetricTileButton(reading: reading, isSelected: reading.metric == selected) {
                        withAnimation(.snappy(duration: 0.25)) { selected = reading.metric }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selected)

            if !unavailable.isEmpty {
                DisclosureGroup(isExpanded: $showingUnavailable) {
                    VStack(spacing: 0) {
                        ForEach(unavailable, id: \.metric) { reading in
                            HStack(spacing: 10) {
                                Image(systemName: reading.metric.symbol)
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 20)
                                Text(reading.metric.title)
                                    .font(.subheadline)
                                Spacer(minLength: 8)
                                Text("Not available for this platform")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(unavailable.count) metrics \(report.platformNames) doesn't share")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct MetricTileButton: View {
    let reading: MetricReading
    let isSelected: Bool
    let pick: () -> Void

    private var caption: String {
        switch reading.status {
        case .filtered:     return "Not available with a content filter"
        case .insufficient: return "Not enough history yet"
        default:            return AnalyticsFormat.change(reading) ?? "No previous period data"
        }
    }

    private var captionColor: Color {
        reading.status == .actual || reading.status == .derived ? AnalyticsFormat.changeColor(reading) : .secondary
    }

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: reading.metric.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(reading.metric.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if reading.status == .derived {
                        Text("Derived")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(reading.current.map { AnalyticsFormat.value($0, reading.metric) } ?? "—")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)

                Text(caption)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(captionColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: Style.card, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.raised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Style.card, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color(uiColor: .separator).opacity(0.5),
                                  lineWidth: isSelected ? 2 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Style.card, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The selected metric over time, against the period before it.
///
/// Only complete buckets are drawn: a day Autocast was not yet reading has no
/// honest value, and drawing it as zero would draw a drop that never happened.
struct TrendCard: View {
    let report: AnalyticsReport
    let metric: AnalyticsMetric

    @State private var selectedDate: Date?
    @State private var revealed = false

    private var points: [TrendPoint] { report.trend(metric) }

    private var grain: String {
        switch report.range.grain {
        case "week":  "By week"
        case "month": "By 30 days"
        default:      "By day"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(grain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            let current = points
            if current.count < 2 {
                AnalyticsEmptyChart(historyStarts: report.historyStartDate, metric: metric, status: report.reading(metric).status)
            } else {
                chart(current)
                legend(hasPrevious: current.contains { $0.previous != nil })
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
        .onChange(of: metric) { _, _ in selectedDate = nil }
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
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(label, revealed ? point.value : 0),
                    series: .value("Period", "Current")
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
            }

            if current.count >= 3, let peak, peak.value > 0 {
                PointMark(x: .value("Date", peak.date), y: .value(label, revealed ? peak.value : 0))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(44)
                    .annotation(position: .top, spacing: 3) {
                        Text("Peak")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            }

            if current.count >= 3, let low, let peak, low.id != peak.id {
                PointMark(x: .value("Date", low.date), y: .value(label, revealed ? low.value : 0))
                    .foregroundStyle(Color.secondary)
                    .symbolSize(30)
                    .annotation(position: .bottom, spacing: 3) {
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
        .frame(height: 210)
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
                Text("Previous: \(AnalyticsFormat.value(previous, metric))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
    }

    private func legend(hasPrevious: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(Color.accentColor).frame(width: 16, height: 3)
                Text("This period")
            }
            if hasPrevious {
                HStack(spacing: 5) {
                    Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 16, height: 3)
                    Text("Previous period")
                }
            }
            Spacer(minLength: 0)
            Text("Touch the chart for values")
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
                return "Not enough history for a trend yet. Autocast started reading your numbers on \(AnalyticsFormat.day(historyStarts)) and checks every 6 hours."
            }
            return "No readings yet. Autocast checks your numbers every 6 hours once an account is connected."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }
}
