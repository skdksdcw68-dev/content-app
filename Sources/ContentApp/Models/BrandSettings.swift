import Foundation

/// How the brand wants to be run.
///
/// Mirrors `brand_settings`. Every field here is a decision the person made
/// once and should not be asked about again -- which is why the plan sheet has
/// three questions and not ten.
struct BrandSettings: Decodable, Hashable, Sendable {
    /// The autopilot switch. Off by default, deliberately: everything it turns
    /// on spends the person's money without asking again.
    var isOn: Bool
    var postsPerDay: Int
    var requiresApproval: Bool
    var quietHoursStart: Int
    var quietHoursEnd: Int
    /// How long before a slot the media is made. Not at plan time -- generating
    /// thirty videos up front spends money on posts that may be discarded, and
    /// provider outputs expire in about a week.
    var renderLeadHours: Int

    enum CodingKeys: String, CodingKey {
        case isOn = "is_on"
        case postsPerDay = "posts_per_day"
        case requiresApproval = "requires_approval"
        case quietHoursStart = "quiet_hours_start"
        case quietHoursEnd = "quiet_hours_end"
        case renderLeadHours = "render_lead_hours"
    }

    /// Ported from the one piece of the first version that was unambiguously
    /// correct, and kept in step with `is_quiet_hour()` in migration 0003.
    /// The wrapping case (22:00 to 07:00) is the normal one and the easy one to
    /// get wrong; start == end means no quiet window at all, not a 24-hour one.
    func isQuiet(hour: Int) -> Bool {
        if quietHoursStart == quietHoursEnd { return false }
        if quietHoursStart < quietHoursEnd {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
        return hour >= quietHoursStart || hour < quietHoursEnd
    }

    /// How it reads on one line.
    var quietWindow: String {
        guard quietHoursStart != quietHoursEnd else { return "No quiet hours" }
        return String(format: "Quiet %02d:00 to %02d:00", quietHoursStart, quietHoursEnd)
    }
}
