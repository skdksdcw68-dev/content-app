import SwiftUI
import UIKit

/// Everything the composer is set to make, in one value.
///
/// Abel, 25 Sep 2026, with fifteen screenshots of ElevenLabs: "i want it to
/// match the exact eleven labs thing... lets go match the video and image
/// generator thing to exactly that."
///
/// Their shape is worth copying for a reason beyond taste. The six knobs that
/// change what you get are on the bar, always visible, in one fixed order, and
/// everything else lives behind the sliders icon. Autocast had three chips in
/// no particular order -- a stepper, "Voiceover", "Captions" -- and the model,
/// the count and the aspect ratio were nowhere at all.
struct GenerateChoices: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case image, video
        var id: String { rawValue }
        var title: String { self == .image ? "Image" : "Video" }
        /// The glyph on the bar, which is also how you tell which mode you are
        /// in without reading anything.
        var symbol: String { self == .image ? "photo" : "play.rectangle" }
        var capability: String { self == .image ? "image_generation" : "video_generation" }
    }

    var mode: Mode = .video
    /// Nil until something is chosen, and then the bar shows its name.
    var model: ModelChoice?
    /// How many come back at once. ElevenLabs defaults to 4 for images and 1
    /// for video, which is the right instinct: four images is a choice, four
    /// videos is a bill.
    var imageCount: Int = 4
    var videoCount: Int = 1
    var seconds: Int = 5
    var aspect: String = "9:16"
    var resolution: String = "720p"
    var audio: Bool = true
    var negative: String = ""

    // Autocast's own, which ElevenLabs has no equivalent of. They belong in
    // the settings sheet rather than the bar: the bar is for what changes the
    // shape of the thing, and these change what is said in it.
    var voiceover: Bool = true
    var captions: Bool = true

    /// The first and last frame, as storage paths.
    ///
    /// 🔴 One each, not a pile. Abel, 26 Sep 2026: "while uploaded end and
    /// start frame, our accepts whatever amount 😂😂😂 bit see the elevven
    /// labs when uploaded." All three pills opened the same picker with
    /// `maxSelectionCount: 4`, so "Start frame" could take four pictures and
    /// none of them was the start frame in particular -- they all landed in
    /// the same list and the model got whichever came first.
    ///
    /// A frame is a slot with one thing in it. Filling it again replaces what
    /// was there, which is what the pill showing a thumbnail and an × means.
    var startFrame: FramePick?
    var endFrame: FramePick?

    /// A picture in a frame slot: where it lives, and what to draw on the pill.
    struct FramePick: Equatable {
        let path: String
        let preview: UIImage
    }

    /// Start and end, in the order an adapter reads them.
    var frames: [String] {
        [startFrame?.path, endFrame?.path].compactMap { $0 }
    }

    /// What this exact request would cost, in credits.
    ///
    /// Abel, 26 Sep 2026: "for generating videos and images make sure the send
    /// button has the credits thing also". Now possible to answer honestly,
    /// because fal publishes a rate per second and per image and the adapter
    /// works the job out from the length and the count -- so this is the real
    /// number, not a tier somebody guessed at.
    ///
    /// The unit is deliberately not a dollar. Nobody wants to see $0.003 on a
    /// button, and the price we pay is not the price we charge; a credit is
    /// Autocast's own money, and the rate between them is one constant to
    /// change when the pricing is settled.
    static func credits(from cost: ModelCost?) -> Int? {
        guard let amount = cost?.amount, cost?.unit == "usd" else { return nil }
        // A tenth of a cent each, so the cheapest image is 3 and a long Veo
        // clip is a few thousand -- the range people already read on other
        // generators, and granular enough that nothing rounds to zero.
        return max(1, Int((amount * 1000).rounded()))
    }

    var count: Int {
        get { mode == .image ? imageCount : videoCount }
        set { if mode == .image { imageCount = newValue } else { videoCount = newValue } }
    }

    var isVideo: Bool { mode == .video }

    /// What travels with the request, so the agent reads the choices and the
    /// person can see in the transcript what they asked for.
    var spec: String {
        var parts: [String] = []
        if isVideo { parts.append("\(seconds) seconds") }
        parts.append(aspect)
        if isVideo {
            parts.append(voiceover ? "with a voiceover" : "no voiceover")
            if captions { parts.append("with captions") }
            if !audio { parts.append("no sound") }
        }
        if count > 1 { parts.append("\(count) versions") }
        if let model { parts.append("using \(model.label)") }
        let trimmed = negative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append("avoid: \(trimmed)") }
        return "(\(parts.joined(separator: ", ")))"
    }

    /// What the quote and the job are told.
    ///
    /// `generate_audio` travels as an extra because it is the single biggest
    /// cost lever we have: Veo 3.1 is $0.40 a second with sound and $0.20
    /// without. Sent explicitly rather than left to the model's own default,
    /// which is on -- and therefore the expensive one.
    var settings: GenerationSettings {
        GenerationSettings(
            resolution: isVideo ? resolution : nil,
            duration: isVideo ? Double(seconds) : nil,
            quality: nil,
            extras: isVideo ? ["generate_audio": audio ? "true" : "false"] : [:]
        )
    }
}

// MARK: - Who made a model

/// The maker behind a model name, for the tile beside it.
///
/// ElevenLabs puts Google's and OpenAI's own marks in the list, which is what
/// makes forty models scannable -- you find the row by its colour before you
/// read a word. Autocast cannot ship other companies' logos, so this is the
/// maker's initial on its own colour: the same scanning job, nothing borrowed.
///
/// The mapping is fact, not guesswork: Veo and Nano Banana are Google's, Sora
/// and GPT Image are OpenAI's, Seedance and Seedream are ByteDance's.
struct ModelMaker: Equatable {
    let name: String
    /// Whose site carries the real mark. The tile fetches its favicon.
    var domain: String = "fal.ai"
    let tint: Color

    static func of(_ model: ModelChoice) -> ModelMaker {
        let haystack = "\(model.family ?? "") \(model.label) \(model.externalId)".lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { haystack.contains($0) } }

        if has(["veo", "nano banana", "nano_banana", "imagen", "gemini"]) {
            return ModelMaker(name: "Google", domain: "google.com", tint: Color(red: 0.26, green: 0.52, blue: 0.96))
        }
        if has(["sora", "gpt image", "gpt_image", "dall"]) {
            return ModelMaker(name: "OpenAI", domain: "openai.com", tint: Color(red: 0.06, green: 0.65, blue: 0.53))
        }
        if has(["seedance", "seedream", "bytedance", "seed audio", "seed_audio"]) {
            return ModelMaker(name: "ByteDance", domain: "bytedance.com", tint: Color(red: 0.00, green: 0.63, blue: 0.85))
        }
        if has(["kling"]) {
            return ModelMaker(name: "Kling", domain: "klingai.com", tint: Color(red: 0.95, green: 0.43, blue: 0.20))
        }
        if has(["wan", "qwen"]) {
            return ModelMaker(name: "Alibaba", domain: "alibaba.com", tint: Color(red: 0.98, green: 0.51, blue: 0.09))
        }
        if has(["minimax", "hailuo"]) {
            return ModelMaker(name: "MiniMax", domain: "minimaxi.com", tint: Color(red: 0.42, green: 0.36, blue: 0.91))
        }
        if has(["grok"]) {
            return ModelMaker(name: "xAI", domain: "x.ai", tint: Color(red: 0.35, green: 0.35, blue: 0.38))
        }
        if has(["topaz"]) {
            return ModelMaker(name: "Topaz", domain: "topazlabs.com", tint: Color(red: 0.12, green: 0.55, blue: 0.62))
        }
        if has(["recraft"]) {
            return ModelMaker(name: "Recraft", domain: "recraft.ai", tint: Color(red: 0.85, green: 0.25, blue: 0.45))
        }
        if has(["elevenlabs", "inworld", "mirelo", "sonilo"]) {
            return ModelMaker(name: "Audio", domain: "elevenlabs.io", tint: Color(red: 0.55, green: 0.35, blue: 0.85))
        }
        // Higgsfield's own -- Soul, Genjutsu, Marketing Studio, and anything
        // else it fronts without naming a maker.
        return ModelMaker(name: "Higgsfield", domain: "higgsfield.ai", tint: Color(red: 0.45, green: 0.40, blue: 0.95))
    }

    /// Two letters at most, so the tile never has to shrink its type.
    var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)) }
        return String(name.prefix(1))
    }
}

/// The maker's tile beside a model, the size ElevenLabs draws it.
///
/// 🔴 The real mark now, not initials. Abel, 26 Sep 2026: "the model choosing
/// logost too make it real." The mark is each maker's own favicon, fetched
/// from their own site at runtime and kept — so nothing trademarked ships in
/// the bundle, and a maker changing their mark changes ours. The tinted
/// initials stay underneath as the first frame and the fallback, because a
/// grey square while a favicon loads is a list that flickers.
struct ModelMakerMark: View {
    let maker: ModelMaker
    var side: CGFloat = 44

    @State private var mark: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
            .fill(
                mark != nil
                    ? AnyShapeStyle(Color(uiColor: .systemBackground))
                    : AnyShapeStyle(LinearGradient(
                        colors: [maker.tint.opacity(0.95), maker.tint.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
            .frame(width: side, height: side)
            .overlay {
                if let mark {
                    Image(uiImage: mark)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.62, height: side * 0.62)
                } else {
                    Text(maker.initials)
                        .font(.system(size: side * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
                    .strokeBorder(Color.primary.opacity(mark != nil ? 0.08 : 0), lineWidth: 1)
            )
            .task(id: maker.domain) { mark = await MakerMarks.mark(for: maker) }
            .accessibilityLabel(maker.name)
    }
}

/// Fetches and keeps the makers' marks. One fetch per maker per install --
/// they land in `MediaCache` like any other picture.
enum MakerMarks {
    @MainActor static func mark(for maker: ModelMaker) async -> UIImage? {
        let key = MediaCache.key("maker-mark", maker.domain)
        if let known = MediaCache.shared.image(key) { return known }
        // Google's favicon service, which resolves any domain's mark at a
        // usable size and answers from cache at their edge. Failing quietly
        // leaves the initials tile, which is the whole reason it exists.
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(maker.domain)&sz=128"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data),
              image.size.width > 16 else { return nil }
        MediaCache.shared.keep(image, key)
        return image
    }
}
