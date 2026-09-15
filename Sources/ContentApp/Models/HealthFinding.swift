import Foundation

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

/// Where problems live now that Home only promotes.
///
/// The red banner and then the red greeting line both came off Home at Abel's
/// request. The reason they existed is still real -- generation failed silently
/// for three days in September -- so the signal moved to a badge on the You tab
/// and a "Needs attention" section at the top of You.
extension AppSession {
    /// Failed posts older than this are history, not a reason for a badge that
    /// never goes away.
    private static let attentionWindow: TimeInterval = 3 * 24 * 60 * 60

    var failedRecently: [PendingPost] {
        posts.filter {
            $0.state == .failed && $0.post.createdAt > .now.addingTimeInterval(-Self.attentionWindow)
        }
    }

    /// What the badge on You counts.
    var attentionCount: Int {
        health.filter(\.isBlocked).count + failedRecently.count
    }

    /// Where Autopilot actually stands. See `AutopilotState`.
    var autopilotState: AutopilotState? {
        AutopilotState.resolve(
            isOn: settings?.isOn == true,
            hasAccount: !connections.isEmpty,
            hasGenerator: hasWorkingGenerator,
            hasPlan: plan != nil,
            blocked: health.first(where: \.isBlocked),
            needsApproval: posts.filter(\.needsYou).count,
            preparing: posts.filter(\.isBusy).count,
            nextUp: planPosts.compactMap(\.scheduledFor).filter { $0 > .now }.min()
        )
    }
}
