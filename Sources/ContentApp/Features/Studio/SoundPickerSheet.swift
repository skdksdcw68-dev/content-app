import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

/// A track from the library (`music` edge function → Openverse, CC0 / CC BY).
struct MusicTrack: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let durationS: Int
    let artwork: String?
    let audio: String
    let license: String
    let licenseUrl: String?
    let attribution: String
    let source: String
}

extension AppSession {
    func music(tab: String, query: String? = nil) async throws -> [MusicTrack] {
        struct Request: Encodable, Sendable { let tab: String; let q: String? }
        struct Response: Decodable, Sendable { let tracks: [MusicTrack] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: Response = try await retryingDroppedConnection {
            try await client.functions.invoke("music", options: FunctionInvokeOptions(body: Request(tab: tab, q: query)), decoder: decoder)
        }
        return response.tracks
    }
}

/// TikTok's sound sheet (Abel's screenshot): For You / Hot / Favorites /
/// Recent with search, rows with artwork, ✂ and 🔖, and Original / Sound /
/// Volume along the bottom. TikTok's own sounds cannot be used by apps, so the
/// library is licensed music, plus your own audio, plus the honest route to a
/// TikTok sound: finish it in TikTok through Drafts.
struct SoundPickerSheet: View {
    @Binding var project: StudioProject
    /// Set when they choose to add a TikTok sound in TikTok.
    @Binding var wantsTikTokSound: Bool
    let onChange: (StudioProject) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case forYou = "For You", hot = "Hot", favorites = "Favorites", recent = "Recent" }
    enum Bottom { case none, volume, trim }

    @State private var tab: Tab = .forYou
    @State private var searching = false
    @State private var query = ""
    @State private var tracks: [MusicTrack] = []
    @State private var loading = false
    @State private var failed: String?
    @State private var previewing: String?
    @State private var applying: String?
    @State private var favorites: [MusicTrack] = SoundShelf.load(SoundShelf.favoritesKey)
    @State private var recent: [MusicTrack] = SoundShelf.load(SoundShelf.recentKey)
    @State private var bottom: Bottom = .none
    @State private var importingFile = false
    @State private var videoItem: PhotosPickerItem?
    @State private var pickingVideo = false
    @State private var explainingTikTok = false
    @State private var player = AVPlayer()

    private var shown: [MusicTrack] {
        switch tab {
        case .favorites: favorites
        case .recent:    recent
        default:         tracks
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                if searching { searchField }
                List {
                    if tab == .forYou && !searching { extraRows }
                    if loading && shown.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                    } else if let failed, shown.isEmpty {
                        Text(failed).font(.subheadline).foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text(emptyText).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { track in
                        row(track)
                    }
                    if !shown.isEmpty && (tab == .forYou || tab == .hot || searching) {
                        Text("Free-to-use music from Openverse (CC BY / CC0). The artist credit is added to your description.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                bottomPanel
                bottomBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task(id: "\(tab.rawValue)|\(searching)") { await load() }
        .onDisappear { player.pause() }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { Task { await useFile(url) } }
        }
        .photosPicker(isPresented: $pickingVideo, selection: $videoItem, matching: .videos)
        .task(id: videoItem) { await useVideoSound() }
        .alert("Use a TikTok sound", isPresented: $explainingTikTok) {
            Button("Send to TikTok Drafts") {
                wantsTikTokSound = true
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("TikTok doesn't let other apps use its sounds. Finish your edit here, then tap Drafts on the post screen — the video opens in TikTok, where you can add any TikTok sound and post.")
        }
    }

    // MARK: - Pieces

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                    searching = false
                } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue)
                            .font(.system(size: 16, weight: tab == item && !searching ? .semibold : .regular))
                            .foregroundStyle(tab == item && !searching ? Color.primary : Color.secondary)
                        Capsule().fill(tab == item && !searching ? Color.primary : Color.clear).frame(height: 2.5)
                    }
                    .fixedSize()
                }
            }
            Spacer()
            Button { searching.toggle() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium))
            }
            .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search sounds", text: $query)
                .submitLabel(.search)
                .onSubmit { Task { await load() } }
        }
        .padding(10)
        .background(Color.track, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var extraRows: some View {
        Button { importingFile = true } label: {
            Label("Your audio", systemImage: "folder")
        }
        Button { pickingVideo = true } label: {
            Label("Use sound from a video", systemImage: "film")
        }
        Button { explainingTikTok = true } label: {
            Label("Use a TikTok sound", systemImage: "music.note")
        }
    }

    private func row(_ track: MusicTrack) -> some View {
        let selected = project.music?.fileURL.lastPathComponent.hasPrefix("track-\(track.id)") == true
        return HStack(spacing: 12) {
            Button { Task { await use(track) } } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: track.artwork.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ZStack { Color.track; Image(systemName: "music.note").foregroundStyle(.secondary) }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if applying == track.id { ProgressView().tint(.white) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            if previewing == track.id {
                                Image(systemName: "waveform").font(.caption).foregroundStyle(Color.accentColor)
                            }
                            Text(track.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                                .lineLimit(1)
                        }
                        Text("\(track.artist) · \(MediaPickerView.clock(Double(track.durationS)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
            }
            .buttonStyle(.plain)

            if selected {
                Button { bottom = bottom == .trim ? .none : .trim } label: {
                    Image(systemName: "scissors").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose where the sound starts")
            }
            Button { toggleFavorite(track) } label: {
                Image(systemName: favorites.contains(track) ? "bookmark.fill" : "bookmark").font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Favorite")
        }
        .padding(.vertical, 4)
        .listRowBackground(selected ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch bottom {
        case .volume:
            VStack(spacing: 10) {
                volumeRow("Original", value: Binding(
                    get: { Double(project.originalVolume) },
                    set: { value in update { $0.originalVolume = Float(value) } }
                ))
                if project.music != nil {
                    volumeRow("Added sound", value: Binding(
                        get: { Double(project.music?.volume ?? 0) },
                        set: { value in update { $0.music?.volume = Float(value) } }
                    ))
                }
            }
            .padding(16)
            .background(Color.track.opacity(0.5))
        case .trim:
            if let music = project.music {
                let longest = max(0, music.trackDuration - project.duration)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Starts at \(MediaPickerView.clock(music.startOffset))")
                        .font(.caption.weight(.semibold))
                    Slider(value: Binding(
                        get: { music.startOffset },
                        set: { value in update { $0.music?.startOffset = value } }
                    ), in: 0...max(0.1, longest)) { editing in
                        if !editing { previewFrom(music.fileURL, music.startOffset) }
                    }
                }
                .padding(16)
                .background(Color.track.opacity(0.5))
            }
        case .none:
            EmptyView()
        }
    }

    private func volumeRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.subheadline).frame(width: 100, alignment: .leading)
            Slider(value: value, in: 0...1.5)
            Text("\(Int(value.wrappedValue * 100))").font(.caption.monospacedDigit()).frame(width: 34)
        }
    }

    private var bottomBar: some View {
        HStack {
            barButton(project.originalVolume == 0 ? "mic.slash" : "mic", "Original") {
                update { $0.originalVolume = $0.originalVolume == 0 ? 1 : 0 }
            }
            barButton("music.note", project.music?.title ?? "Sound") {
                if project.music != nil {
                    player.pause()
                    previewing = nil
                    update { $0.music = nil }
                }
            }
            barButton("speaker.wave.2", "Volume") {
                bottom = bottom == .volume ? .none : .volume
            }
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func barButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var emptyText: String {
        switch tab {
        case .favorites: "Tap 🔖 on a sound to keep it here."
        case .recent:    "Sounds you use show up here."
        default:         searching ? "No sounds found." : "No sounds right now."
        }
    }

    // MARK: - Actions

    private func update(_ change: (inout StudioProject) -> Void) {
        var copy = project
        change(&copy)
        project = copy
        onChange(copy)
    }

    private func load() async {
        guard tab == .forYou || tab == .hot || searching else { return }
        if searching && query.trimmingCharacters(in: .whitespaces).isEmpty { return }
        loading = true
        failed = nil
        defer { loading = false }
        do {
            tracks = try await session.music(tab: searching ? "search" : (tab == .hot ? "hot" : "for_you"),
                                             query: searching ? query : nil)
        } catch {
            failed = session.readableMessage(error)
        }
    }

    /// Downloads the track and puts it under the video.
    private func use(_ track: MusicTrack) async {
        guard let remote = URL(string: track.audio) else { return }
        applying = track.id
        defer { applying = nil }
        do {
            let (temp, _) = try await URLSession.shared.download(from: remote)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("track-\(track.id)-\(UUID().uuidString.prefix(6)).mp3")
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: temp, to: local)
            let duration = try await AVURLAsset(url: local).load(.duration).seconds
            update {
                $0.music = StudioMusic(title: track.title, artist: track.artist, attribution: track.attribution,
                                       fileURL: local, trackDuration: duration.isFinite ? duration : Double(track.durationS))
                if $0.originalVolume == 1 { $0.originalVolume = 0.3 }
            }
            recent.removeAll { $0.id == track.id }
            recent.insert(track, at: 0)
            recent = Array(recent.prefix(30))
            SoundShelf.save(recent, SoundShelf.recentKey)
            previewFrom(local, 0)
            previewing = track.id
        } catch {
            failed = "That sound couldn't be downloaded. Try another."
        }
    }

    private func useFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: local)
            let duration = try await AVURLAsset(url: local).load(.duration).seconds
            update {
                $0.music = StudioMusic(title: url.deletingPathExtension().lastPathComponent, artist: "Your audio",
                                       attribution: nil, fileURL: local, trackDuration: duration)
            }
            previewFrom(local, 0)
        } catch {
            failed = "That file couldn't be used."
        }
    }

    /// The sound of another video, as the track.
    private func useVideoSound() async {
        guard let videoItem else { return }
        defer { self.videoItem = nil }
        do {
            guard let movie = try await videoItem.loadTransferable(type: Movie.self) else { return }
            let asset = AVURLAsset(url: movie.url)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("sound-\(UUID().uuidString).m4a")
            try await exporter.export(to: out, as: .m4a)
            let duration = try await AVURLAsset(url: out).load(.duration).seconds
            update {
                $0.music = StudioMusic(title: "Sound from your video", artist: "Your audio",
                                       attribution: nil, fileURL: out, trackDuration: duration)
            }
            previewFrom(out, 0)
        } catch {
            failed = "That video has no sound Autocast could use."
        }
    }

    private func previewFrom(_ url: URL, _ offset: Double) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
        player.play()
    }

    private func toggleFavorite(_ track: MusicTrack) {
        if let index = favorites.firstIndex(of: track) { favorites.remove(at: index) } else { favorites.insert(track, at: 0) }
        SoundShelf.save(favorites, SoundShelf.favoritesKey)
    }
}

/// Favorites and Recent, kept on the phone.
enum SoundShelf {
    static let favoritesKey = "studio.sounds.favorites"
    static let recentKey = "studio.sounds.recent"

    static func load(_ key: String) -> [MusicTrack] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MusicTrack].self, from: data)) ?? []
    }

    static func save(_ tracks: [MusicTrack], _ key: String) {
        if let data = try? JSONEncoder().encode(tracks) { UserDefaults.standard.set(data, forKey: key) }
    }
}
