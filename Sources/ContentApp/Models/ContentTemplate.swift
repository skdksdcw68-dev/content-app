import Foundation

/// A content style, from the catalogue (`content_templates`, 0057): what a
/// series is made of. Chosen the way a website template is chosen -- the
/// brief and the themes are its, the account is yours.
struct ContentTemplate: Identifiable, Decodable, Hashable, Sendable {
    var id: String { slug }
    let slug: String
    let name: String
    let tagline: String
    let category: String
    /// An SF Symbol for the tile until there is a picture.
    let symbol: String
    /// The picture's asset name, once there is one.
    let art: String?
    let pillars: [Pillar]
    let visualStyle: String

    struct Pillar: Decodable, Hashable, Sendable {
        let name: String
        let detail: String?
    }

    /// The picture for the tile, by the style's asset name or the
    /// convention `style-<slug>`, whichever exists.
    var artName: String { art ?? "style-\(slug)" }

    private enum CodingKeys: String, CodingKey {
        case slug, name, tagline, category, symbol, art, pillars
        case visualStyle = "visual_style"
    }
}
