import SwiftUI

/// One thing wrong, said the way the person it happened to would say it.
///
/// Every field here is written by the database from a closed set of failure
/// codes. Nothing a provider said reaches this type; that stays on
/// `generation_jobs.error`, for diagnostics. See 0021 for the sentence that was
/// on a customer's home screen before that rule existed — it named a supplier
/// they never chose, quoted an error string and cited an HTTP status.
struct HealthFinding: Identifiable, Decodable, Hashable, Sendable {
    var id: String { code }
    let severity: String
    let code: String
    let title: String
    let detail: String
    /// The one button this finding wants. Nil when there is nothing to press.
    let action: String?
    /// Where that button goes.
    let route: String?

    var isBlocked: Bool { severity == "blocked" }
}

/// Where a health action sends somebody. A closed set on purpose: a route the
/// app does not recognise should be a button that never appears, rather than
/// one that appears and does nothing.
enum HealthRoute: String {
    case generator
    case connections
    case plan
}

/// The banner that says the machine has stopped, before anything else on Home.
///
/// This exists because of a specific three days in September. Autopilot was on,
/// both cron loops reported healthy every minute, and the product made nothing
/// at all. Nothing anywhere said so. The failure was visible in the database
/// the whole time and invisible to the person it was happening to.
///
/// Two rules, and the second was learned the hard way:
///
///   1. It sits at the very top, above the greeting, in the colour of the thing
///      it reports. A warning further down a page is a warning nobody reads.
///   2. It never shows an error. It shows a consequence and one thing to do
///      about it. What broke is the backend's business.
///
/// Only ever the worst finding — `autopilot_health()` returns one row. A stack
/// of red boxes is a wall, not a signal, and the second problem is worth
/// solving once the first stops blocking everything behind it.
struct HealthBanner: View {
    let finding: HealthFinding
    let onAct: (HealthRoute) -> Void

    private var tint: Color { finding.isBlocked ? .red : .orange }

    /// Only when the finding names an action *and* a route the app knows.
    private var route: HealthRoute? {
        guard finding.action != nil, let raw = finding.route else { return nil }
        return HealthRoute(rawValue: raw)
    }

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

                if let route, let label = finding.action {
                    Button { onAct(route) } label: {
                        HStack(spacing: 4) {
                            Text(label)
                            Image(systemName: "arrow.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
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
