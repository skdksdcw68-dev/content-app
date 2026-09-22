import SwiftUI
import PhotosUI
import Photos
import AVKit

/// TikTok's post screen, after the editor (Abel's screenshots, 18 Sep 2026):
/// the description on the left with the cover on the right (Preview / Edit
/// cover), "# Hashtags" and "@ Mention" under it -- typing either shows
/// suggestions in place of the rows, as TikTok does -- then "Everyone can view
/// this post" and "More options" as plain rows, and Drafts / Post at the
/// bottom. The one addition is a small ✨ in the description's corner.
///
/// A connected account is all it needs -- no brand setup, no plan. The file
/// from the editor goes up as rendered.
struct ComposeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    enum Sending { case post, drafts }

    /// The finished video from the editor.
    let movieURL: URL
    /// The music's credit, when the editor used a library track.
    let attribution: String?
    /// They chose a TikTok sound, which can only be added in TikTok: Drafts.
    let preferDrafts: Bool

    init(video: URL, attribution: String? = nil, preferDrafts: Bool = false) {
        movieURL = video
        self.attribution = attribution
        self.preferDrafts = preferDrafts
        _caption = State(initialValue: attribution.map { "\n\n" + $0 } ?? "")
    }

    // The video
    @State private var facts: VideoFacts?
    @State private var poster: UIImage?
    @State private var uploadTask: Task<String, Error>?
    @State private var path: String?

    // The post
    @State private var caption: String
    @State private var writing = false
    @FocusState private var typing: Bool
    @State private var aiTags: [String] = []
    @State private var info: CreatorInfo?
    @State private var privacy: String?
    @State private var scheduled = false
    @State private var scheduleAt = Date().addingTimeInterval(3600)
    // Starting values from Profile → Post defaults.
    @State private var allowComments = PostDefaults.allowComments
    @State private var allowReuse = PostDefaults.allowReuse
    @State private var isAIGC = PostDefaults.aiLabel
    @State private var disclose = false
    @State private var yourBrand = false
    @State private var brandedContent = false
    @State private var saveToDevice = PostDefaults.saveToPhotos
    @State private var coverMs: Int?
    /// The accounts this post goes to.
    @State private var destinations: Set<UUID> = []
    // YouTube and Instagram's own settings.
    @State private var youtubeTitle = ""
    @State private var youtubeVisibility = "PUBLIC_TO_EVERYONE"
    @State private var instagramOwnCaption = false
    @State private var instagramCaption = ""

    // Sheets
    @State private var showingCover = false

    // Sending
    @State private var sending: Sending?
    @State private var problems: [ValidationReport.Check] = []
    @State private var composed: (signature: String, post: ComposedPost)?
    @State private var done: UUID?

    var body: some View {
        details
            .task { await loadVideo() }
            .task { await loadAccount() }
            .navigationDestination(item: $done) { id in
                PostDetailView(postID: id)
            }
    }

    // MARK: - The post screen

    /// A native form: the cover and the words first, then who sees it, when,
    /// and the settings -- each in its own grouped section, standard sizes.
    private var details: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    cover
                    TextField("Describe your video", text: $caption, axis: .vertical)
                        .lineLimit(6...12)
                        .focused($typing)
                }
                .padding(.vertical, 4)

                Button {
                    Task { await writeWithAI() }
                } label: {
                    HStack {
                        Label(writing ? "Writing…" : "Improve with AI", systemImage: "sparkles")
                        Spacer()
                        if writing { ProgressView() }
                    }
                }
                .disabled(writing || (caption.isEmpty && facts == nil))
            } footer: {
                Text("\(caption.count)/2200 · AI rewrites your words and adds hashtags. It never adds claims you didn't make.")
            }

            if let token = activeToken, !suggestions(for: token).isEmpty {
                Section("Suggestions") {
                    ForEach(suggestions(for: token), id: \.self) { tag in
                        Button {
                            complete(token, with: tag)
                        } label: {
                            LabeledContent(tag, value: aiTags.contains(tag) ? "Suggested" : "Used before")
                        }
                        .tint(.primary)
                    }
                }
            }

            if !problems.isEmpty {
                Section {
                    ForEach(problems) { check in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title)
                                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Fix before posting")
                }
            }

            if preferDrafts {
                Section {
                    Label("To add a TikTok sound, choose Drafts. The video opens in TikTok to finish.", systemImage: "music.note")
                        .font(.subheadline)
                }
            }

            Section {
                ForEach(accounts) { account in
                    Toggle(isOn: Binding(
                        get: { destinations.contains(account.id) },
                        set: { on in
                            if on { destinations.insert(account.id) } else { destinations.remove(account.id) }
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.platform.networkName)
                                Text(account.label).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            SettingsIcon(account.platform.symbolName)
                        }
                    }
                }
            } header: {
                Text("Post to")
            } footer: {
                if accounts.isEmpty {
                    Text("Connect an account in Profile → Accounts first.")
                }
            }

            if chosenTikTok != nil {
                Section {
                    Picker("Who can view", selection: Binding(
                        get: { privacy ?? info?.privacyOptions.first ?? "SELF_ONLY" },
                        set: { privacy = $0 }
                    )) {
                        ForEach(info?.privacyOptions ?? [], id: \.self) { option in
                            Text(CreatorInfo.label(for: option)).tag(option)
                        }
                    }
                    .disabled(info == nil)
                    Toggle("Allow comments", isOn: $allowComments)
                        .disabled(info?.commentDisabled == true)
                    Toggle("Allow Duet and Stitch", isOn: $allowReuse)
                        .disabled(info?.duetDisabled == true && info?.stitchDisabled == true)
                    NavigationLink {
                        DisclosureView(privacy: privacy, disclose: $disclose, yourBrand: $yourBrand, brandedContent: $brandedContent)
                    } label: {
                        LabeledContent("Content disclosure", value: disclose ? "On" : "Off")
                    }
                } header: {
                    platformHeader(.tiktok)
                } footer: {
                    Text("By posting, you agree to TikTok’s Music Usage Confirmation.")
                }
            }

            if chosen(.shorts) {
                Section {
                    TextField("Title", text: $youtubeTitle, prompt: Text(defaultTitle))
                    Picker("Visibility", selection: $youtubeVisibility) {
                        Text("Public").tag("PUBLIC_TO_EVERYONE")
                        Text("Unlisted").tag("FOLLOWER_OF_CREATOR")
                        Text("Private").tag("SELF_ONLY")
                    }
                } header: {
                    platformHeader(.shorts)
                } footer: {
                    Text("Your description goes under the video. While Google reviews Autocast, YouTube keeps uploads private.")
                }
            }

            if chosen(.reels) {
                Section {
                    Toggle("Different caption for Instagram", isOn: $instagramOwnCaption)
                    if instagramOwnCaption {
                        TextField("Instagram caption", text: $instagramCaption, axis: .vertical)
                            .lineLimit(3...8)
                    }
                } header: {
                    platformHeader(.reels)
                } footer: {
                    Text("Shared as a Reel to your profile and the Reels tab. Reels are public.")
                }
            }

            Section("When") {
                Toggle("Schedule for later", isOn: $scheduled)
                if scheduled {
                    DatePicker("Post at", selection: $scheduleAt, in: Date().addingTimeInterval(120)...,
                               displayedComponents: [.date, .hourAndMinute])
                }
            }

            Section {
                Toggle("AI-generated content", isOn: $isAIGC)
                Toggle("Save to Photos", isOn: $saveToDevice)
            } footer: {
                Text("Sent in original quality, never re-compressed. The AI label goes to TikTok and YouTube.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("New post")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("#") { insert("#") }
                Button("@") { insert("@") }
                Button {
                    Task { await writeWithAI() }
                } label: {
                    Image(systemName: "sparkles")
                }
                .disabled(writing)
                Spacer()
                Button("Done") { typing = false }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showingCover) {
            if let facts {
                CoverPicker(url: movieURL, duration: facts.duration, chosenMs: $coverMs, poster: $poster)
            }
        }
    }

    /// The cover, big enough to see, with a clear Edit Cover button under it.
    private var cover: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.track
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 96, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button("Edit Cover") { showingCover = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(facts == nil)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Drafts is TikTok's inbox, so it only appears when TikTok is chosen.
            if chosenTikTok != nil {
                Button {
                    Task { await send(.drafts) }
                } label: {
                    HStack(spacing: 6) {
                        if sending == .drafts { ProgressView() } else { Image(systemName: "tray.and.arrow.down") }
                        Text("Drafts")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }

            Button {
                Task { await send(.post) }
            } label: {
                HStack(spacing: 6) {
                    if sending == .post { ProgressView().tint(Theme.onAccent) }
                    Text(scheduled ? "Schedule" : "Post")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
        }
        .disabled(sending != nil || facts == nil || (chosenTikTok != nil && info == nil) || destinations.isEmpty)
        .padding(.horizontal, Style.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Actions

    private func insert(_ symbol: String) {
        if !caption.isEmpty && !caption.hasSuffix(" ") && !caption.hasSuffix("\n") { caption += " " }
        caption += symbol
        typing = true
    }

    /// Every account that can post right now.
    private var accounts: [PlatformConnection] {
        session.connections.filter(\.isHealthy)
            .sorted { ($0.platform == .tiktok ? 0 : 1) < ($1.platform == .tiktok ? 0 : 1) }
    }

    private func chosen(_ platform: Platform) -> Bool {
        accounts.contains { $0.platform == platform && destinations.contains($0.id) }
    }

    private func platformHeader(_ platform: Platform) -> some View {
        Label(platform.networkName, systemImage: platform.symbolName)
    }

    /// YouTube's title when none is typed: the caption's first line.
    private var defaultTitle: String {
        let line = caption.split(separator: "\n").first.map(String.init) ?? ""
        let words = line.split(separator: " ").filter { !$0.hasPrefix("#") }.joined(separator: " ")
        return words.isEmpty ? "Title" : String(words.prefix(100))
    }

    /// Each account's own caption, where it differs from the shared one.
    private var captionOverrides: [UUID: String] {
        var result: [UUID: String] = [:]
        for account in accounts where destinations.contains(account.id) {
            switch account.platform {
            case .shorts:
                let title = youtubeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { result[account.id] = title + "\n\n" + caption }
            case .reels:
                let own = instagramCaption.trimmingCharacters(in: .whitespacesAndNewlines)
                if instagramOwnCaption && !own.isEmpty { result[account.id] = own }
            case .tiktok:
                break
            }
        }
        return result
    }

    private var chosenTikTok: PlatformConnection? {
        accounts.first { $0.platform == .tiktok && destinations.contains($0.id) }
    }

    private func loadAccount() async {
        // Everything connected starts switched on.
        if destinations.isEmpty { destinations = Set(accounts.map(\.id)) }
        // The audience and interaction settings follow TikTok when it is
        // chosen (it has the most choices), otherwise the first account.
        guard info == nil, let connection = chosenTikTok ?? accounts.first(where: { destinations.contains($0.id) }) else { return }
        guard let fetched = await session.creatorInfo(for: connection.id) else { return }
        info = fetched
        privacy = PostDefaults.privacy(from: fetched.privacyOptions)
        // A default never switches on what the account has turned off.
        allowComments = PostDefaults.allowComments && !fetched.commentDisabled
        allowReuse = PostDefaults.allowReuse && !(fetched.duetDisabled && fetched.stitchDisabled)
    }

    private func loadVideo() async {
        guard facts == nil else { return }
        do {
            let read = try await VideoFacts.read(movieURL)
            facts = read
            poster = read.poster
            // Upload while they write, so Post is quick.
            let url = movieURL
            let task = Task { try await session.uploadVideo(at: url) }
            uploadTask = task
            path = try? await task.value
        } catch {
            session.lastError = "That video couldn't be read."
        }
    }

    // MARK: - # and @ suggestions

    /// The word being typed, when it starts with # or @.
    private var activeToken: String? {
        guard let last = caption.last, last != " ", last != "\n",
              let word = caption.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
              let first = word.first, first == "#" || first == "@" else { return nil }
        return String(word)
    }

    private func suggestions(for token: String) -> [String] {
        let typed = token.lowercased()
        let pool = token.hasPrefix("#") ? aiTags + TagMemory.tags : TagMemory.mentions
        var seen = Set<String>()
        return Array(pool.filter { tag in
            let lower = tag.lowercased()
            return lower.hasPrefix(typed) && lower != typed && seen.insert(lower).inserted
        }.prefix(8))
    }

    private func complete(_ token: String, with value: String) {
        guard caption.hasSuffix(token) else { return }
        caption = String(caption.dropLast(token.count)) + value + " "
    }

    /// Save to device: the rendered video into Photos.
    static func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private func writeWithAI() async {
        writing = true
        defer { writing = false }
        do {
            let result = try await session.writeCaption(caption, hashtags: [], frames: facts?.frames ?? [])
            aiTags = result.hashtags
            let existing = Set(caption.split(separator: " ").map { $0.lowercased() }.filter { $0.hasPrefix("#") })
            let tags = result.hashtags.filter { !existing.contains($0.lowercased()) && !result.caption.lowercased().contains($0.lowercased()) }
            withAnimation(.snappy(duration: 0.25)) {
                caption = tags.isEmpty ? result.caption : result.caption + "\n\n" + tags.joined(separator: " ")
            }
        } catch {
            session.lastError = session.readableMessage(error)
        }
    }

    private func signature(_ mode: Sending) -> String {
        [caption, String(coverMs ?? 0), mode == .drafts ? "d" : "p",
         destinations.map(\.uuidString).sorted().joined(separator: ","),
         youtubeTitle, instagramOwnCaption ? instagramCaption : ""].joined(separator: "|")
    }

    private func send(_ mode: Sending) async {
        guard let facts else { return }
        sending = mode
        problems = []
        let drafts = mode == .drafts

        // On Home as a tile that says "Uploading" from this moment until the
        // post exists (Abel, 22 Sep 2026), rather than a spinner in here.
        let upload = AppSession.LocalUpload(poster: poster, caption: caption)
        session.uploads.append(upload)
        defer {
            sending = nil
            session.uploads.removeAll { $0.id == upload.id }
        }

        do {
            if path == nil {
                if let uploadTask, let finished = try? await uploadTask.value {
                    path = finished
                } else {
                    path = try await session.uploadVideo(at: movieURL)
                }
            }
            guard let path else { return }

            // Same words as last time: check again rather than make a second post.
            let post: ComposedPost
            let checks: [ValidationReport.Check]
            if let existing = composed, existing.signature == signature(mode) {
                post = existing.post
                checks = try await session.validate(post: existing.post.postId, toDrafts: drafts).checks
            } else {
                // Drafts goes to TikTok alone.
                let chosen = drafts ? [chosenTikTok?.id].compactMap { $0 } : Array(destinations)
                post = try await session.compose(
                    path: path, video: facts, caption: caption, hashtags: [],
                    coverMs: coverMs, toDrafts: drafts, connections: chosen,
                    captions: drafts ? [:] : captionOverrides
                )
                composed = (signature(mode), post)
                checks = post.checks
            }

            let blocking = checks.filter { !$0.ok && $0.key != "time" }
            guard blocking.isEmpty else {
                withAnimation(.snappy(duration: 0.25)) { problems = blocking }
                return
            }

            let options = info?.privacyOptions ?? post.privacyOptions
            let chosenPrivacy = drafts
                ? (options.contains("SELF_ONLY") ? "SELF_ONLY" : (options.first ?? "SELF_ONLY"))
                : (privacy ?? options.first ?? "SELF_ONLY")

            // Each account is approved with the settings it understands.
            let targets = post.targets ?? [ComposedPost.Target(id: post.postTargetId, platform: "tiktok")]
            var approvedAny = false
            for target in targets {
                let isTikTok = target.platform == "tiktok"
                let targetPrivacy: String
                switch target.platform {
                case "reels": targetPrivacy = "PUBLIC_TO_EVERYONE"
                case "shorts": targetPrivacy = youtubeVisibility
                default: targetPrivacy = chosenPrivacy
                }
                let outcome = await session.approve(
                    postTargetID: target.id,
                    privacy: targetPrivacy,
                    disableComment: !allowComments,
                    disableDuet: isTikTok ? !allowReuse : true,
                    disableStitch: isTikTok ? !allowReuse : true,
                    isAIGC: isAIGC,
                    runAt: scheduled && !drafts ? scheduleAt : nil,
                    postNow: drafts || !scheduled,
                    toDrafts: drafts && isTikTok,
                    brandContent: isTikTok && disclose && brandedContent && !drafts,
                    brandOrganic: isTikTok && disclose && yourBrand && !drafts
                )
                if outcome != nil { approvedAny = true }
            }
            guard approvedAny else { return }
            TagMemory.remember(caption)
            if saveToDevice { await Self.saveToPhotos(movieURL) }
            done = post.postId
        } catch {
            session.lastError = session.readableMessage(error)
        }
    }
}

private struct DisclosureView: View {
    let privacy: String?
    @Binding var disclose: Bool
    @Binding var yourBrand: Bool
    @Binding var brandedContent: Bool

    var body: some View {
        List {
            Section {
                Toggle("Disclose post content", isOn: $disclose)
            } footer: {
                Text("Turn on to disclose that this post promotes goods or services in exchange for something of value.")
            }
            if disclose {
                Section {
                    Toggle(isOn: $yourBrand) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your brand")
                            Text("You are promoting yourself or your own business.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $brandedContent) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Branded content")
                            Text(privacy == "SELF_ONLY"
                                 ? "Not available when only you can view the post."
                                 : "You are promoting another brand or a third party.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(privacy == "SELF_ONLY")
                }
            }
        }
        .navigationTitle("Content disclosure and ads")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Cover

/// Pick the frame people see before they tap.
private struct CoverPicker: View {
    let url: URL
    let duration: Double
    @Binding var chosenMs: Int?
    @Binding var poster: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var at: Double = 0
    @State private var frame: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black)
                    if let frame {
                        Image(uiImage: frame).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Slider(value: $at, in: 0...max(0.1, duration))
                Text(String(format: "%.1fs", at))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(Style.gutter)
            .navigationTitle("Edit cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        chosenMs = Int(at * 1000)
                        if let frame { poster = frame }
                        dismiss()
                    }
                }
            }
            .task(id: at) {
                try? await Task.sleep(for: .milliseconds(120))
                frame = await Self.image(url, at)
            }
            .onAppear { at = Double(chosenMs ?? 0) / 1000 }
        }
    }

    static func image(_ url: URL, _ seconds: Double) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let cg = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Remembering tags

/// Hashtags and @mentions used before, kept on the phone for suggestions.
enum TagMemory {
    private static let tagsKey = "compose.tags"
    private static let mentionsKey = "compose.mentions"

    static var tags: [String] { UserDefaults.standard.stringArray(forKey: tagsKey) ?? [] }
    static var mentions: [String] { UserDefaults.standard.stringArray(forKey: mentionsKey) ?? [] }

    static func remember(_ caption: String) {
        let words = caption.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        store(words.filter { $0.hasPrefix("#") && $0.count > 1 }, tagsKey)
        store(words.filter { $0.hasPrefix("@") && $0.count > 1 }, mentionsKey)
    }

    private static func store(_ new: [String], _ key: String) {
        guard !new.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        for item in new.reversed() {
            list.removeAll { $0.lowercased() == item.lowercased() }
            list.insert(item, at: 0)
        }
        UserDefaults.standard.set(Array(list.prefix(60)), forKey: key)
    }
}
