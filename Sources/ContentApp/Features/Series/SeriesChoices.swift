import Foundation

// What Start a series asks about how the videos come out: how they look, who
// speaks over them, how the words show on screen, and in what language.
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
    /// The ElevenLabs voice that speaks it. Nil for nobody, and for "decide
    /// for me", where the voice is picked per video.
    var elevenLabsID: String? = nil
    /// ElevenLabs' own public sample of that voice, so it can be heard before
    /// it is chosen rather than imagined from an adjective.
    var sample: URL? = nil

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
        // Each one is a real ElevenLabs voice. Abel, 31 Oct 2026, after
        // hearing the paid voice next to free ones: "it's clear the paid is
        // better."
        SeriesVoice(
            id: "warm_female", name: "Warm female", detail: "Friendly and conversational",
            symbol: "waveform", sentence: "a warm, friendly, conversational female voice",
            elevenLabsID: "jqcCZkN6Knx8BJ5TBdYR",
            sample: URL(string: "https://storage.googleapis.com/eleven-public-prod/database/user/XKwEw9ihVRMYSZkGwKydUfpES0B3/voices/jqcCZkN6Knx8BJ5TBdYR/JKHbp9CMKBoqcDFfzWIf.mp3")
        ),
        SeriesVoice(
            id: "upbeat_female", name: "Upbeat female", detail: "Bright and energetic",
            symbol: "waveform.badge.plus", sentence: "a bright, upbeat, energetic female voice",
            elevenLabsID: "Y2pP8eXRDH19yyV1Tslt",
            sample: URL(string: "https://storage.googleapis.com/eleven-public-prod/database/workspace/a00f6e0482e844af8e53e744905b121f/voices/Y2pP8eXRDH19yyV1Tslt/ufALidAEgwwGpsini9ss.mp3")
        ),
        SeriesVoice(
            id: "calm_male", name: "Calm male", detail: "Steady and easy to trust",
            symbol: "waveform.path", sentence: "a calm, steady, trustworthy male voice",
            elevenLabsID: "TyhbGdmkFuKkLJookqy9",
            sample: URL(string: "https://storage.googleapis.com/eleven-public-prod/database/workspace/95e05f5eba13487ca7bece7a56027bff/voices/TyhbGdmkFuKkLJookqy9/f5b7a272-85cf-47ea-92e0-cb2080c61e81.mp3")
        ),
        SeriesVoice(
            id: "deep_male", name: "Deep male", detail: "Authoritative, like a trailer",
            symbol: "waveform.badge.mic", sentence: "a deep, authoritative male voice, like a film trailer",
            elevenLabsID: "mq6RH3bgBY9BDzvWeMZk",
            sample: URL(string: "https://storage.googleapis.com/eleven-public-prod/database/workspace/9722ac9e4b8847bdb33efaada6390532/voices/mq6RH3bgBY9BDzvWeMZk/R2rjb2MmWHjeDjxCNjHX.mp3")
        ),
        SeriesVoice(
            id: "casual_male", name: "Casual male", detail: "Relaxed, like a friend",
            symbol: "message", sentence: "a relaxed, casual male voice, like a friend talking",
            elevenLabsID: "snODv2VnG1inLn1Ba0dk",
            sample: URL(string: "https://storage.googleapis.com/eleven-public-prod/database/workspace/77466a60c55e4e4cbbd21b401cf2bf34/voices/snODv2VnG1inLn1Ba0dk/A30tVZgPkRNLlfUKsdrs.mp3")
        ),
        SeriesVoice(
            id: "storyteller", name: "Storyteller", detail: "Slow and gripping",
            symbol: "book", sentence: "a slow, gripping storyteller's voice with pauses for effect",
            elevenLabsID: "acrqYoDVmcpJemOxjC39",
            sample: URL(string: "https://storage.googleapis.com/eleven-public-prod/database/user/user_9701ke9g8xefebrt7j2pphkg808g/voices/acrqYoDVmcpJemOxjC39/yVl8SdkVGLti2cVjc5FG.mp3")
        ),
    ]
}

// MARK: - Captions

/// How the spoken words are burned into the picture. Six, so the two-column
/// grid has no stranded tile.
///
/// The id is all the server needs: the renderer holds each style's font, size,
/// colour and position, and draws them from the voice-over's word timings. The
/// tile only has to look enough like the result to be chosen from.
struct SeriesCaption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String

    var isNone: Bool { id == "none" }

    static let all: [SeriesCaption] = [
        SeriesCaption(id: "bold_pop", name: "Bold pop", detail: "One big word at a time"),
        SeriesCaption(id: "highlight", name: "Highlight", detail: "The spoken word lights up"),
        SeriesCaption(id: "minimal", name: "Minimal", detail: "Small and out of the way"),
        SeriesCaption(id: "subtitle", name: "Subtitles", detail: "Full lines at the bottom"),
        SeriesCaption(id: "boxed", name: "Boxed", detail: "Words on a white card"),
        SeriesCaption(id: "none", name: "No captions", detail: "Just the picture"),
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
