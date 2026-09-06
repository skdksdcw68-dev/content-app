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

    var body: some View {
        Group {
            if session.connections.isEmpty {
                ComingSoon(
                    symbol: "link",
                    title: "Connect an account first",
                    detail: "Autocast needs somewhere to post before it can hold anything for you. You → Connect TikTok."
                )
            } else if session.posts.isEmpty {
                ComingSoon(
                    symbol: "square.grid.2x2",
                    title: "Nothing here yet",
                    detail: "Add a video and it becomes a post waiting for your approval. Nothing goes anywhere until you say so."
                )
            } else {
                list
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label("Add", systemImage: "plus")
                }
                .disabled(session.connections.isEmpty || session.isWorking)
            }
        }
        .task(id: pickerItem) { await loadPicked() }
        .refreshable { await session.refreshPosts() }
        .sheet(isPresented: $showingCaption) { captionSheet }
        .sheet(item: $approving) { post in
            ApprovalSheet(post: post)
        }
    }

    private var list: some View {
        List {
            ForEach(session.posts) { post in
                Button {
                    approving = post
                } label: {
                    PostRow(post: post)
                }
                .buttonStyle(.plain)
                .disabled(post.isBusy)
            }
        }
        .listStyle(.insetGrouped)
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

private struct PostRow: View {
    let post: PendingPost

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: post.post.status.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(StatusBadge.tint(for: post.post.status))
                .frame(width: 34, height: 34)
                .background(StatusBadge.tint(for: post.post.status).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(post.caption.isEmpty ? post.post.hook : post.caption)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(post.statusLine)
                    .font(.caption)
                    .foregroundStyle(post.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            if post.isBusy {
                ProgressView().controlSize(.small)
            } else if post.needsYou {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
