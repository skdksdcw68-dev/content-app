import Foundation

// What Start a series asks about how the videos come out: how they look, who
// speaks over them, and in what language.
//
// Abel, 29 Sep 2026: after the platform and the seconds, "it should ask me for
// the video style it wants with pictures. I must put that... and then
// something that asks me for a voiceover. It must be a requirement."
//
// These are not decoration. Each one is sent to the writer (`propose-plan`),
// stored on the plan (`content_plans.look / voice / language`, 0075), and used
// again for every later post, because a series writes one post at a time.

// MARK: - Look

/// How every shot is drawn. Twelve, so the two-column grid has no stranded
/// tile, and each has a picture: the same barista, poured in twelve looks, so
/// the tiles can be compared rather than imagined.
struct SeriesLook: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// The line under the name.
    let tagline: String
    /// What the writer is told about every shot.
    let prompt: String

    /// The tile's picture, `look-<id>` in the asset catalogue.
    var artName: String { "look-\(id)" }

    /// The one line the server stores and the writer reads.
    var sentence: String { "\(name) -- \(prompt)" }

    static let all: [SeriesLook] = [
        SeriesLook(
            id: "cinematic", name: "Cinematic", tagline: "Film grade, shallow focus",
            prompt: "cinematic film look, shallow depth of field, anamorphic bokeh, warm teal-and-orange grade, slow deliberate camera moves"
        ),
        SeriesLook(
            id: "realistic", name: "Realistic", tagline: "Natural, like a phone shot",
            prompt: "photorealistic, natural daylight, handheld smartphone realism, true-to-life colour"
        ),
        SeriesLook(
            id: "anime", name: "Anime", tagline: "Cel-shaded and painterly",
            prompt: "anime style, cel-shaded, clean bold outlines, painterly skies, expressive characters"
        ),
        SeriesLook(
            id: "animated3d", name: "3D animated", tagline: "Soft light, round shapes",
            prompt: "stylised 3D animation, soft global illumination, rounded friendly shapes, glossy materials"
        ),
        SeriesLook(
            id: "cartoon", name: "Cartoon", tagline: "Flat, bold and bouncy",
            prompt: "flat 2D cartoon, thick outlines, bright flat colours, playful bouncy motion"
        ),
        SeriesLook(
            id: "clay", name: "Claymation", tagline: "Handmade stop-motion",
            prompt: "stop-motion claymation, visible fingerprints in the clay, handmade miniature sets, slightly jittery frame rate"
        ),
        SeriesLook(
            id: "watercolour", name: "Watercolour", tagline: "Soft washes on paper",
            prompt: "watercolour illustration, soft bleeding washes, visible paper texture, loose ink lines, gentle motion"
        ),
        SeriesLook(
            id: "neon", name: "Neon night", tagline: "Rain, magenta and cyan",
            prompt: "neon-lit night city, rain reflections, magenta and cyan glow, futuristic mood"
        ),
        SeriesLook(
            id: "vintage", name: "Vintage film", tagline: "Grain and light leaks",
            prompt: "vintage 8mm film, heavy grain, light leaks, faded warm colours, 1970s feel"
        ),
        SeriesLook(
            id: "minimal", name: "Minimal", tagline: "Clean shapes, lots of space",
            prompt: "clean minimal motion graphics, flat geometric shapes, limited palette, lots of white space"
        ),
        SeriesLook(
            id: "comic", name: "Comic book", tagline: "Bold ink, halftone dots",
            prompt: "comic book panels, bold black ink, halftone dot shading, dynamic angles, limited bright colours"
        ),
        SeriesLook(
            id: "documentary", name: "Documentary", tagline: "Honest and unposed",
            prompt: "documentary style, handheld, natural available light, muted realistic colours, real locations"
        ),
    ]
}

// MARK: - Voice

/// Who speaks over the video. A required answer, because "does it have a
/// voice?" changes what is written: a voiced video needs a script, a silent
/// one needs its words on the screen.
struct SeriesVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    /// What the writer is told. Begins with "none" when nobody speaks.
    let sentence: String

    var isNone: Bool { id == "none" }

    static let all: [SeriesVoice] = [
        SeriesVoice(
            id: "none", name: "No voiceover", detail: "Music and words on screen",
            symbol: "speaker.slash", sentence: "none"
        ),
        SeriesVoice(
            id: "decide", name: "Decide for me", detail: "Each video gets the voice that suits it",
            symbol: "sparkles",
            sentence: "a voice chosen per video to suit it -- warm, upbeat, calm or deep"
        ),
        SeriesVoice(
            id: "warm_female", name: "Warm female", detail: "Friendly and conversational",
            symbol: "waveform", sentence: "a warm, friendly, conversational female voice"
        ),
        SeriesVoice(
            id: "upbeat_female", name: "Upbeat female", detail: "Bright and energetic",
            symbol: "waveform.badge.plus", sentence: "a bright, upbeat, energetic female voice"
        ),
        SeriesVoice(
            id: "calm_male", name: "Calm male", detail: "Steady and easy to trust",
            symbol: "waveform.path", sentence: "a calm, steady, trustworthy male voice"
        ),
        SeriesVoice(
            id: "deep_male", name: "Deep male", detail: "Authoritative, like a trailer",
            symbol: "waveform.badge.mic", sentence: "a deep, authoritative male voice, like a film trailer"
        ),
        SeriesVoice(
            id: "casual_male", name: "Casual male", detail: "Relaxed, like a friend",
            symbol: "message", sentence: "a relaxed, casual male voice, like a friend talking"
        ),
        SeriesVoice(
            id: "storyteller", name: "Storyteller", detail: "Slow and gripping",
            symbol: "book", sentence: "a slow, gripping storyteller's voice with pauses for effect"
        ),
    ]
}

// MARK: - Language

/// What the words are in: the hook, the caption, the hashtags and anything
/// spoken. Ten, for the same even-grid reason as the looks.
struct SeriesLanguage: Identifiable, Hashable, Sendable {
    let id: String
    /// In the language itself, so it can be found by someone who reads it.
    let native: String
    /// What the writer is told.
    let english: String

    static let all: [SeriesLanguage] = [
        SeriesLanguage(id: "english", native: "English", english: "English"),
        SeriesLanguage(id: "spanish", native: "Español", english: "Spanish"),
        SeriesLanguage(id: "french", native: "Français", english: "French"),
        SeriesLanguage(id: "german", native: "Deutsch", english: "German"),
        SeriesLanguage(id: "portuguese", native: "Português", english: "Portuguese"),
        SeriesLanguage(id: "italian", native: "Italiano", english: "Italian"),
        SeriesLanguage(id: "arabic", native: "العربية", english: "Arabic"),
        SeriesLanguage(id: "hindi", native: "हिन्दी", english: "Hindi"),
        SeriesLanguage(id: "turkish", native: "Türkçe", english: "Turkish"),
        SeriesLanguage(id: "indonesian", native: "Bahasa Indonesia", english: "Indonesian"),
    ]
}
