import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Everything queued, and the way to add something to it.
///
/// Media comes from the camera roll for now. Generation is a separate pipeline
/// and the path from here to TikTok is identical either way, so this is the
/// shortest honest route to a post that actually publishes -- and `user_upload`
/// is a real provenance the schema already understands, not a stand-in.
struct LibraryView: View {
    @Environment(AppSession.self) private var session

    @State private var pickerItem: PhotosPickerItem?
    @State private var caption = ""
    @State private var showingCaption = false
    @State private var pendingVideo: (data: Data, filename: String)?
    @State private var approving: PendingPost?

    /// Every video made for this brand, newest first. Nil until loaded.
    @State private var loadedVideos: [BoardPost]?
    @State private var reviewing: BoardPost?
    @State private var deleting: BoardPost?
    @State private var filter: Shelf = .all

    /// The shelves: where a video is on its way.
    enum Shelf: String, CaseIterable, Identifiable {
        case all, waiting, scheduled, posted
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:       "All"
            case .waiting:   "Needs you"
            case .scheduled: "Scheduled"
            case .posted:    "Posted"
            }
        }
        func holds(_ post: BoardPost) -> Bool {
            switch self {
            case .all:       true
            case .waiting:   post.stage == .readyForReview || post.stage == .needsAttention || post.stage == .draft || post.stage == .inDrafts
            case .scheduled: post.stage == .approved || post.stage == .scheduled || post.stage == .generating || post.stage == .readyToPublish || post.stage == .publishing || post.stage == .verifying
            case .posted:    post.stage == .published
            }
        }
    }

    private var videos: [BoardPost] { loadedVideos ?? [] }
    private var shown: [BoardPost] { videos.filter { filter.holds($0) } }

    private let grid = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    /// The library: every video as a tall tile, three across, shelved by
    /// where it is. Tap one to watch, trim and take it on; hold for the
    /// details or to delete (Abel, 23 Sep 2026: "the library should be
    /// looking so good").
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if loadedVideos == nil {
                        LazyVGrid(columns: grid, spacing: 3) {
                            ForEach(0..<9, id: \.self) { _ in
                                // Rounded like the tiles it stands in for.
                                // Square corners made the grid visibly change
                                // shape the moment the videos landed.
                                RoundedRectangle(cornerRadius: Theme.mediaRadius, style: .continuous)
                                    .fill(Color.track)
                                    .aspectRatio(9 / 16, contentMode: .fit)
                            }
                        }
                        .breathing()
                    } else if shown.isEmpty {
                        empty
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: grid, spacing: 3) {
                            ForEach(shown) { video in
                                Button { reviewing = video } label: {
                                    LibraryTile(post: video)
                                }
                                .buttonStyle(SoftPressStyle())
                                .contextMenu {
                                    Button { session.push(.post(video.id)) } label: {
                                        Label("Details", systemImage: "info.circle")
                                    }
                                    if video.stage != .publishing && video.stage != .verifying {
                                        Button(role: .destructive) { deleting = video } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Picker("Shelf", selection: $filter) {
                        ForEach(Shelf.allCases) { shelf in
                            Text(shelf.title).tag(shelf)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Style.gutter)
                    .padding(.vertical, 10)
                    .background(Color.canvas)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .pushedPage()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a video")
                .disabled(session.connections.isEmpty || session.isWorking)
            }
        }
        .task(id: session.brand?.id) { loadedVideos = try? await session.videos() }
        .task(id: pickerItem) { await loadPicked() }
        .refreshable {
            await session.refreshPosts()
            loadedVideos = try? await session.videos()
        }
        .sheet(isPresented: $showingCaption) { captionSheet }
        .sheet(item: $approving) { post in
            ApprovalSheet(post: post)
        }
        .fullScreenCover(item: $reviewing) { post in
            VideoReviewView(post: post)
        }
        .alert("Delete this video?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let video = deleting else { return }
                deleting = nil
                Task {
                    // The copy on the phone goes with it: a video of a post
                    // that no longer exists is space nobody can reach.
                    if let media = video.media { session.forgetVideo(of: media) }
                    if await session.deletePost(video.id) {
                        loadedVideos?.removeAll { $0.id == video.id }
                    }
                }
            }
        } message: {
            Text("It’s removed from Autocast. Anything already on TikTok stays there.")
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .all ? "video.badge.plus" : "tray")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text(filter == .all ? "Nothing here yet" : "Nothing on this shelf")
                .font(.headline)
            Text(filter == .all
                 ? "Videos you make and post show up here."
                 : "Videos move here as they go out.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var captionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Say something about it", text: $caption, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Caption")
                } footer: {
                    Text("You will see this again, with the account it is going to, before anything is posted.")
                }
            }
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pendingVideo = nil
                        showingCaption = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await upload() } }
                        .disabled(session.isWorking)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func loadPicked() async {
        guard let pickerItem else { return }
        do {
            guard let movie = try await pickerItem.loadTransferable(type: Movie.self) else { return }
            let data = try Data(contentsOf: movie.url)
            try? FileManager.default.removeItem(at: movie.url)
            pendingVideo = (data, movie.url.lastPathComponent)
            caption = ""
            showingCaption = true
        } catch {
            session.lastError = "That video could not be read."
        }
        self.pickerItem = nil
    }

    private func upload() async {
        guard let pendingVideo else { return }
        showingCaption = false
        await session.addVideo(
            data: pendingVideo.data,
            filename: pendingVideo.filename,
            caption: caption
        )
        self.pendingVideo = nil
    }
}


/// Pulls a video out of the photo library as a file rather than as bytes in
/// memory, so a long clip does not have to be materialised twice.
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = URL.temporaryDirectory
                .appending(path: "upload-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }
}

/// One video on the shelf: its frame, edge to edge, and where it is.
private struct LibraryTile: View {
    let post: BoardPost

    var body: some View {
        GeometryReader { proxy in
            PostThumb(media: post.media, stage: post.stage, width: proxy.size.width)
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.mediaRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if post.stage != .published {
                // One chip. StageChip already draws its own capsule, and
                // wrapping it in a material one made a chip inside a chip.
                StageChip(stage: post.stage, compact: true)
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if post.stage == .published {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
            }
        }
        .accessibilityLabel("\(post.stage.title): \(post.hook)")
    }
}
