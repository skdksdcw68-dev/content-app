import Foundation

/// Who the account is for and what it sounds like -- the context the planner
/// is given before it decides anything.
///
/// Separate from `AutopilotSettings` on purpose: settings are the bounds the
/// autopilot works inside, this is the brief it works from. Changing the brief
/// changes what it writes; changing the settings changes what it is allowed
/// to do with it.
struct BrandProfile: Codable, Hashable, Sendable {
    var name: String
    /// Who is on the other end. Handed to the model verbatim, so it is worth
    /// writing as a sentence rather than a keyword list.
    var audience: String
    /// The subject the account is about.
    var niche: String

    /// Things the planner has worked out from what has been posted so far and
    /// now applies without being told again.
    ///
    /// Shown in Profile because an autopilot that quietly accumulates opinions
    /// about you and never shows them is not one people trust. Every entry is
    /// removable.
    var memory: [String]

    /// When off, the planner is given the brief and nothing else -- no
    /// accumulated memory. Clearing memory is destructive; this is the
    /// reversible version of the same choice.
    var usesMemory: Bool

    init(
        name: String = "",
        audience: String = "",
        niche: String = "",
        memory: [String] = [],
        usesMemory: Bool = true
    ) {
        self.name = name
        self.audience = audience
        self.niche = niche
        self.memory = memory
        self.usesMemory = usesMemory
    }

    /// True once there is enough here for the planner to write in a voice
    /// that is recognisably this account's rather than a generic one.
    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !audience.trimmingCharacters(in: .whitespaces).isEmpty
            && !niche.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What Profile shows on the row, and what Home nudges about when thin.
    var summary: String {
        isComplete ? "\(niche) \u{2014} for \(audience)" : "Incomplete"
    }
}
