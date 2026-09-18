import SwiftUI

/// What the post screen starts with, so the same switches are not flipped on
/// every video. Kept on this phone: they are habits, not account data.
///
/// The post screen still shows every one of them and can change them for that
/// post -- TikTok requires the choice be visible each time -- and a default
/// the account does not allow (comments off at TikTok, say) never wins.
enum PostDefaults {
    static let privacyKey = "postDefaults.privacy"
    static let allowCommentsKey = "postDefaults.allowComments"
    static let allowReuseKey = "postDefaults.allowReuse"
    static let aiLabelKey = "postDefaults.aiLabel"
    static let saveToPhotosKey = "postDefaults.saveToPhotos"

    private static var store: UserDefaults { .standard }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? fallback
    }

    static var privacy: String { store.string(forKey: privacyKey) ?? "PUBLIC_TO_EVERYONE" }
    static var allowComments: Bool { bool(allowCommentsKey, true) }
    static var allowReuse: Bool { bool(allowReuseKey, true) }
    static var aiLabel: Bool { bool(aiLabelKey, false) }
    static var saveToPhotos: Bool { bool(saveToPhotosKey, false) }

    /// The one privacy to start on: the default if this account offers it,
    /// otherwise public if offered, otherwise the first it does offer.
    static func privacy(from offered: [String]) -> String? {
        if offered.contains(privacy) { return privacy }
        if offered.contains("PUBLIC_TO_EVERYONE") { return "PUBLIC_TO_EVERYONE" }
        return offered.first
    }

    static let privacyChoices: [(value: String, title: String)] = [
        ("PUBLIC_TO_EVERYONE", "Everyone"),
        ("MUTUAL_FOLLOW_FRIENDS", "Friends"),
        ("FOLLOWER_OF_CREATOR", "Followers"),
        ("SELF_ONLY", "Only you"),
    ]
}

struct PostDefaultsView: View {
    @AppStorage(PostDefaults.privacyKey) private var privacy = "PUBLIC_TO_EVERYONE"
    @AppStorage(PostDefaults.allowCommentsKey) private var allowComments = true
    @AppStorage(PostDefaults.allowReuseKey) private var allowReuse = true
    @AppStorage(PostDefaults.aiLabelKey) private var aiLabel = false
    @AppStorage(PostDefaults.saveToPhotosKey) private var saveToPhotos = false

    var body: some View {
        Form {
            Section {
                Picker("Who can watch", selection: $privacy) {
                    ForEach(PostDefaults.privacyChoices, id: \.value) { choice in
                        Text(choice.title).tag(choice.value)
                    }
                }
            } footer: {
                Text("If your account doesn’t offer this, the post starts on what it does offer.")
            }

            Section("Interactions") {
                Toggle("Allow comments", isOn: $allowComments)
                Toggle("Allow Duet and Stitch", isOn: $allowReuse)
            }

            Section {
                Toggle("Label as AI-generated", isOn: $aiLabel)
            } footer: {
                Text("Turn this on if your videos are mostly made with AI.")
            }

            Section {
                Toggle("Save a copy to Photos", isOn: $saveToPhotos)
            }
        }
        .navigationTitle("Post defaults")
        .navigationBarTitleDisplayMode(.inline)
    }
}
