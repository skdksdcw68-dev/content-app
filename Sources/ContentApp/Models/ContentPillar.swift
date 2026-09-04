import Foundation

/// A recurring theme the autopilot plans within.
///
/// Pillars are the main lever a person has over an autopilot that otherwise
/// decides for itself: it will only plan posts that belong to one of these,
/// and it balances across them by `weight`.
struct ContentPillar: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var detail: String
    /// Relative share of the schedule. A pillar with weight 2 gets planned
    /// roughly twice as often as one with weight 1.
    var weight: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        detail: String,
        weight: Int = 1,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.weight = weight
        self.isEnabled = isEnabled
    }
}
