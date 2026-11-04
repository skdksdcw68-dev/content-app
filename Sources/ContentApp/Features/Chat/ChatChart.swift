import Charts
import SwiftUI

/// An answer's numbers, as the server worked them out from the same data the
/// answer was written from (agent-chat `chartFrom`). Every field optional, so
/// a chart with less in it still draws.
struct ChatChart: Equatable, Decodable, Sendable {
    struct Stat: Equatable, Decodable, Sendable {
        let label: String
        let value: String
        let change: String?
    }

    struct Bar: Equatable, Decodable, Sendable {
        let label: String
        let value: Double
        let display: String?
    }

    let stats: [Stat]?
    let barsTitle: String?
    let bars: [Bar]?
    let topTitle: String?
    let top: [Bar]?

    private enum CodingKeys: String, CodingKey {
        case stats, bars, top
        case barsTitle = "bars_title"
        case topTitle = "top_title"
    }
}

/// Stat tiles, a bar chart and the top videos, under the answer (Abel's
/// mockup, 4 Nov 2026, screen 7).
struct ChatChartCard: View {
    let chart: ChatChart

    private var stats: [ChatChart.Stat] { chart.stats ?? [] }
    private var bars: [ChatChart.Bar] { chart.bars ?? [] }
    private var top: [ChatChart.Bar] { chart.top ?? [] }
    private var tallest: Double { bars.map(\.value).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !stats.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                        tile(stat)
                    }
                }
            }
            if !bars.isEmpty { barChart }
            if !top.isEmpty { topList }
        }
    }

    private func tile(_ stat: ChatChart.Stat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(stat.value)
                .font(.title3.bold())
                .monospacedDigit()
            if let change = stat.change {
                Text(change)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(change.hasPrefix("▲") ? Color.green : change.hasPrefix("▼") ? Color.orange : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
        }
        .accessibilityElement(children: .combine)
    }

    private var barChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = chart.barsTitle {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            Chart {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    BarMark(
                        x: .value("Video", bar.label),
                        y: .value("Views", bar.value)
                    )
                    .foregroundStyle(bar.value == tallest ? Theme.accent : Theme.accent.opacity(0.4))
                    .cornerRadius(5)
                    .annotation(position: .top) {
                        if bar.value == tallest, let shown = bar.display {
                            Text(shown)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .frame(height: 150)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
        }
    }

    private var topList: some View {
        let best = top.map(\.value).max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            if let title = chart.topTitle {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(Array(top.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.label)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.display ?? "")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule().fill(Theme.accent)
                                .frame(width: proxy.size.width * CGFloat(best > 0 ? row.value / best : 0))
                        }
                    }
                    .frame(height: 6)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
        }
    }
}
