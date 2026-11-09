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
    /// A sample video, from the server (0101) when it has one.
    let serverPreview: URL?

    /// The sample to watch before picking it: the server's link, or the one
    /// built into this build for the three proven formats (Abel, 5 Nov 2026:
    /// "hardcode all the videos ... unless we change them from the server").
    var previewURL: URL? {
        serverPreview ?? Self.builtInPreviews[slug].flatMap(URL.init(string:))
    }

    /// The sample built into this build for a proven format, by its slug: for
    /// places that show a format without having loaded the templates.
    static func builtInPreview(for slug: String) -> URL? {
        builtInPreviews[slug].flatMap(URL.init(string:))
    }

    private static let builtInPreviews: [String: String] = [
        "facts": "https://dosszkllkassvyprkhrg.supabase.co/storage/v1/object/public/samples/formats/facts.mp4",
        "scary": "https://dosszkllkassvyprkhrg.supabase.co/storage/v1/object/public/samples/formats/scary.mp4",
        "motivation": "https://dosszkllkassvyprkhrg.supabase.co/storage/v1/object/public/samples/formats/motivation.mp4",
    ]

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
        /// "drawn": the renderer draws the video itself (no pictures, no
        /// captions). `drawn` says which kind: "showdown" or "glow".
        let engine: String?
        let drawn: String?

        private enum CodingKeys: String, CodingKey {
            case format, structure, shots, voice, text, music, hooks, steps, engine, drawn
            case durationSeconds = "duration_s"
        }
    }

    /// A code-drawn format: no look, no captions, and no cost guess shown.
    var isDrawn: Bool { workflow?.engine == "drawn" }
    /// Whether anybody speaks in it. A normal format always does; a drawn one
    /// only when its workflow says narration.
    var hasVoice: Bool { !isDrawn || workflow?.voice == "narration" }
    /// The Stickman showdown is always 20 s; the length is not the person's to set.
    var hasFixedLength: Bool { isDrawn && workflow?.drawn == "showdown" }

    /// The picture for the tile, by the style's asset name or the
    /// convention `style-<slug>`, whichever exists.
    var artName: String { art ?? "style-\(slug)" }

    /// Whether somebody has to point a camera at themselves for this.
    ///
    /// A `talking_head` style cannot be made by a generator: it is a person
    /// speaking, and that person is the owner. The series still works -- it
    /// writes the script and schedules the slot -- but the video is filmed,
    /// not generated, so the flow says so before it is chosen rather than
    /// leaving somebody waiting for a video that will never appear
    /// (24 Sep 2026, when Founder diary, Fitness and Hot takes became
    /// talking-head styles).
    var needsFilming: Bool { workflow?.format == "talking_head" }

    private enum CodingKeys: String, CodingKey {
        case slug, name, tagline, category, symbol, art, pillars, workflow
        case visualStyle = "visual_style"
        case serverPreview = "preview_url"
    }
}
