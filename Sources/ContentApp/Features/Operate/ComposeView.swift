import SwiftUI
import PhotosUI
import AVKit

/// Posting, in TikTok's own order (Abel's screenshots, 18 Sep 2026):
/// pick the video → watch it full screen → Next → the post screen.
///
/// The post screen is TikTok's: the description on the left with the cover on
/// the right (Preview / Edit cover), "# Hashtags" and "@ Mention" under it,
/// then "Everyone can view this post" and "More options" as plain rows, and
/// Drafts / Post at the bottom. The one addition is a small ✨ in the corner
/// of the description: it rewrites your words and puts hashtags in the text,
/// the way TikTok keeps them.
///
/// A connected account is all it needs -- no brand setup, no plan. The file
/// goes up as recorded.
struct ComposeView: View {
    @Environment(AppSession.self) private var session

    enum Phase { case preview, details }
    enum Sending { case post, drafts }

    // The video
    @State private var phase: Phase = .preview
    @State private var picking = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var movieURL: URL?
    @State private var facts: VideoFacts?
    @State private var poster: UIImage?
    @State private var player: AVPlayer?
    @State private var uploadTask: Task<String, Error>?
    @State private var path: String?

    // The post
    @State private var caption = ""
    @State private var writing = false
    @FocusState private var typing: Bool
    @State private var info: CreatorInfo?
    @State private var privacy: String?
    @State private var scheduled = false
    @State private var scheduleAt = Date().addingTimeInterval(3600)
    @State private var allowComments = true
    @State private var allowReuse = true
    @State private var isAIGC = false
    @State private var disclose = false
    @State private var yourBrand = false
    @State private var brandedContent = false
    @State private var coverMs: Int?

    // Sheets
    @State private var choosingAudience = false
    @State private var choosingTime = false
    @State private var showingMore = false
    @State private var showingCover = false

    // Sending
    @State private var sending: Sending?
    @State private var problems: [ValidationReport.Check] = []
    @State private var composed: (signature: String, post: ComposedPost)?
    @State private var done: UUID?

    var body: some View {
        Group {
            switch phase {
            case .preview: preview
            case .details: details
            }
        }
        .photosPicker(isPresented: $picking, selection: $pickerItem, matching: .videos)
        .task(id: pickerItem) { await loadPicked() }
        .task { await loadAccount() }
        .task {
            // Straight to the camera roll, after the push has finished.
            guard facts == nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            picking = true
        }
        .navigationDestination(item: $done) { id in
            PostDetailView(postID: id)
        }
    }

    // MARK: - 1. Preview

    private var preview: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 90)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if facts == nil {
                VStack(spacing: 14) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 34, weight: .light))
                    Button("Choose a video") { picking = true }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        picking = true
                    } label: {
                        Text("Change")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(.white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Button {
                        player?.pause()
                        withAnimation(.snappy(duration: 0.25)) { phase = .details }
                    } label: {
                        Text("Next")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .disabled(facts == nil)
                }
                .buttonStyle(SoftPressStyle())
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
    }

    // MARK: - 2. The post screen

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                descriptionArea
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                HStack(spacing: 10) {
                    chip("#", "Hashtags") { insert("#") }
                    chip("@", "Mention") { insert("@") }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Divider().padding(.top, 18)

                if !problems.isEmpty {
                    problemsList
                    Divider()
                }

                row("globe", audienceTitle) { choosingAudience = true }
                row("clock", scheduled ? "Scheduled · \(scheduleAt.formatted(date: .abbreviated, time: .shortened))" : "Post now") {
                    choosingTime = true
                }
                row("ellipsis.circle", "More options") { showingMore = true }

                Text("By posting, you agree to TikTok's Music Usage Confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { phase = .preview }
                } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .accessibilityLabel("Back to the video")
            }
        }
        .navigationBarBackButtonHidden(true)
        .pushedPage()
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $choosingAudience) { audienceSheet }
        .sheet(isPresented: $choosingTime) { timeSheet }
        .sheet(isPresented: $showingMore) { MoreOptionsSheet(
            info: info, privacy: privacy,
            allowComments: $allowComments, allowReuse: $allowReuse, isAIGC: $isAIGC,
            disclose: $disclose, yourBrand: $yourBrand, brandedContent: $brandedContent
        ) }
        .sheet(isPresented: $showingCover) {
            if let movieURL, let facts {
                CoverPicker(url: movieURL, duration: facts.duration, chosenMs: $coverMs, poster: $poster)
            }
        }
    }

    /// The description, borderless, with the cover beside it and the small
    /// ✨ in its corner.
    private var descriptionArea: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                TextField("Add description...", text: $caption, axis: .vertical)
                    .font(.system(size: 17))
                    .lineLimit(7...14)
                    .focused($typing)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Button {
                    Task { await writeWithAI() }
                } label: {
                    Group {
                        if writing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(Color.track, in: Circle())
                    .foregroundStyle(Color.primary)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(writing || (caption.isEmpty && facts == nil))
                .accessibilityLabel("Improve with AI")
            }

            cover
        }
    }

    private var cover: some View {
        Button { showingCover = true } label: {
            ZStack {
                Color.track
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                }
                VStack {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Spacer()
                    Text("Edit cover")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)
                }
                .background(
                    LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.35)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
            .frame(width: 118, height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
    }

    private func chip(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(symbol).font(.system(size: 17, weight: .bold))
                Text(title).font(.system(size: 16, weight: .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Color.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(SoftPressStyle())
    }

    private func row(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 17))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var audienceTitle: String {
        switch privacy {
        case "PUBLIC_TO_EVERYONE":    "Everyone can view this post"
        case "MUTUAL_FOLLOW_FRIENDS": "Friends can view this post"
        case "FOLLOWER_OF_CREATOR":   "Followers can view this post"
        case "SELF_ONLY":             "Only you can view this post"
        default:                      "Who can view this post"
        }
    }

    private var problemsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(problems) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.subheadline.weight(.semibold))
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await send(.drafts) }
            } label: {
                HStack(spacing: 8) {
                    if sending == .drafts { ProgressView() } else { Image(systemName: "tray") }
                    Text("Drafts")
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.track, in: Capsule())
                .foregroundStyle(Color.primary)
            }
            Button {
                Task { await send(.post) }
            } label: {
                HStack(spacing: 8) {
                    if sending == .post {
                        ProgressView().tint(Theme.onAccent)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    Text(scheduled ? "Schedule" : "Post")
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(Theme.onAccent)
            }
        }
        .buttonStyle(SoftPressStyle())
        .disabled(sending != nil || facts == nil || info == nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Sheets

    private var audienceSheet: some View {
        NavigationStack {
            List {
                ForEach(info?.privacyOptions ?? [], id: \.self) { option in
                    Button {
                        privacy = option
                        choosingAudience = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CreatorInfo.label(for: option)).foregroundStyle(Color.primary)
                                Text(CreatorInfo.detail(for: option)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if privacy == option {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Who can view this post")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private var timeSheet: some View {
        NavigationStack {
            Form {
                Toggle("Schedule for later", isOn: $scheduled)
                if scheduled {
                    DatePicker("Post at", selection: $scheduleAt, in: Date().addingTimeInterval(120)...,
                               displayedComponents: [.date, .hourAndMinute])
                }
            }
            .navigationTitle("When")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingTime = false } }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func insert(_ symbol: String) {
        if !caption.isEmpty && !caption.hasSuffix(" ") && !caption.hasSuffix("\n") { caption += " " }
        caption += symbol
        typing = true
    }

    private func loadAccount() async {
        guard info == nil, let connection = session.connections.first(where: \.isHealthy) else { return }
        guard let fetched = await session.creatorInfo(for: connection.id) else { return }
        info = fetched
        privacy = fetched.privacyOptions.contains("PUBLIC_TO_EVERYONE") ? "PUBLIC_TO_EVERYONE" : fetched.privacyOptions.first
        allowComments = !fetched.commentDisabled
        allowReuse = !(fetched.duetDisabled && fetched.stitchDisabled)
    }

    private func loadPicked() async {
        guard let pickerItem else { return }
        do {
            guard let movie = try await pickerItem.loadTransferable(type: Movie.self) else { return }
            if let old = movieURL { try? FileManager.default.removeItem(at: old) }
            movieURL = movie.url
            let read = try await VideoFacts.read(movie.url)
            facts = read
            poster = read.poster
            coverMs = nil
            composed = nil
            problems = []
            path = nil
            let next = AVPlayer(url: movie.url)
            player = next
            phase = .preview
            next.play()
            // Upload while they watch and write, so Post is quick.
            let url = movie.url
            let task = Task { try await session.uploadVideo(at: url) }
            uploadTask = task
            path = try? await task.value
        } catch {
            session.lastError = "That video couldn't be read."
        }
    }

    private func writeWithAI() async {
        writing = true
        defer { writing = false }
        do {
            let result = try await session.writeCaption(caption, hashtags: [], frames: facts?.frames ?? [])
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
        [caption, String(coverMs ?? 0), mode == .drafts ? "d" : "p"].joined(separator: "|")
    }

    private func send(_ mode: Sending) async {
        guard let facts else { picking = true; return }
        sending = mode
        defer { sending = nil }
        problems = []
        let drafts = mode == .drafts

        do {
            if path == nil {
                if let uploadTask, let finished = try? await uploadTask.value {
                    path = finished
                } else if let movieURL {
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
                post = try await session.compose(
                    path: path, video: facts, caption: caption, hashtags: [],
                    coverMs: coverMs, toDrafts: drafts
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

            let outcome = await session.approve(
                postTargetID: post.postTargetId,
                privacy: chosenPrivacy,
                disableComment: !allowComments,
                disableDuet: !allowReuse,
                disableStitch: !allowReuse,
                isAIGC: isAIGC,
                runAt: scheduled && !drafts ? scheduleAt : nil,
                postNow: drafts || !scheduled,
                toDrafts: drafts,
                brandContent: disclose && brandedContent && !drafts,
                brandOrganic: disclose && yourBrand && !drafts
            )
            guard outcome != nil else { return }
            player?.pause()
            done = post.postId
        } catch {
            session.lastError = session.readableMessage(error)
        }
    }
}

// MARK: - More options

/// TikTok's More options sheet: privacy settings, then advanced settings.
private struct MoreOptionsSheet: View {
    let info: CreatorInfo?
    let privacy: String?
    @Binding var allowComments: Bool
    @Binding var allowReuse: Bool
    @Binding var isAIGC: Bool
    @Binding var disclose: Bool
    @Binding var yourBrand: Bool
    @Binding var brandedContent: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy settings") {
                    toggleRow("bubble.left", "Allow comments", nil, $allowComments)
                        .disabled(info?.commentDisabled == true)
                    toggleRow("play.square.stack", "Allow reuse of content", "Duet and Stitch", $allowReuse)
                        .disabled(info?.duetDisabled == true && info?.stitchDisabled == true)
                }
                Section("Advanced settings") {
                    NavigationLink {
                        DisclosureView(privacy: privacy, disclose: $disclose, yourBrand: $yourBrand, brandedContent: $brandedContent)
                    } label: {
                        Label("Content disclosure and ads", systemImage: "megaphone")
                    }
                    toggleRow("wand.and.stars", "AI-generated content",
                              "Add this label to tell viewers your content was generated or edited with AI.", $isAIGC)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkles.tv").frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("High-quality upload")
                            Text("Autocast always sends your original file, never re-compressed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("More options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func toggleRow(_ symbol: String, _ title: String, _ detail: String?, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
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
