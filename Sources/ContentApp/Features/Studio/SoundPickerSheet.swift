import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import Supabase

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

/// The sound sheet, built from native parts: a segmented For You / Hot /
/// Favorites / Recent, the system search field, a list of tracks, and the mix
/// in a form section. TikTok's own sounds cannot be used by apps, so the
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

    @State private var tab: Tab = .forYou
    @State private var query = ""
    @State private var searched = ""
    @State private var tracks: [MusicTrack] = []
    @State private var loading = false
    @State private var failed: String?
    @State private var previewing: String?
    @State private var applying: String?
    @State private var favorites: [MusicTrack] = SoundShelf.load(SoundShelf.favoritesKey)
    @State private var recent: [MusicTrack] = SoundShelf.load(SoundShelf.recentKey)
    @State private var importingFile = false
    @State private var videoItem: PhotosPickerItem?
    @State private var pickingVideo = false
    @State private var explainingTikTok = false
    @State private var player = AVPlayer()

    private var searching: Bool { !searched.isEmpty }

    private var shown: [MusicTrack] {
        if searching { return tracks }
        switch tab {
        case .favorites: return favorites
        case .recent:    return recent
        default:         return tracks
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if project.music != nil || project.originalVolume != 1 {
                    mixSection
                }

                if !searching {
                    Section {
                        Picker("Sounds", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }

                if tab == .forYou && !searching {
                    Section {
                        Button { importingFile = true } label: { Label("Your audio file", systemImage: "folder") }
                        Button { pickingVideo = true } label: { Label("Sound from a video", systemImage: "film") }
                        Button { explainingTikTok = true } label: { Label("Use a TikTok sound", systemImage: "music.note.tv") }
                    }
                }

                Section {
                    if loading && shown.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let failed, shown.isEmpty {
                        Text(failed).foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { track in row(track) }
                } header: {
                    Text(searching ? "Results" : tab.rawValue)
                } footer: {
                    if !shown.isEmpty && tab != .favorites && tab != .recent {
                        Text("Free-to-use music (CC BY / CC0) from Openverse. The artist credit is added to your description.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search sounds")
            .onSubmit(of: .search) { searched = query }
            .onChange(of: query) { _, value in if value.isEmpty { searched = "" } }
            .navigationTitle("Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task(id: "\(tab.rawValue)|\(searched)") { await load() }
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
            Text("TikTok doesn't let other apps use its sounds. Finish your edit here, then choose Drafts on the post screen — the video opens in TikTok, where you can add any TikTok sound and post.")
        }
    }

    // MARK: - Pieces

    private var mixSection: some View {
        Section("Mix") {
            if let music = project.music {
                LabeledContent("Sound", value: music.title)
                let longest = max(0, music.trackDuration - project.duration)
                if longest > 1 {
                    Slider(value: Binding(get: { music.startOffset },
                                          set: { value in update { $0.music?.startOffset = value } }),
                           in: 0...longest) {
                        Text("Starts at")
                    } minimumValueLabel: {
                        Text("\(Image(systemName: "scissors"))")
                    } maximumValueLabel: {
                        Text(Clock.format(music.startOffset)).font(.caption.monospacedDigit())
                    } onEditingChanged: { editing in
                        if !editing { previewFrom(music.fileURL, music.startOffset) }
                    }
                }
                volumeRow("Added sound", Double(music.volume)) { value in update { $0.music?.volume = Float(value) } }
            }
            volumeRow("Original sound", Double(project.originalVolume)) { value in update { $0.originalVolume = Float(value) } }
            if project.music != nil {
                Button("Remove sound", role: .destructive) {
                    player.pause()
                    previewing = nil
                    update { $0.music = nil }
                }
            }
        }
    }

    private func volumeRow(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        Slider(value: Binding(get: { value }, set: set), in: 0...1.5) {
            Text(title)
        } minimumValueLabel: {
            Text(title).font(.subheadline).frame(width: 110, alignment: .leading)
        } maximumValueLabel: {
            Text("\(Int(value * 100))").font(.caption.monospacedDigit()).frame(width: 32)
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
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { if applying == track.id { ProgressView() } }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                        Text("\(track.artist) · \(Clock.format(Double(track.durationS)))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    } else if previewing == track.id {
                        Image(systemName: "waveform").foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Button { toggleFavorite(track) } label: {
                Image(systemName: favorites.contains(track) ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Favorite")
        }
    }

    private var emptyText: String {
        if searching { return "No sounds found." }
        switch tab {
        case .favorites: return "Tap the bookmark on a sound to keep it here."
        case .recent:    return "Sounds you use show up here."
        default:         return "No sounds right now."
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
        loading = true
        failed = nil
        defer { loading = false }
        do {
            tracks = try await session.music(tab: searching ? "search" : (tab == .hot ? "hot" : "for_you"),
                                             query: searching ? searched : nil)
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
