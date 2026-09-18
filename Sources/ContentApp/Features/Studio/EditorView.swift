import SwiftUI
import AVFoundation
import AVKit

/// From Create's Upload: TikTok's picker, then the editor, then the post screen.
struct StudioFlowView: View {
    struct Session: Identifiable, Hashable {
        let id = UUID()
        let clips: [StudioClip]
    }

    @State private var session: Session?

    var body: some View {
        MediaPickerView { clips in
            session = Session(clips: clips)
        }
        .navigationDestination(item: $session) { picked in
            EditorView(clips: picked.clips)
        }
    }
}

/// What the preview player is doing, observed by the editor.
@MainActor
@Observable
final class EditorPlayback {
    let player = AVPlayer()
    var time: Double = 0
    var isPlaying = false
    private var token: Any?

    init() {
        token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.time = time.seconds
                self?.isPlaying = self?.player.rate != 0
            }
        }
    }

    func toggle(duration: Double) {
        if player.rate != 0 {
            player.pause()
        } else {
            if time >= duration - 0.05 { seek(0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(_ seconds: Double) {
        player.seek(to: StudioComposer.seconds(seconds), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
    }
}

/// TikTok's editor (Abel's screenshots): the preview, time and play, undo and
/// redo, a timeline of the clips with the sound under them, and Edit / Sound /
/// Text / Filters / Adjust along the bottom. Every change re-renders through
/// the same compositor the export uses.
struct EditorView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case edit = "Edit", sound = "Sound", text = "Text", filters = "Filters", adjust = "Adjust"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .edit:    "scissors"
            case .sound:   "music.note"
            case .text:    "textformat"
            case .filters: "camera.filters"
            case .adjust:  "slider.horizontal.3"
            }
        }
    }

    struct Rendered: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        let attribution: String?
        let tiktokSound: Bool
    }

    @State private var project: StudioProject
    @State private var history = EditHistory<StudioProject>()
    @State private var playback = EditorPlayback()
    @State private var tool: Tool?
    @State private var selected: UUID?
    @State private var editingText: UUID?
    @State private var showingSound = false
    @State private var addingMore = false
    @State private var wantsTikTokSound = false
    @State private var rebuild = 0
    @State private var exportProgress: Double?
    @State private var exportTask: Task<Void, Never>?
    @State private var rendered: Rendered?
    @State private var buildFailed: String?

    @Environment(\.dismiss) private var dismiss

    init(clips: [StudioClip]) {
        _project = State(initialValue: StudioProject(clips: clips))
    }

    private let pointsPerSecond: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
                .padding(.top, 6)
            controls
            timeline
            Spacer(minLength: 0)
            bottom
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .pushedPage()
        .task(id: rebuild) { await rebuildPlayer() }
        .onDisappear { playback.player.pause() }
        .sheet(isPresented: $showingSound) {
            SoundPickerSheet(project: $project, wantsTikTokSound: $wantsTikTokSound) { _ in
                rebuild += 1
            }
        }
        .sheet(isPresented: $addingMore) {
            NavigationStack {
                MediaPickerView(onPicked: { clips in
                    change { $0.clips.append(contentsOf: clips) }
                }, addingMore: true)
            }
        }
        .navigationDestination(item: $rendered) { video in
            ComposeView(video: video.url, attribution: video.attribution, preferDrafts: video.tiktokSound)
        }
        .overlay { if let exportProgress { exportOverlay(exportProgress) } }
    }

    // MARK: - Top, preview, controls

    private var topBar: some View {
        HStack {
            circleButton("chevron.left", filled: false) { dismiss() }
            Spacer()
            circleButton("arrow.right", filled: true) { startExport() }
                .accessibilityLabel("Next")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func circleButton(_ symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .frame(width: 52, height: 52)
                .background(filled ? Color.accentColor : Color.white.opacity(0.14), in: Circle())
                .foregroundStyle(filled ? Theme.onAccent : Color.white)
        }
        .buttonStyle(SoftPressStyle())
    }

    private var preview: some View {
        PlayerSurface(player: playback.player)
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if let buildFailed {
                    Text(buildFailed).font(.footnote).foregroundStyle(.white).padding()
                }
            }
            .onTapGesture { playback.toggle(duration: project.duration) }
            .frame(maxHeight: 400)
    }

    private var controls: some View {
        HStack {
            Text("\(MediaPickerView.clock(playback.time))/\(MediaPickerView.clock(project.duration))")
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 120, alignment: .leading)
            Spacer()
            Button { playback.toggle(duration: project.duration) } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
            }
            Spacer()
            HStack(spacing: 18) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!history.canUndo)
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!history.canRedo)
            }
            .font(.system(size: 19, weight: .medium))
            .frame(width: 120, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(project.clips) { clip in
                            ClipStrip(clip: clip, width: max(24, CGFloat(clip.duration) * pointsPerSecond),
                                      selected: selected == clip.id)
                                .onTapGesture {
                                    selected = clip.id
                                    tool = .edit
                                    if let index = project.clips.firstIndex(where: { $0.id == clip.id }) {
                                        playback.seek(project.start(of: index) + 0.01)
                                    }
                                }
                        }
                        Button { addingMore = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .bold))
                                .frame(width: 56, height: 56)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(.black)
                        }
                        .padding(.leading, 10)
                    }
                    Button { showingSound = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                            Text(project.music?.title ?? (project.originalVolume == 0 ? "Muted · Add sound" : "original sound"))
                                .lineLimit(1)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(width: max(120, CGFloat(project.duration) * pointsPerSecond), height: 40, alignment: .leading)
                        .background(Color(red: 0.55, green: 0.62, blue: 1).opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(Color(red: 0.1, green: 0.12, blue: 0.3))
                    }
                    .buttonStyle(.plain)
                    if !project.texts.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(project.texts) { text in
                                Text(text.text)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .frame(height: 26)
                                    .background(Color.yellow.opacity(0.85), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .foregroundStyle(.black)
                                    .onTapGesture {
                                        editingText = text.id
                                        tool = .text
                                    }
                            }
                        }
                    }
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 150)
                    .offset(x: CGFloat(playback.time) * pointsPerSecond)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .frame(height: 150)
    }

    // MARK: - Bottom

    @ViewBuilder
    private var bottom: some View {
        if let tool {
            VStack(spacing: 0) {
                HStack {
                    Text(tool.rawValue).font(.headline)
                    Spacer()
                    Button { self.tool = nil } label: {
                        Image(systemName: "checkmark").font(.system(size: 18, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                panel(tool)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .background(Color(white: 0.1))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Tool.allCases) { item in
                        Button {
                            if item == .sound { showingSound = true } else { tool = item }
                            if item == .edit && selected == nil { selected = currentClipID }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: item.symbol).font(.system(size: 24))
                                Text(item.rawValue).font(.system(size: 15, weight: .medium))
                            }
                            .frame(width: 84, height: 80)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func panel(_ tool: Tool) -> some View {
        switch tool {
        case .edit:
            EditPanel(
                project: project,
                clipID: selected ?? currentClipID,
                time: playback.time,
                change: change,
                select: { selected = $0 }
            )
        case .text:
            TextPanel(project: project, editing: $editingText, time: playback.time, change: change)
        case .filters:
            FilterPanel(project: project, change: change)
        case .adjust:
            AdjustPanel(project: project, change: change)
        case .sound:
            EmptyView()
        }
    }

    private var currentClipID: UUID? {
        project.clip(at: playback.time).map { project.clips[$0.index].id }
    }

    private func exportOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressRing(progress: progress, lineWidth: 6, color: .white)
                    .frame(width: 84, height: 84)
                    .overlay(Text("\(Int(progress * 100))%").font(.headline.monospacedDigit()).foregroundStyle(.white))
                Text("Making your video")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Full quality, nothing compressed away.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Cancel") {
                    exportTask?.cancel()
                    exportProgress = nil
                }
                .foregroundStyle(.white)
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Actions

    private func change(_ edit: (inout StudioProject) -> Void) {
        var copy = project
        edit(&copy)
        guard copy != project else { return }
        history.record(project)
        project = copy
        rebuild += 1
    }

    private func undo() {
        if let previous = history.undo(project) {
            project = previous
            rebuild += 1
        }
    }

    private func redo() {
        if let next = history.redo(project) {
            project = next
            rebuild += 1
        }
    }

    private func rebuildPlayer() async {
        // A short pause, so a slider dragged across its range builds once.
        try? await Task.sleep(for: .milliseconds(rebuild == 0 ? 0 : 180))
        guard !Task.isCancelled else { return }
        do {
            let built = try await StudioComposer.build(project)
            guard !Task.isCancelled else { return }
            let resume = playback.time
            let wasPlaying = playback.isPlaying
            playback.player.replaceCurrentItem(with: StudioComposer.playerItem(built))
            playback.seek(min(resume, max(0, project.duration - 0.05)))
            if wasPlaying || rebuild == 0 { playback.player.play() }
            buildFailed = nil
        } catch {
            buildFailed = "This clip couldn't be played."
        }
    }

    private func startExport() {
        playback.player.pause()
        exportProgress = 0
        let snapshot = project
        exportTask = Task {
            do {
                let built = try await StudioComposer.build(snapshot)
                let url = try await StudioComposer.export(built) { value in
                    Task { @MainActor in if exportProgress != nil { exportProgress = value } }
                }
                guard !Task.isCancelled else { return }
                exportProgress = nil
                rendered = Rendered(url: url, attribution: snapshot.music?.attribution, tiktokSound: wantsTikTokSound)
            } catch {
                exportProgress = nil
                if !Task.isCancelled { buildFailed = "The video couldn't be made. Try again." }
            }
        }
    }
}

// MARK: - Player

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        view.playerLayer.player = player
    }
}

// MARK: - Clip strip

private struct ClipStrip: View {
    let clip: StudioClip
    let width: CGFloat
    let selected: Bool
    @State private var thumb: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white.opacity(0.12)
            if let thumb {
                HStack(spacing: 0) {
                    ForEach(0..<max(1, Int(width / 42)), id: \.self) { _ in
                        Image(uiImage: thumb).resizable().scaledToFill().frame(width: 42, height: 56).clipped()
                    }
                }
                .frame(width: width, alignment: .leading)
                .clipped()
            }
            if clip.speed != 1 {
                Text(String(format: "%.1fx", clip.speed))
                    .font(.caption2.weight(.bold))
                    .padding(3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
        .frame(width: width, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.clear, lineWidth: 2.5)
        }
        .task(id: clip.url) {
            if clip.kind == .photo {
                thumb = UIImage(contentsOfFile: clip.url.path)
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 160, height: 160)
                let at = StudioComposer.seconds(clip.trimStart + min(0.5, clip.trimmedLength / 2))
                if let image = try? await generator.image(at: at).image { thumb = UIImage(cgImage: image) }
            }
        }
    }
}

// MARK: - Panels

private struct EditPanel: View {
    let project: StudioProject
    let clipID: UUID?
    let time: Double
    let change: ((inout StudioProject) -> Void) -> Void
    let select: (UUID?) -> Void

    private var clip: StudioClip? { project.clips.first { $0.id == clipID } }
    private let speeds: [Double] = [0.3, 0.5, 1, 1.5, 2, 3]

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Trim").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(String(format: "%.1f", clip.trimStart))s – \(String(format: "%.1f", clip.trimEnd))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { clip.trimStart },
                                      set: { value in change { $0.trim(clip.id, start: value, end: clip.trimEnd) } }),
                       in: 0...max(0.3, clip.sourceDuration - StudioProject.shortest))
                Slider(value: Binding(get: { clip.trimEnd },
                                      set: { value in change { $0.trim(clip.id, start: clip.trimStart, end: value) } }),
                       in: min(clip.sourceDuration - 0.01, StudioProject.shortest)...clip.sourceDuration)

                HStack(spacing: 6) {
                    Text("Speed").font(.subheadline.weight(.semibold))
                    Spacer()
                    ForEach(speeds, id: \.self) { speed in
                        Button {
                            change { $0.setSpeed(clip.id, speed) }
                        } label: {
                            Text(speed == 1 ? "1x" : String(format: speed < 1 ? "%.1fx" : "%gx", speed))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(clip.speed == speed ? Color.white : Color.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(clip.speed == speed ? Color.black : Color.white)
                        }
                    }
                }

                if clip.kind == .video {
                    HStack {
                        Image(systemName: clip.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                        Slider(value: Binding(get: { Double(clip.volume) },
                                              set: { value in change { $0.setVolume(clip.id, Float(value)) } }),
                               in: 0...2)
                    }
                }

                HStack(spacing: 10) {
                    action("scissors", "Split") { change { _ = $0.split(at: time) } }
                    action("arrow.left", "Move") { change { $0.move(clip.id, by: -1) } }
                    action("arrow.right", "Move") { change { $0.move(clip.id, by: 1) } }
                    action("trash", "Delete") {
                        change { $0.remove(clip.id) }
                        select(nil)
                    }
                    .disabled(project.clips.count < 2)
                }
            }
            .foregroundStyle(.white)
        } else {
            Text("Tap a clip on the timeline to edit it.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func action(_ symbol: String, _ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct TextPanel: View {
    let project: StudioProject
    @Binding var editing: UUID?
    let time: Double
    let change: ((inout StudioProject) -> Void) -> Void

    private let colors = ["#FFFFFF", "#000000", "#FE2C55", "#25F4EE", "#FFD60A", "#34C759", "#AF52DE"]
    private var text: StudioText? { project.texts.first { $0.id == editing } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text {
                TextField("Type something", text: Binding(
                    get: { text.text },
                    set: { value in update(text.id) { $0.text = value } }
                ), axis: .vertical)
                .lineLimit(1...3)
                .font(.body.weight(.semibold))
                .padding(10)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 8) {
                    ForEach(StudioText.Style.allCases, id: \.self) { style in
                        Button { update(text.id) { $0.style = style } } label: {
                            Text(style.rawValue.capitalized)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(text.style == style ? Color.white : Color.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(text.style == style ? Color.black : Color.white)
                        }
                    }
                }
                HStack(spacing: 10) {
                    ForEach(colors, id: \.self) { hex in
                        Button { update(text.id) { $0.color = hex } } label: {
                            Circle().fill(Color(uiColor: UIColor(hex: hex) ?? .white))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(text.color == hex ? Color.white : Color.white.opacity(0.3), lineWidth: text.color == hex ? 3 : 1))
                        }
                    }
                }
                labelledSlider("Size", value: text.size, range: 0.025...0.09) { value in update(text.id) { $0.size = value } }
                labelledSlider("Up / down", value: text.y, range: 0.08...0.92) { value in update(text.id) { $0.y = value } }
                labelledSlider("Left / right", value: text.x, range: 0.15...0.85) { value in update(text.id) { $0.x = value } }
                HStack {
                    Button(text.end == nil ? "Showing the whole video" : "Show from here for 3s") {
                        update(text.id) { item in
                            if item.end == nil {
                                item.start = time
                                item.end = min(project.duration, time + 3)
                            } else {
                                item.start = 0
                                item.end = nil
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    Spacer()
                    Button(role: .destructive) {
                        change { $0.texts.removeAll { $0.id == text.id } }
                        editing = nil
                    } label: { Image(systemName: "trash") }
                }
            } else {
                Button {
                    let new = StudioText(text: "Your text")
                    change { $0.texts.append(new) }
                    editing = new.id
                } label: {
                    Label("Add text", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !project.texts.isEmpty {
                    Text("Or tap a text on the timeline to change it.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func update(_ id: UUID, _ edit: @escaping (inout StudioText) -> Void) {
        change { project in
            if let index = project.texts.firstIndex(where: { $0.id == id }) { edit(&project.texts[index]) }
        }
    }

    private func labelledSlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}

private struct FilterPanel: View {
    let project: StudioProject
    let change: ((inout StudioProject) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(StudioFilter.allCases) { filter in
                        Button { change { $0.filter = filter } } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(swatch(filter))
                                    .frame(width: 62, height: 62)
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(project.filter == filter ? Color.white : Color.clear, lineWidth: 2.5))
                                Text(filter.title).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if project.filter != .none {
                HStack {
                    Text("Strength").font(.caption)
                    Slider(value: Binding(get: { project.filterIntensity },
                                          set: { value in change { $0.filterIntensity = value } }), in: 0...1)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func swatch(_ filter: StudioFilter) -> LinearGradient {
        let colors: [Color] = switch filter {
        case .none:  [.gray, .white.opacity(0.6)]
        case .vivid: [.pink, .orange]
        case .warm:  [.orange, .yellow]
        case .cool:  [.blue, .teal]
        case .mono:  [.black, .white]
        case .fade:  [.gray.opacity(0.6), .white.opacity(0.4)]
        case .noir:  [.black, .gray]
        case .film:  [.brown, .orange.opacity(0.6)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct AdjustPanel: View {
    let project: StudioProject
    let change: ((inout StudioProject) -> Void) -> Void

    var body: some View {
        VStack(spacing: 10) {
            row("sun.max", "Brightness", project.adjust.brightness, -0.3...0.3) { v in change { $0.adjust.brightness = v } }
            row("circle.lefthalf.filled", "Contrast", project.adjust.contrast, 0.5...1.5) { v in change { $0.adjust.contrast = v } }
            row("drop", "Saturation", project.adjust.saturation, 0...2) { v in change { $0.adjust.saturation = v } }
            row("thermometer.medium", "Warmth", project.adjust.warmth, -1...1) { v in change { $0.adjust.warmth = v } }
            if !project.adjust.isNeutral {
                Button("Reset") { change { $0.adjust = StudioAdjust() } }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
    }

    private func row(_ symbol: String, _ title: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22)
            Text(title).font(.caption).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}
