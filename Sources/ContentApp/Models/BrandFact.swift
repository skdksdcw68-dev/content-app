import Foundation

/// One thing the agent has been told, and now applies without being asked again.
///
/// Mirrors `brand_memory`. Shown in full and removable line by line, because an
/// agent that quietly accumulates opinions about you is not one anybody should
/// hand an unattended publish key.
struct BrandFact: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let fact: String
    /// Where it came from: the person, the agent, or the numbers. Only `user`
    /// exists today; the other two are what learning from results will write.
    let source: String
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, fact, source
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fact = try container.decodeIfPresent(String.self, forKey: .fact) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "user"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            .flatMap(PostgresTimestamp.parse)
    }
}
