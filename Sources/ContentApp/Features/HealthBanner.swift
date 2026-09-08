import SwiftUI

/// One thing the agent found wrong with itself.
struct HealthFinding: Identifiable, Decodable, Hashable, Sendable {
    var id: String { code }
    let severity: String
    let code: String
    let title: String
    let detail: String

    var isBlocked: Bool { severity == "blocked" }
}

/// The banner that says the machine has stopped, before anything else on Home.
///
/// This exists because of a specific three days in September. Autopilot was on,
/// both cron loops reported healthy every minute, and the product made nothing
/// at all -- generation refused every request and the publisher cancelled four
/// jobs for want of media. Nothing anywhere said so. The failure was visible in
/// the database the whole time and invisible to the person it was happening to.
///
/// So it sits at the very top, above the greeting, in the colour of the thing
/// it is reporting, and it does not wait to be scrolled to. A warning further
/// down a page is a warning nobody reads.
///
/// Only ever the first finding. `autopilot_health()` returns them worst-first
/// and a stack of six red boxes is a wall, not a signal -- the second problem
/// is worth solving after the first one stops blocking everything behind it.
struct HealthBanner: View {
    let finding: HealthFinding

    private var tint: Color { finding.isBlocked ? .red : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.isBlocked ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }
}
