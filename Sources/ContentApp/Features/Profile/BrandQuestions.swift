import Foundation

/// Everything the Brand page asks, beyond the three sentences.
///
/// Abel, 19 Sep 2026: the Brand page "should have a lots of selections and
/// questions, like onboarding". Same shape as onboarding's questions, so one
/// picker draws all of them. Each answer is saved with its title and labels
/// into `brands.profile`, and the planner and caption writer read them as
/// PREFERENCES -- how to write -- never as facts about the product.
enum BrandQuestions {
    /// Voice lives in `brand_settings.tone` as well, because the planner
    /// already reads it there. Reused from onboarding so the two agree.
    static var voice: OnboardingQuestion { OnboardingQuestion.voice }

    static let goal = OnboardingQuestion(
        id: "goal",
        title: "Main goal",
        subtitle: "What your posts are for. Pick up to three.",
        selection: .multiple,
        options: [
            .init(id: "downloads", label: "App downloads", symbol: "arrow.down.app"),
            .init(id: "signups", label: "Sign-ups", symbol: "person.badge.plus"),
            .init(id: "sales", label: "Sales", symbol: "cart"),
            .init(id: "followers", label: "Followers", symbol: "person.3"),
            .init(id: "awareness", label: "Getting known", symbol: "megaphone"),
            .init(id: "community", label: "Community", symbol: "bubble.left.and.bubble.right"),
            .init(id: "traffic", label: "Website visits", symbol: "safari"),
        ]
    )

    static let category = OnboardingQuestion(
        id: "category",
        title: "What it is",
        subtitle: "The kind of thing you're marketing.",
        selection: .single,
        options: OnboardingQuestion.product.options
    )

    static let audience = OnboardingQuestion(
        id: "audience",
        title: "Audience",
        subtitle: "Who you're talking to. Pick as many as fit.",
        selection: .multiple,
        options: OnboardingQuestion.audience.options + [
            .init(id: "fitness", label: "Fitness and health", symbol: "figure.run"),
            .init(id: "fashion", label: "Fashion lovers", symbol: "tshirt"),
            .init(id: "foodies", label: "Food lovers", symbol: "fork.knife"),
        ]
    )

    static let ages = OnboardingQuestion(
        id: "ages",
        title: "Age range",
        subtitle: "Roughly how old your audience is.",
        selection: .multiple,
        options: [
            .init(id: "13-17", label: "13–17", symbol: "person"),
            .init(id: "18-24", label: "18–24", symbol: "person"),
            .init(id: "25-34", label: "25–34", symbol: "person"),
            .init(id: "35-44", label: "35–44", symbol: "person"),
            .init(id: "45+", label: "45 and over", symbol: "person"),
        ]
    )

    static let styles = OnboardingQuestion(
        id: "styles",
        title: "Content styles",
        subtitle: "The kinds of videos you want. Pick as many as you like.",
        selection: .multiple,
        options: [
            .init(id: "howto", label: "How-to and tutorials", symbol: "list.number"),
            .init(id: "tips", label: "Tips and tricks", symbol: "lightbulb"),
            .init(id: "demo", label: "Product demos", symbol: "iphone"),
            .init(id: "bts", label: "Behind the scenes", symbol: "video"),
            .init(id: "story", label: "Storytelling", symbol: "book"),
            .init(id: "trends", label: "Trends and memes", symbol: "flame"),
            .init(id: "beforeafter", label: "Before and after", symbol: "arrow.left.arrow.right"),
            .init(id: "myths", label: "Myth busting", symbol: "xmark.seal"),
            .init(id: "dayinlife", label: "Day in the life", symbol: "sun.max"),
            .init(id: "compare", label: "Comparisons", symbol: "scalemass"),
            .init(id: "qa", label: "Questions and answers", symbol: "questionmark.bubble"),
            .init(id: "pov", label: "POV skits", symbol: "theatermasks"),
        ]
    )

    static let formats = OnboardingQuestion(
        id: "formats",
        title: "Video formats",
        subtitle: "How your videos are usually made.",
        selection: .multiple,
        options: [
            .init(id: "screen", label: "Screen recording", symbol: "record.circle"),
            .init(id: "talking", label: "Talking to camera", symbol: "person.crop.square"),
            .init(id: "voiceover", label: "Voiceover with clips", symbol: "waveform"),
            .init(id: "text", label: "Text on screen", symbol: "textformat"),
            .init(id: "slideshow", label: "Photo slideshow", symbol: "photo.on.rectangle"),
            .init(id: "faceless", label: "No face, visuals only", symbol: "eye.slash"),
            .init(id: "ai", label: "AI-made visuals", symbol: "wand.and.stars"),
        ]
    )

    static let length = OnboardingQuestion(
        id: "length",
        title: "Video length",
        subtitle: "How long your videos usually are.",
        selection: .single,
        options: [
            .init(id: "short", label: "Short, under 15 seconds", symbol: "hare"),
            .init(id: "medium", label: "Medium, 15–30 seconds", symbol: "timer"),
            .init(id: "long", label: "Longer, 30–60 seconds", symbol: "tortoise"),
            .init(id: "mixed", label: "A mix", symbol: "shuffle"),
        ]
    )

    static let cta = OnboardingQuestion(
        id: "cta",
        title: "Call to action",
        subtitle: "What you ask viewers to do at the end.",
        selection: .single,
        options: [
            .init(id: "download", label: "Download the app", symbol: "arrow.down.app"),
            .init(id: "bio", label: "Link in bio", symbol: "link"),
            .init(id: "follow", label: "Follow for more", symbol: "person.badge.plus"),
            .init(id: "comment", label: "Comment", symbol: "text.bubble"),
            .init(id: "share", label: "Share or save", symbol: "square.and.arrow.up"),
            .init(id: "none", label: "No call to action", symbol: "nosign"),
        ]
    )

    static let emoji = OnboardingQuestion(
        id: "emoji",
        title: "Emoji",
        subtitle: "How many emoji in captions.",
        selection: .single,
        options: [
            .init(id: "none", label: "None", symbol: "circle.slash"),
            .init(id: "few", label: "A few", symbol: "face.smiling"),
            .init(id: "lots", label: "Lots", symbol: "sparkles"),
        ]
    )

    static let hashtags = OnboardingQuestion(
        id: "hashtags",
        title: "Hashtags",
        subtitle: "How many hashtags per post.",
        selection: .single,
        options: [
            .init(id: "none", label: "None", symbol: "circle.slash"),
            .init(id: "few", label: "2–3", symbol: "number"),
            .init(id: "more", label: "4–6", symbol: "number.square"),
        ]
    )

    static let language = OnboardingQuestion(
        id: "language",
        title: "Language",
        subtitle: "The language captions are written in.",
        selection: .single,
        options: [
            .init(id: "en", label: "English", symbol: "globe"),
            .init(id: "es", label: "Spanish", symbol: "globe"),
            .init(id: "fr", label: "French", symbol: "globe"),
            .init(id: "de", label: "German", symbol: "globe"),
            .init(id: "pt", label: "Portuguese", symbol: "globe"),
            .init(id: "ar", label: "Arabic", symbol: "globe"),
            .init(id: "am", label: "Amharic", symbol: "globe"),
            .init(id: "hi", label: "Hindi", symbol: "globe"),
        ]
    )

    /// In the order the page shows them, grouped.
    static let audienceGroup: [OnboardingQuestion] = [category, goal, audience, ages]
    static let contentGroup: [OnboardingQuestion] = [styles, formats, length]
    static let writingGroup: [OnboardingQuestion] = [cta, emoji, hashtags, language]

    /// Free-text answers, saved into the same profile.
    struct TextQuestion: Identifiable, Hashable {
        let id: String
        let title: String
        let placeholder: String
    }

    static let texts: [TextQuestion] = [
        .init(id: "always", title: "Always mention", placeholder: "Words or phrases to include"),
        .init(id: "avoid", title: "Never mention", placeholder: "Topics or words to stay away from"),
        .init(id: "link", title: "Where to send people", placeholder: "App Store link, website…"),
    ]
}
