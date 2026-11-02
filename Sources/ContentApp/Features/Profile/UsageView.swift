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
/// took the month -- chat, analytics, pictures, videos.
///
/// Drawn the way Bevel draws its contributors card (Abel, 2 Nov 2026, from
/// Mobbin: "I just want to use it as a usage screen"): the two big numbers on
/// the page, then one soft rounded card of rows, each an icon, a name, a share
/// in colour and a thin gradient bar.
struct UsageView: View {
    @Environment(AppSession.self) private var session
    @State private var breakdown: UsageBreakdown?
    @State private var loaded = false

    var body: some View {
        let standing = session.credits
        ScrollView {
            VStack(spacing: 16) {
                // The month, large: how much of it is gone, and how much is left.
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(standing.map { UsageFormat.percent($0.percentUsed) } ?? "…")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("Used this month")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(standing.map { UsageFormat.percent($0.percentLeft) } ?? "…")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(planLine(standing))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)

                // What took it, each with its own bar, in one soft card.
                VStack(alignment: .leading, spacing: 18) {
                    Text("Where it went")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

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
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )

                Text(subtitle(standing))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                if (standing?.tier ?? 0) < 3 {
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
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

    private func planLine(_ standing: CreditsStanding?) -> String {
        guard let name = standing?.name, !name.isEmpty else { return "left" }
        return "left on \(name)"
    }

    private func subtitle(_ standing: CreditsStanding?) -> String {
        guard let standing else { return "Reading your month…" }
        guard let resets = standing.resets else { return "Everything takes exactly what it costs." }
        return "Fills up again on \(resets.formatted(.dateTime.month(.wide).day())). Everything takes exactly what it costs, and you see the share before you make anything."
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(name)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Text(UsageFormat.percent(group.percent))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.indigo)
            }
            // A thin gradient bar: a track, and the share laid over it.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.pink.opacity(0.55), Color.indigo],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(6, proxy.size.width * min(1, group.percent / 100)))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}

extension AppSession {
    /// Where this month's usage went. Nil when it cannot be read.
    func usageBreakdown() async -> UsageBreakdown? {
        try? await client.rpc("usage_breakdown").execute().value
    }
}
