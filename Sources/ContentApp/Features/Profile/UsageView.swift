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
/// how their usage is running." The plan, the month and when it fills up
/// again, and what took it -- chat, analytics, pictures, videos.
///
/// Drawn the way Claude draws its Billing and Settings pages (Abel, 2 Nov
/// 2026: "this one looks good", from the mockup): warm paper, one grey row for
/// the plan, one grey card for the month, one grouped list for where it went.
struct UsageView: View {
    @Environment(AppSession.self) private var session
    @State private var breakdown: UsageBreakdown?
    @State private var loaded = false

    var body: some View {
        let standing = session.credits
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                planRow(standing)
                monthCard(standing)
                ClaudeCaption("Where it went")
                whereItWent
                Text("Everything takes exactly what it costs, and you see the share before you make anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                if (standing?.tier ?? 0) < 3 {
                    upgradeButton(standing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.claudePaper.ignoresSafeArea())
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Pieces

    /// The plan, as one grey row. Tapping it opens the plans.
    private func planRow(_ standing: CreditsStanding?) -> some View {
        Button {
            session.showingPaywall = true
        } label: {
            ClaudeGroup {
                HStack {
                    Text("Plan")
                        .font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    Text(planName(standing))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    /// The month in one card: how much is gone, how much is left, and the bar.
    private func monthCard(_ standing: CreditsStanding?) -> some View {
        ClaudeGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(standing.map { UsageFormat.percent($0.percentUsed) } ?? "…")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Text(leftLine(standing))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(resetLine(standing))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ClaudeBar(fraction: (standing?.percentUsed ?? 0) / 100)
                    .padding(.top, 2)
            }
            .padding(14)
        }
        .accessibilityElement(children: .combine)
    }

    /// What took the month, one row each, in one grouped list.
    @ViewBuilder
    private var whereItWent: some View {
        if let groups = breakdown?.groups, !groups.isEmpty {
            ClaudeGroup {
                ForEach(groups) { group in
                    if group.id != groups.first?.id {
                        ClaudeDivider()
                    }
                    UsageGroupRow(group: group)
                }
            }
        } else if loaded {
            ClaudeGroup {
                Text("Nothing used yet this month.")
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        } else {
            ClaudeGroup {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(18)
            }
        }
    }

    private func upgradeButton(_ standing: CreditsStanding?) -> some View {
        Button {
            session.showingPaywall = true
        } label: {
            Text((standing?.tier ?? 0) == 0 ? "Get a plan" : "Get more usage")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(.systemBackground))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.primary, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    // MARK: - Words

    private func load() async {
        await session.refreshCredits()
        breakdown = await session.usageBreakdown()
        loaded = true
    }

    private func planName(_ standing: CreditsStanding?) -> String {
        guard let name = standing?.name, !name.isEmpty else { return "No plan" }
        return name
    }

    private func leftLine(_ standing: CreditsStanding?) -> String {
        guard let standing else { return "" }
        return "\(UsageFormat.percent(standing.percentLeft)) left"
    }

    private func resetLine(_ standing: CreditsStanding?) -> String {
        guard let standing else { return "Reading your month…" }
        guard let resets = standing.resets else { return "Used this month." }
        return "Used this month. Fills up again \(resets.formatted(.dateTime.month(.wide).day()))."
    }
}

/// One kind of usage: its name, its share, and a thin bar.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(UsageFormat.percent(group.percent))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ClaudeBar(fraction: group.percent / 100)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

extension AppSession {
    /// Where this month's usage went. Nil when it cannot be read.
    func usageBreakdown() async -> UsageBreakdown? {
        try? await client.rpc("usage_breakdown").execute().value
    }
}
