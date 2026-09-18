import SwiftUI
import Photos
import UIKit

/// TikTok's picker (Abel's screenshot, 18 Sep 2026): the album at the top,
/// All / Videos / Photos, a three-across grid with each video's length, and
/// Select multiple with numbered picks and Next.
///
/// A plain tap picks one item and moves on; Select multiple numbers them in
/// the order tapped, which is the order they go on the timeline.
struct MediaPickerView: View {
    /// Called with the picked items, already copied to local files.
    let onPicked: ([StudioClip]) -> Void
    /// When adding to a video already being edited, the flow stays on multiple.
    var addingMore = false

    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case all = "All", videos = "Videos", photos = "Photos" }

    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var tab: Tab = .all
    @State private var albums: [PHAssetCollection] = []
    @State private var album: PHAssetCollection?
    @State private var assets: [PHAsset] = []
    @State private var multiple = false
    @State private var picked: [String] = []
    @State private var loading = false
    @State private var failed: String?

    private let manager = PHCachingImageManager()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .pushedPage()
        .task { await start() }
        .onChange(of: tab) { _, _ in reload() }
        .onChange(of: album) { _, _ in reload() }
        .overlay {
            if loading {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("Getting your \(picked.count > 1 ? "clips" : "clip") ready…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .alert("Couldn't open that", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failed ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 20, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
                Menu {
                    Button("Recents") { album = nil }
                    ForEach(albums, id: \.localIdentifier) { collection in
                        Button(collection.localizedTitle ?? "Album") { album = collection }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(album?.localizedTitle ?? "Recents")
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)

            HStack(spacing: 26) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        VStack(spacing: 7) {
                            Text(item.rawValue)
                                .font(.system(size: 16, weight: tab == item ? .semibold : .regular))
                                .foregroundStyle(tab == item ? Color.white : Color.white.opacity(0.55))
                            Capsule()
                                .fill(tab == item ? Color.white : Color.clear)
                                .frame(width: 40, height: 3)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
    }

    // MARK: - Grid

    @ViewBuilder
    private var content: some View {
        switch status {
        case .authorized, .limited:
            ScrollView {
                if status == .limited {
                    Button {
                        presentLimitedPicker()
                    } label: {
                        Text("You've allowed some photos. Tap to choose more.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .padding(10)
                    }
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        cell(asset)
                    }
                }
            }
        case .notDetermined:
            Spacer()
        default:
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36, weight: .light))
                Text("Allow access to your photos to pick videos.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(32)
        }
    }

    private func cell(_ asset: PHAsset) -> some View {
        let order = picked.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
        return Button {
            tap(asset)
        } label: {
            AssetThumbnail(asset: asset, manager: manager)
                .aspectRatio(3 / 4, contentMode: .fill)
                .overlay(alignment: .bottomTrailing) {
                    if asset.mediaType == .video {
                        Text(Self.clock(asset.duration))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if multiple {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 1.5)
                                .background(Circle().fill(order == nil ? Color.black.opacity(0.2) : Color.accentColor))
                            if let order {
                                Text("\(order)").font(.caption.weight(.bold)).foregroundStyle(Theme.onAccent)
                            }
                        }
                        .frame(width: 26, height: 26)
                        .padding(7)
                    }
                }
                .overlay {
                    if order != nil { Color.white.opacity(0.15) }
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button {
                multiple.toggle()
                if !multiple { picked = Array(picked.prefix(1)) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: multiple ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(multiple ? Color.accentColor : Color.white)
                    Text("Select multiple")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
            Button {
                Task { await finish() }
            } label: {
                Text(picked.count > 1 ? "Next (\(picked.count))" : "Next")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 180, height: 50)
                    .background(picked.isEmpty ? Color.white.opacity(0.12) : Color.accentColor, in: Capsule())
                    .foregroundStyle(picked.isEmpty ? Color.white.opacity(0.4) : Theme.onAccent)
            }
            .disabled(picked.isEmpty || loading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
    }

    // MARK: - Actions

    private func start() async {
        if addingMore { multiple = true }
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { return }
        loadAlbums()
        reload()
    }

    private func loadAlbums() {
        var found: [PHAssetCollection] = []
        let smart: [PHAssetCollectionSubtype] = [.smartAlbumFavorites, .smartAlbumVideos, .smartAlbumScreenshots, .smartAlbumSelfPortraits]
        for subtype in smart {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in found.append(collection) }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in found.append(collection) }
        albums = found
    }

    private func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch tab {
        case .all:    options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        case .videos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .photos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        let result = album.map { PHAsset.fetchAssets(in: $0, options: options) } ?? PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }

    private func tap(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if multiple {
            if let index = picked.firstIndex(of: id) { picked.remove(at: index) } else { picked.append(id) }
        } else {
            picked = [id]
            Task { await finish() }
        }
    }

    private func finish() async {
        guard !picked.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        let chosen = picked.compactMap { id in assets.first { $0.localIdentifier == id } }
        do {
            var clips: [StudioClip] = []
            for asset in chosen {
                clips.append(try await Self.clip(from: asset))
            }
            onPicked(clips)
            if addingMore { dismiss() }
        } catch {
            failed = "It may still be downloading from iCloud. Try again in a moment."
        }
    }

    private func presentLimitedPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root) { _ in
            Task { @MainActor in reload() }
        }
    }

    /// Copies the original file out of the library (from iCloud if needed).
    static func clip(from asset: PHAsset) async throws -> StudioClip {
        let resources = PHAssetResource.assetResources(for: asset)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        if asset.mediaType == .video {
            guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                    ?? resources.first(where: { $0.type == .video }) else { throw CocoaError(.fileNoSuchFile) }
            let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("clip-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            return .video(url, duration: asset.duration)
        }

        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else { throw CocoaError(.fileNoSuchFile) }
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("photo-src-\(UUID().uuidString)")
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: original, options: options)
        // Everything becomes JPEG: HEIC and PNG are not what TikTok takes.
        guard let image = UIImage(contentsOfFile: original.path),
              let jpeg = image.jpegData(compressionQuality: 0.92) else { throw CocoaError(.fileReadCorruptFile) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        try? FileManager.default.removeItem(at: original)
        return .photo(url)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// One library item's thumbnail.
private struct AssetThumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.white.opacity(0.06)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
        }
        .onAppear {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            manager.requestImage(for: asset, targetSize: CGSize(width: 300, height: 400),
                                 contentMode: .aspectFill, options: options) { result, _ in
                image = result
            }
        }
    }
}
