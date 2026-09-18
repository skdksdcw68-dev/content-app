import SwiftUI
import PhotosUI
import AVFoundation

/// Posting, the way TikTok's own post screen works -- your words, your tags,
/// your cover, who can see it, when -- with one thing TikTok does not have:
/// Write with AI, which makes your caption better and adds hashtags without
/// inventing anything.
///
/// A connected account is all it needs (Abel, 18 Sep 2026): no brand setup,
/// no plan. The file goes up as recorded -- no re-compression -- and after
/// Post the post screen shows it moving through Publishing, Verifying,
/// Published from the rows the scheduler writes.
struct ComposeView: View {
    @Environment(AppSession.self) private var session

    enum Sending { case post, drafts }
    enum When: Hashable { case now, later }

    // The video
    @State private var picking = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var movieURL: URL?
    @State private var facts: VideoFacts?
    @State private var poster: UIImage?
    @State private var uploadTask: Task<String, Error>?
    @State private var path: String?
    @State private var uploadFailed: String?

    // The words
    @State private var caption = ""
    @State private var hashtags: [String] = []
    @State private var writing = false
    @FocusState private var typing: Bool

    // The account and its options
    @State private var info: CreatorInfo?
    @State private var privacy: String?
    @State private var when: When = .now
    @State private var scheduleAt = Date().addingTimeInterval(3600)
    @State private var allowComments = true
    @State private var allowDuet = true
    @State private var allowStitch = true
    @State private var isAIGC = false
    @State private var disclose = false
    @State private var yourBrand = false
    @State private var brandedContent = false
    @State private var coverMs: Int?
    @State private var showingMore = false
    @State private var showingCover = false

    // Sending
    @State private var sending: Sending?
    @State private var problems: [ValidationReport.Check] = []
    @State private var composed: (signature: String, post: ComposedPost)?
    @State private var done: UUID?

    private var hasVideo: Bool { facts != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                editor
                accountRow
                options
                if !problems.isEmpty { problemsCard }
                footnote
            }
            .screenGutter()
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("New post")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .safeAreaInset(edge: .bottom) { actionBar }
        .photosPicker(isPresented: $picking, selection: $pickerItem, matching: .videos)
        .task(id: pickerItem) { await loadPicked() }
        .task { await loadAccount() }
        .task {
            // Straight to the camera roll, like TikTok opens on the camera --
            // after the push has finished, or the picker never appears.
            guard !hasVideo else { return }
            try? await Task.sleep(for: .milliseconds(450))
            picking = true
        }
        .sheet(isPresented: $showingMore) { moreOptions }
        .sheet(isPresented: $showingCover) {
            if let movieURL, let facts {
                CoverPicker(url: movieURL, duration: facts.duration, chosenMs: $coverMs, poster: $poster)
            }
        }
        .navigationDestination(item: $done) { id in
            PostDetailView(postID: id)
        }
    }

    // MARK: - Editor

    /// The caption, the tags and the tools all live in one box, with the cover
    /// beside it -- TikTok's arrangement.
    private var editor: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Add a description…", text: $caption, axis: .vertical)
                    .lineLimit(5...12)
                    .font(.body)
                    .focused($typing)

                if !hashtags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(hashtags, id: \.self) { tag in
                            tagChip(tag)
                        }
                    }
                }

                toolRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            cover
        }
        .padding(14)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
            Button {
                hashtags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .accessibilityLabel("Remove \(tag)")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08), in: Capsule())
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            toolButton("#", "Hashtags") { insert("#") }
            toolButton("@", "Mention") { insert("@") }
            Spacer(minLength: 0)
            Button {
                Task { await writeWithAI() }
            } label: {
                HStack(spacing: 5) {
                    if writing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                    }
                    Text(writing ? "Writing…" : "Write with AI")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(SoftPressStyle())
            .disabled(writing || (caption.isEmpty && !hasVideo))
        }
    }

    private func toolButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(symbol).font(.caption.weight(.bold))
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.track, in: Capsule())
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(SoftPressStyle())
    }

    private var cover: some View {
        Button {
            if hasVideo { showingCover = true } else { picking = true }
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.track)
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.badge.plus").font(.system(size: 22, weight: .medium))
                        Text("Add video").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
                }
                if hasVideo {
                    VStack(spacing: 0) {
                        uploadBadge
                        Spacer()
                        Text("Edit cover")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45))
                    }
                }
            }
            .frame(width: 104, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
    }

    @ViewBuilder
    private var uploadBadge: some View {
        HStack {
            Spacer()
            Group {
                if uploadFailed != nil {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                } else if path == nil {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.system(size: 14))
            .padding(5)
            .background(.black.opacity(0.35), in: Circle())
            .padding(5)
        }
    }

    // MARK: - Account and options

    private var accountRow: some View {
        HStack(spacing: 10) {
            AsyncImage(url: info?.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.track)
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Posting to").font(.caption).foregroundStyle(.secondary)
                Text(info.map { "@\($0.username)" } ?? (session.connections.first?.label ?? "TikTok"))
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Image(systemName: "music.note").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var options: some View {
        VStack(spacing: 0) {
            optionRow("globe", "Who can see this") {
                Menu {
                    ForEach(info?.privacyOptions ?? [], id: \.self) { option in
                        Button(CreatorInfo.label(for: option)) { privacy = option }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(privacy.map { CreatorInfo.label(for: $0) } ?? "Choose")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline)
                }
                .disabled(info == nil)
            }
            Divider().padding(.leading, 44)
            optionRow("clock", "When") {
                Picker("When", selection: $when) {
                    Text("Now").tag(When.now)
                    Text("Schedule").tag(When.later)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            if when == .later {
                DatePicker("Post at", selection: $scheduleAt, in: Date().addingTimeInterval(120)..., displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline)
                    .padding(.leading, 44)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
            }
            Divider().padding(.leading, 44)
            Button { showingMore = true } label: {
                optionRow("gearshape", "More options") {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 44)
            optionRow("sparkles.tv", "Original quality") {
                Text("Sent as recorded").font(.caption).foregroundStyle(.secondary)
            }
        }
        .background(Color.raised, in: RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }

    private func optionRow<Trailing: View>(_ symbol: String, _ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 22)
                .foregroundStyle(.primary)
            Text(title).font(.subheadline)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var moreOptions: some View {
        NavigationStack {
            Form {
                Section("Privacy settings") {
                    Toggle("Allow comments", isOn: $allowComments).disabled(info?.commentDisabled == true)
                    Toggle("Allow Duet", isOn: $allowDuet).disabled(info?.duetDisabled == true)
                    Toggle("Allow Stitch", isOn: $allowStitch).disabled(info?.stitchDisabled == true)
                }
                Section {
                    Toggle("AI-generated content", isOn: $isAIGC)
                } footer: {
                    Text("Adds TikTok's label telling viewers the content was generated or edited with AI.")
                }
                Section {
                    Toggle("Disclose post content", isOn: $disclose)
                    if disclose {
                        Toggle("Your brand", isOn: $yourBrand)
                        Toggle("Branded content", isOn: $brandedContent)
                            .disabled(privacy == "SELF_ONLY")
                    }
                } footer: {
                    Text(disclose
                         ? (privacy == "SELF_ONLY"
                            ? "Branded content can't be private. Your brand: you're promoting yourself or your own business."
                            : "Your brand: promoting yourself or your own business. Branded content: promoting someone else in exchange for something.")
                         : "Turn on if this promotes a brand, product or service.")
                }
            }
            .navigationTitle("More options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMore = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var problemsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fix before posting", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            ForEach(problems) { check in
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title).font(.subheadline.weight(.medium))
                    Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }

    private var footnote: some View {
        Text("By posting, you agree to TikTok's Music Usage Confirmation. It may take a few minutes for the post to appear on your profile.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await send(.drafts) }
            } label: {
                HStack(spacing: 6) {
                    if sending == .drafts { ProgressView().controlSize(.small) } else { Image(systemName: "tray.and.arrow.down") }
                    Text("Drafts")
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.track, in: Capsule())
                .foregroundStyle(Color.primary)
            }
            .buttonStyle(SoftPressStyle())

            Button {
                Task { await send(.post) }
            } label: {
                HStack(spacing: 6) {
                    if sending == .post { ProgressView().controlSize(.small).tint(Theme.onAccent) } else { Image(systemName: "arrow.up.circle.fill") }
                    Text(when == .now ? "Post" : "Schedule")
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(SoftPressStyle())
        }
        .disabled(sending != nil || !hasVideo || info == nil)
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

    private func loadAccount() async {
        guard info == nil, let connection = session.connections.first(where: \.isHealthy) else { return }
        guard let fetched = await session.creatorInfo(for: connection.id) else { return }
        info = fetched
        privacy = fetched.privacyOptions.contains("PUBLIC_TO_EVERYONE") ? "PUBLIC_TO_EVERYONE" : fetched.privacyOptions.first
        allowComments = !fetched.commentDisabled
        allowDuet = !fetched.duetDisabled
        allowStitch = !fetched.stitchDisabled
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
            uploadFailed = nil
            // Upload while they write, so Post is quick.
            let url = movie.url
            let task = Task { try await session.uploadVideo(at: url) }
            uploadTask = task
            do {
                path = try await task.value
            } catch {
                uploadFailed = session.readableMessage(error)
            }
        } catch {
            session.lastError = "That video couldn't be read."
        }
    }

    private func writeWithAI() async {
        writing = true
        defer { writing = false }
        do {
            let result = try await session.writeCaption(caption, hashtags: hashtags, frames: facts?.frames ?? [])
            withAnimation(.snappy(duration: 0.25)) {
                caption = result.caption
                var merged = hashtags
                for tag in result.hashtags where !merged.contains(tag) { merged.append(tag) }
                hashtags = merged
            }
        } catch {
            session.lastError = session.readableMessage(error)
        }
    }

    private func signature(_ mode: Sending) -> String {
        [caption, hashtags.joined(separator: " "), String(coverMs ?? 0), mode == .drafts ? "d" : "p"].joined(separator: "|")
    }

    private func send(_ mode: Sending) async {
        guard let facts else { picking = true; return }
        sending = mode
        defer { sending = nil }
        problems = []
        let drafts = mode == .drafts

        do {
            if path == nil {
                if let uploadTask {
                    path = try await uploadTask.value
                } else if let movieURL {
                    path = try await session.uploadVideo(at: movieURL)
                }
            }
            guard let path else { return }

            // Same words as last time: check again rather than make a second post.
            let post: ComposedPost
            var checks: [ValidationReport.Check]
            if let existing = composed, existing.signature == signature(mode) {
                post = existing.post
                checks = try await session.validate(post: existing.post.postId, toDrafts: drafts).checks
            } else {
                post = try await session.compose(
                    path: path, video: facts, caption: caption, hashtags: hashtags,
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
                disableDuet: !allowDuet,
                disableStitch: !allowStitch,
                isAIGC: isAIGC,
                runAt: when == .later && !drafts ? scheduleAt : nil,
                postNow: drafts || when == .now,
                toDrafts: drafts,
                brandContent: disclose && brandedContent && !drafts,
                brandOrganic: disclose && yourBrand && !drafts
            )
            guard outcome != nil else { return }
            if let movieURL { try? FileManager.default.removeItem(at: movieURL) }
            done = post.postId
        } catch {
            session.lastError = session.readableMessage(error)
        }
    }
}

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
            .navigationTitle("Cover")
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
