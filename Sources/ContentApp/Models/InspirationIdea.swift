import Foundation

/// A video worth making next, and the measured reason it is being suggested.
///
/// Mirrors `inspiration_ideas`. Abel, 25 Sep 2026: "understand what videos he's
/// making and give the user inspirational videos to post, like VidIQ."
///
/// `because` is not a summary somebody wrote: it is an insight's own sentence,
/// copied across by the function that made the idea. `measured` says whether
/// there were any numbers behind it at all -- a brand-new account gets ideas
/// from its chosen themes, and the card says so rather than implying an
/// audience finding nobody has earned yet.
struct InspirationIdea: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let key: String
    /// The first line of the video.
    let hook: String
    /// One sentence on what the rest of it shows.
    let angle: String
    let because: String
    let measured: Bool
    let seconds: Int?
    let format: String?
    let hashtags: [String]

    /// What gets typed into the video page when somebody taps this.
    var brief: String {
        var text = "\(hook)\n\n\(angle)"
        if let seconds { text += "\n\nAbout \(seconds) seconds." }
        return text
    }

    enum CodingKeys: String, CodingKey {
        case id, key, hook, angle, because, measured, seconds, format, hashtags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        hook = try container.decodeIfPresent(String.self, forKey: .hook) ?? ""
        angle = try container.decodeIfPresent(String.self, forKey: .angle) ?? ""
        because = try container.decodeIfPresent(String.self, forKey: .because) ?? ""
        measured = try container.decodeIfPresent(Bool.self, forKey: .measured) ?? false
        seconds = try container.decodeIfPresent(Int.self, forKey: .seconds)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        hashtags = try container.decodeIfPresent([String].self, forKey: .hashtags) ?? []
    }
}
