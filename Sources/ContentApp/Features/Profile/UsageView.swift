import SwiftUI

/// This month for the brand, counted from what actually happened. A cost is
/// shown only where a provider reported one -- never estimated.
struct UsageView: View {
    @Environment(AppSession.self) private var session
    @State private var usage: UsageSummary?
    @State private var loaded = false

    private var monthStart: Date {
        Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    }

    var body: some View {
        Form {
            if let usage {
                Section {
                    row("Posted to TikTok", "paperplane", usage.posted)
                    row("Sent to drafts", "tray.and.arrow.down", usage.sentToDrafts)
                    row("Scheduled now", "calendar.badge.clock", usage.scheduled)
                    row("Videos added", "film", usage.videosMade)
                } header: {
                    Text("Posts")
                }

                Section {
                    row("Plans written", "calendar", usage.plansWritten)
                    row("AI video jobs", "wand.and.stars", usage.aiGenerations)
                    if let writes = usage.byKind["plan_write"], writes > 0 {
                        row("AI plan writes", "sparkles", Int(writes))
                    }
                } header: {
                    Text("AI")
                } footer: {
                    if usage.recordedCostCents > 0 {
                        Text("Generators reported \((Double(usage.recordedCostCents) / 100).formatted(.currency(code: "USD"))) this month. You’re billed by them directly.")
                    } else {
                        Text("No generator reported a cost this month.")
                    }
                }
            } else if loaded {
                Section { Text("Couldn’t load this month’s numbers.").foregroundStyle(.secondary) }
            } else {
                SkeletonRows(count: 5)
            }
        }
        .navigationTitle(monthStart.formatted(.dateTime.month(.wide)))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.brand?.id) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        usage = await session.usage(since: monthStart)
        loaded = true
    }

    private func row(_ title: String, _ symbol: String, _ value: Int) -> some View {
        SettingsRow(title, symbol: symbol, value: value.formatted())
    }
}
