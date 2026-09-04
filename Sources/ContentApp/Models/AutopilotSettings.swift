import Foundation

/// Everything the autopilot is allowed to decide, and the bounds it decides in.
struct AutopilotSettings: Codable, Hashable, Sendable {
    /// The master switch. Off means nothing is planned, written or published.
    var isOn: Bool
    /// How many posts a day it aims for, across all connected platforms.
    var postsPerDay: Int
    /// Platforms it may publish to. Intersected with connected accounts.
    var platforms: Set<Platform>
    /// The voice it writes in. Free text, handed to the model verbatim.
    var tone: String
    /// When ON, a post stops at `.scheduled` until a person approves it.
    /// When OFF, the autopilot publishes on its own -- which is the point of
    /// the product, and also the setting people want to opt into deliberately.
    var requiresApproval: Bool
    /// Earliest and latest hour of the day it will publish in, local time.
    /// Outside this window a due post waits.
    var quietHoursStart: Int
    var quietHoursEnd: Int

    init(
        isOn: Bool = false,
        postsPerDay: Int = 2,
        platforms: Set<Platform> = [.tiktok],
        tone: String = "Direct, a little dry, no hype words.",
        requiresApproval: Bool = true,
        quietHoursStart: Int = 22,
        quietHoursEnd: Int = 7
    ) {
        self.isOn = isOn
        self.postsPerDay = postsPerDay
        self.platforms = platforms
        self.tone = tone
        self.requiresApproval = requiresApproval
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }

    /// True when `hour` falls inside the quiet window. The window wraps past
    /// midnight whenever start > end, which is the normal case.
    func isQuiet(hour: Int) -> Bool {
        if quietHoursStart == quietHoursEnd { return false }
        if quietHoursStart < quietHoursEnd {
            return hour >= quietHoursStart && hour < quietHoursEnd
        }
        return hour >= quietHoursStart || hour < quietHoursEnd
    }

    /// What the autopilot is actually cleared to do right now, in one line.
    /// Drives the status banner at the top of the queue.
    var summary: String {
        guard isOn else { return "Autopilot is off" }
        let plural = postsPerDay == 1 ? "post" : "posts"
        let mode = requiresApproval ? "waits for your approval" : "posts on its own"
        return "\(postsPerDay) \(plural) a day, \(mode)"
    }
}
