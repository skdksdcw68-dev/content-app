import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// Create → Upload: Apple's own photo picker (ordered multi-select), then the
/// editor, then the post screen. Native all the way (Abel, 18 Sep 2026: "native
/// size, native component and everything").
struct StudioFlowView: View {
    struct Session: Identifiable, Hashable {
        let id = UUID()
        let clips: [StudioClip]
    }

    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var items: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var failed = false
    @State private var session: Session?

    var body: some View {
        ContentUnavailableView {
            Label("Choose videos or photos", systemImage: "photo.stack")
        } description: {
            Text("Pick one, or several in the order you want them.")
        } actions: {
            Button("Choose") { picking = true }
                .buttonStyle(RemiFilledButtonStyle())
                .controlSize(.large)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("New video")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .photosPicker(
            isPresented: $picking,
            selection: $items,
            maxSelectionCount: 20,
            selectionBehavior: .ordered,
            matching: .any(of: [.videos, .images]),
            preferredItemEncoding: .current
        )
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            if session == nil && items.isEmpty { picking = true }
        }
        .task(id: items) { await load() }
        .overlay {
            if loading {
                ProgressView("Getting your clips ready…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .alert("Couldn't open that", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It may still be downloading from iCloud. Try again in a moment.")
        }
        .navigationDestination(item: $session) { picked in
            EditorView(clips: picked.clips)
        }
    }

    private func load() async {
        guard !items.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let clips = try await StudioImport.clips(from: items)
            items = []
            session = Session(clips: clips)
        } catch {
            items = []
            failed = true
        }
    }
}

/// Turns picker items into local files the editor can use.
enum StudioImport {
    static func clips(from items: [PhotosPickerItem]) async throws -> [StudioClip] {
        var clips: [StudioClip] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await item.loadTransferable(type: Movie.self) else { continue }
                let duration = try await AVURLAsset(url: movie.url).load(.duration).seconds
                clips.append(.video(movie.url, duration: duration.isFinite ? duration : 1))
            } else if let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.92) {
                // Everything becomes JPEG: HEIC and PNG are not what TikTok takes.
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
                try jpeg.write(to: url)
                clips.append(.photo(url))
            }
        }
        if clips.isEmpty { throw CocoaError(.fileReadUnknown) }
        return clips
    }
}

/// "01:05"
enum Clock {
    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
