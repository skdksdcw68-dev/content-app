import SwiftUI
import Supabase

/// Where this month's usage went, from `usage_breakdown()` (0081).
struct UsageBreakdown: Decodable, Equatable, Sendable {
    struct Group: Decodable, Equatable, Sendable, Identifiable {
        let kind: String
        let units: Int
        /// Share of the whole month, 0 to 100.
        let percent: Double
        var id: String { kind }
    }

    let allowance: Int
    let groups: [Group]
}

/// The Usage screen. Netro, 19 Oct 2026: "The user must click Usage to see
/// how their usage is running." The meter, when it fills up again, and what
/// took the month -- chat, analytics, pictures, videos -- in the native list
/// the rest of You is built from.
struct UsageView: View {
    @Environment(AppSession.self) private var session
    @State private var breakdown: UsageBreakdown?
    @State private var loaded = false

    var body: some View {
        let standing = session.credits
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(standing.map { UsageFormat.percent($0.percentUsed) } ?? "…")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("used")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let name = standing?.name {
                            Text(name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    ProgressView(value: standing.map { $0.percentUsed / 100 } ?? 0)
                        .tint(meterTint(standing))
                    Text(subtitle(standing))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
                if let groups = breakdown?.groups, !groups.isEmpty {
                    ForEach(groups) { group in
                        UsageGroupRow(group: group)
                    }
                } else if loaded {
                    Text("Nothing used yet this month.")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("This month")
            } footer: {
                Text("Everything takes exactly what it costs: a chat reply a tiny share, a picture well under 1%, a video more. You see the share before you make anything.")
            }

            if (standing?.tier ?? 0) < 3 {
                Section {
                    Button {
                        session.showingPaywall = true
                    } label: {
                        Label((standing?.tier ?? 0) == 0 ? "Get a plan" : "Get more usage", systemImage: "arrow.up.circle")
                    }
                }
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        await session.refreshCredits()
        breakdown = await session.usageBreakdown()
        loaded = true
    }

    private func subtitle(_ standing: CreditsStanding?) -> String {
        guard let standing else { return "Reading your month…" }
        let left = "\(UsageFormat.percent(standing.percentLeft)) left"
        guard let resets = standing.resets else { return left }
        return "\(left) · fills up again on \(resets.formatted(.dateTime.month(.wide).day()))"
    }

    private func meterTint(_ standing: CreditsStanding?) -> Color {
        let used = standing?.percentUsed ?? 0
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return Theme.proGreen
    }
}

private struct UsageGroupRow: View {
    let group: UsageBreakdown.Group

    private var name: String {
        switch group.kind {
        case "videos": return "Videos"
        case "pictures": return "Pictures"
        case "audio": return "Sound and voice"
        case "chat": return "Chat"
        case "analytics": return "Analytics"
        case "research": return "Research"
        case "plans": return "Plans and campaigns"
        case "writing": return "Captions and ideas"
        default: return "Other"
        }
    }

    private var symbol: String {
        switch group.kind {
        case "videos": return "film"
        case "pictures": return "photo"
        case "audio": return "waveform"
        case "chat": return "bubble.left.and.bubble.right"
        case "analytics": return "chart.xyaxis.line"
        case "research": return "magnifyingglass"
        case "plans": return "calendar"
        case "writing": return "text.quote"
        default: return "ellipsis.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SettingsLabel(name, symbol: symbol)
                Spacer(minLength: 8)
                Text(UsageFormat.percent(group.percent))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, group.percent / 100))
                .tint(Theme.accent)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension AppSession {
    /// Where this month's usage went. Nil when it cannot be read.
    func usageBreakdown() async -> UsageBreakdown? {
        try? await client.rpc("usage_breakdown").execute().value
    }
}
