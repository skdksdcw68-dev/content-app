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
    /// How its videos get made (0058). Nil on a style without one.
    let workflow: Workflow?

    struct Pillar: Decodable, Hashable, Sendable {
        let name: String
        let detail: String?
    }

    struct Workflow: Decodable, Hashable, Sendable {
        let format: String?
        let structure: [String]?
        let shots: Int?
        let voice: String?
        let text: String?
        let music: String?
        let hooks: [String]?
        let durationSeconds: Int?
        /// How every video gets made, the way the app explains it.
        let steps: [String]?

        private enum CodingKeys: String, CodingKey {
            case format, structure, shots, voice, text, music, hooks, steps
            case durationSeconds = "duration_s"
        }
    }

    /// The picture for the tile, by the style's asset name or the
    /// convention `style-<slug>`, whichever exists.
    var artName: String { art ?? "style-\(slug)" }

    private enum CodingKeys: String, CodingKey {
        case slug, name, tagline, category, symbol, art, pillars, workflow
        case visualStyle = "visual_style"
    }
}
