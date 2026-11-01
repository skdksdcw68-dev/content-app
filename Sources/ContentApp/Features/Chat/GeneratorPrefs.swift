import Foundation

/// What the generator makes when nobody says otherwise: the model, how many
/// pictures, their shape and quality, and a video's length and resolution.
///
/// Abel, 1 Nov 2026, on the card that asked for a model and a quality every
/// time: "i hate the way it also sends the sheets ... even after u told it use
/// this and generate it, it still asks". The Grok way: set once behind the
/// sliders in the bar, never asked per request. What a message says wins ("2
/// of these, square"). Kept on the phone and sent with every message; the
/// server reads it when it starts a job (agent-chat `produce`), and fits each
/// value to the model it ends up using.
struct GeneratorPrefs: Codable, Equatable {
    /// A model's `externalId`; nil lets Autocast choose.
    var imageModel: String?
    var imageModelLabel: String?
    var imageCount: Int
    var imageAspect: String
    var imageQuality: String
    var videoModel: String?
    var videoModelLabel: String?
    var videoSeconds: Int
    var videoResolution: String
    var videoAspect: String

    init() {
        imageCount = 1
        imageAspect = "3:4"
        imageQuality = "Medium"
        videoSeconds = 5
        videoResolution = "720p"
        videoAspect = "9:16"
    }

    static let counts = [1, 2, 4]
    static let imageShapes = ["9:16", "3:4", "1:1", "4:3", "16:9"]
    static let qualities = ["Low", "Medium", "High"]
    static let lengths = [5, 10]
    static let resolutions = ["720p", "1080p"]

    private static let key = "generatorPrefs.v1"

    /// Read fresh each time: the sheet writes, the next message reads.
    static var current: GeneratorPrefs {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let prefs = try? JSONDecoder().decode(GeneratorPrefs.self, from: data)
            else { return GeneratorPrefs() }
            return prefs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    /// As the server reads it (`prefs` on agent-chat's body).
    var payload: [String: Any] {
        var image: [String: Any] = ["count": imageCount, "aspect_ratio": imageAspect, "resolution": imageQuality]
        if let imageModel { image["model"] = imageModel }
        var video: [String: Any] = ["duration": videoSeconds, "resolution": videoResolution, "aspect_ratio": videoAspect]
        if let videoModel { video["model"] = videoModel }
        return ["image": image, "video": video]
    }
}
