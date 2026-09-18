import SwiftUI
import AVFoundation
import PhotosUI
import CoreImage

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

/// The editor, built from native parts: a big preview, a scrubber, the clips
/// in a row, and a bottom toolbar whose tools open ordinary sheets -- Clip,
/// Sound, Text, Filters, Adjust. Every change re-renders through the same
/// compositor the export uses, so the preview is the post.
struct EditorView: View {
    enum Tool: String, Identifiable, CaseIterable {
        case clip = "Clip", sound = "Sound", text = "Text", filters = "Filters", adjust = "Adjust"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .clip:    "timeline.selection"
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
    @State private var wantsTikTokSound = false
    @State private var rebuild = 0
    @State private var adding: [PhotosPickerItem] = []
    @State private var exportProgress: Double?
    @State private var exportTask: Task<Void, Never>?
    @State private var rendered: Rendered?
    @State private var problem: String?

    init(clips: [StudioClip]) {
        _project = State(initialValue: StudioProject(clips: clips))
    }

    private var selectedClip: StudioClip? {
        project.clips.first { $0.id == (selected ?? currentClipID) }
    }

    private var currentClipID: UUID? {
        project.clip(at: playback.time).map { project.clips[$0.index].id }
    }

    var body: some View {
        VStack(spacing: 14) {
            preview
            scrubber
            clipStrip
        }
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next") { startExport() }
                    .buttonStyle(RemiFilledButtonStyle())
                    .controlSize(.small)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                ForEach(Tool.allCases) { item in
                    Button {
                        if item == .clip && selected == nil { selected = currentClipID }
                        tool = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .labelStyle(ToolLabelStyle())
                    }
                    if item != Tool.allCases.last { Spacer() }
                }
            }
        }
        .toolbar(.visible, for: .bottomBar)
        .task(id: rebuild) { await rebuildPlayer() }
        .task(id: adding) { await addPicked() }
        .onDisappear { playback.player.pause() }
        .sheet(item: $tool) { item in sheet(item) }
        .navigationDestination(item: $rendered) { video in
            ComposeView(video: video.url, attribution: video.attribution, preferDrafts: video.tiktokSound)
        }
        .overlay { if let exportProgress { exportOverlay(exportProgress) } }
        .alert("Something went wrong", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Preview

    private var preview: some View {
        PlayerSurface(player: playback.player)
            .aspectRatio(9 / 16, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if !playback.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.ultraThinMaterial, in: Circle())
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { playback.toggle(duration: project.duration) }
            .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
            .frame(maxHeight: 440)
            .padding(.horizontal, Style.gutter)
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Button { playback.toggle(duration: project.duration) } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 32)
            }
            Slider(value: Binding(
                get: { min(playback.time, project.duration) },
                set: { playback.seek($0) }
            ), in: 0...max(0.1, project.duration))
            Text("\(Clock.format(playback.time)) / \(Clock.format(project.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!history.canUndo)
                Button { redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!history.canRedo)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle").font(.title3)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, Style.gutter)
    }

    private var clipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(project.clips.enumerated()), id: \.element.id) { index, clip in
                    ClipThumb(clip: clip, selected: selected == clip.id)
                        .onTapGesture {
                            selected = clip.id
                            playback.seek(project.start(of: index) + 0.01)
                        }
                        .contextMenu {
                            Button { selected = clip.id; tool = .clip } label: { Label("Edit clip", systemImage: "slider.horizontal.below.rectangle") }
                            Button { change { $0.move(clip.id, by: -1) } } label: { Label("Move left", systemImage: "arrow.left") }
                            Button { change { $0.move(clip.id, by: 1) } } label: { Label("Move right", systemImage: "arrow.right") }
                            if project.clips.count > 1 {
                                Button(role: .destructive) { change { $0.remove(clip.id) } } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
                PhotosPicker(selection: $adding, maxSelectionCount: 10, selectionBehavior: .ordered,
                             matching: .any(of: [.videos, .images])) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 58, height: 84)
                        .background(Color.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Add clips")
            }
            .padding(.horizontal, Style.gutter)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func sheet(_ item: Tool) -> some View {
        switch item {
        case .clip:
            ClipSheet(project: project, clipID: selectedClip?.id, time: playback.time, change: change) { selected = $0 }
        case .sound:
            SoundPickerSheet(project: $project, wantsTikTokSound: $wantsTikTokSound) { _ in rebuild += 1 }
        case .text:
            TextSheet(project: project, time: playback.time, change: change)
        case .filters:
            FilterSheet(project: project, change: change)
        case .adjust:
            AdjustSheet(project: project, change: change)
        }
    }

    private func exportOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressRing(progress: progress, lineWidth: 6, color: .accentColor)
                    .frame(width: 76, height: 76)
                    .overlay(Text("\(Int(progress * 100))%").font(.headline.monospacedDigit()))
                Text("Making your video").font(.headline)
                Text("Full quality, nothing compressed away.").font(.footnote).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) {
                    exportTask?.cancel()
                    exportProgress = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
        if let previous = history.undo(project) { project = previous; rebuild += 1 }
    }

    private func redo() {
        if let next = history.redo(project) { project = next; rebuild += 1 }
    }

    private func addPicked() async {
        guard !adding.isEmpty else { return }
        do {
            let clips = try await StudioImport.clips(from: adding)
            change { $0.clips.append(contentsOf: clips) }
        } catch {
            problem = "Those couldn't be added. They may still be downloading from iCloud."
        }
        adding = []
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
        } catch {
            problem = "This clip couldn't be played."
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
                if !Task.isCancelled { problem = "The video couldn't be made. Try again." }
            }
        }
    }
}

// MARK: - Player

struct PlayerSurface: UIViewRepresentable {
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

/// One clip in the strip: its first frame, its length, its speed.
private struct ClipThumb: View {
    let clip: StudioClip
    let selected: Bool
    @State private var thumb: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.track
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
            HStack(spacing: 3) {
                Text(Clock.format(clip.duration))
                if clip.speed != 1 { Text(String(format: "· %gx", clip.speed)) }
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(5)
        }
        .frame(width: 58, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3)
        }
        .task(id: clip.url) {
            if clip.kind == .photo {
                thumb = UIImage(contentsOfFile: clip.url.path)
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 200, height: 200)
                if let image = try? await generator.image(at: StudioComposer.seconds(clip.trimStart + 0.1)).image {
                    thumb = UIImage(cgImage: image)
                }
            }
        }
    }
}

// MARK: - Sheets

private struct ClipSheet: View {
    let project: StudioProject
    let clipID: UUID?
    let time: Double
    let change: ((inout StudioProject) -> Void) -> Void
    let select: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    private var clip: StudioClip? { project.clips.first { $0.id == clipID } }
    private let speeds: [Double] = [0.5, 1, 1.5, 2, 3]

    var body: some View {
        NavigationStack {
            Form {
                if let clip {
                    Section("Trim") {
                        LabeledContent("Start", value: String(format: "%.1fs", clip.trimStart))
                        Slider(value: Binding(get: { clip.trimStart },
                                              set: { v in change { $0.trim(clip.id, start: v, end: clip.trimEnd) } }),
                               in: 0...max(0.3, clip.sourceDuration - StudioProject.shortest))
                        LabeledContent("End", value: String(format: "%.1fs", clip.trimEnd))
                        Slider(value: Binding(get: { clip.trimEnd },
                                              set: { v in change { $0.trim(clip.id, start: clip.trimStart, end: v) } }),
                               in: min(clip.sourceDuration - 0.01, StudioProject.shortest)...clip.sourceDuration)
                    }
                    Section("Speed") {
                        Picker("Speed", selection: Binding(get: { clip.speed },
                                                           set: { v in change { $0.setSpeed(clip.id, v) } })) {
                            ForEach(speeds, id: \.self) { speed in
                                Text(String(format: "%gx", speed)).tag(speed)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    if clip.kind == .video {
                        Section("Clip sound") {
                            Slider(value: Binding(get: { Double(clip.volume) },
                                                  set: { v in change { $0.setVolume(clip.id, Float(v)) } }), in: 0...2) {
                                Text("Volume")
                            } minimumValueLabel: {
                                Image(systemName: "speaker.slash")
                            } maximumValueLabel: {
                                Image(systemName: "speaker.wave.3")
                            }
                        }
                    }
                    Section {
                        Button { change { _ = $0.split(at: time) } } label: {
                            Label("Split at the playhead", systemImage: "scissors")
                        }
                        Button { change { $0.move(clip.id, by: -1) } } label: {
                            Label("Move earlier", systemImage: "arrow.left")
                        }
                        Button { change { $0.move(clip.id, by: 1) } } label: {
                            Label("Move later", systemImage: "arrow.right")
                        }
                        if project.clips.count > 1 {
                            Button(role: .destructive) {
                                change { $0.remove(clip.id) }
                                select(nil)
                                dismiss()
                            } label: {
                                Label("Delete clip", systemImage: "trash")
                            }
                        }
                    }
                } else {
                    Text("Tap a clip in the strip to edit it.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct TextSheet: View {
    let project: StudioProject
    let time: Double
    let change: ((inout StudioProject) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editing: UUID?

    private var text: StudioText? { project.texts.first { $0.id == editing } }

    var body: some View {
        NavigationStack {
            Form {
                if let text {
                    Section {
                        TextField("Your text", text: Binding(get: { text.text }, set: { v in update(text.id) { $0.text = v } }),
                                  axis: .vertical)
                            .lineLimit(1...4)
                    }
                    Section("Look") {
                        Picker("Style", selection: Binding(get: { text.style }, set: { v in update(text.id) { $0.style = v } })) {
                            ForEach(StudioText.Style.allCases, id: \.self) { style in
                                Text(style.rawValue.capitalized).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        ColorPicker("Colour", selection: Binding(
                            get: { Color(uiColor: UIColor(hex: text.color) ?? .white) },
                            set: { v in update(text.id) { $0.color = UIColor(v).hex } }
                        ), supportsOpacity: false)
                        LabeledContent("Size") {
                            Slider(value: Binding(get: { text.size }, set: { v in update(text.id) { $0.size = v } }), in: 0.025...0.09)
                                .frame(maxWidth: 200)
                        }
                    }
                    Section("Place") {
                        Picker("Position", selection: Binding(
                            get: { text.y < 0.35 ? 0 : (text.y > 0.65 ? 2 : 1) },
                            set: { v in update(text.id) { $0.y = [0.18, 0.5, 0.8][v] } }
                        )) {
                            Text("Top").tag(0)
                            Text("Middle").tag(1)
                            Text("Bottom").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Show for the whole video", isOn: Binding(
                            get: { text.end == nil },
                            set: { whole in update(text.id) { item in
                                if whole { item.start = 0; item.end = nil } else {
                                    item.start = time
                                    item.end = min(project.duration, time + 3)
                                }
                            } }
                        ))
                    }
                    Section {
                        Button(role: .destructive) {
                            change { $0.texts.removeAll { $0.id == text.id } }
                            editing = nil
                        } label: { Label("Delete text", systemImage: "trash") }
                    }
                } else {
                    Section {
                        Button {
                            let new = StudioText(text: "Your text")
                            change { $0.texts.append(new) }
                            editing = new.id
                        } label: { Label("Add text", systemImage: "plus") }
                    }
                    if !project.texts.isEmpty {
                        Section("On this video") {
                            ForEach(project.texts) { item in
                                Button(item.text.isEmpty ? "Text" : item.text) { editing = item.id }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editing != nil {
                    ToolbarItem(placement: .cancellationAction) { Button("All text") { editing = nil } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { if project.texts.count == 1 { editing = project.texts[0].id } }
    }

    private func update(_ id: UUID, _ edit: @escaping (inout StudioText) -> Void) {
        change { project in
            if let index = project.texts.firstIndex(where: { $0.id == id }) { edit(&project.texts[index]) }
        }
    }
}

private struct FilterSheet: View {
    let project: StudioProject
    let change: ((inout StudioProject) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previews: [StudioFilter: UIImage] = [:]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(StudioFilter.allCases) { filter in
                        Button { change { $0.filter = filter } } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Color.track
                                    if let image = previews[filter] {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    }
                                }
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(project.filter == filter ? Color.accentColor : .clear, lineWidth: 3)
                                }
                                Text(filter.title)
                                    .font(.caption.weight(project.filter == filter ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Style.gutter)

                if project.filter != .none {
                    Slider(value: Binding(get: { project.filterIntensity },
                                          set: { v in change { $0.filterIntensity = v } }), in: 0...1) {
                        Text("Strength")
                    } minimumValueLabel: {
                        Text("Light").font(.caption)
                    } maximumValueLabel: {
                        Text("Full").font(.caption)
                    }
                    .padding(.horizontal, Style.gutter)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { await makePreviews() }
    }

    /// Each filter on the video's own first frame.
    private func makePreviews() async {
        guard let first = project.clips.first else { return }
        var frame: CIImage?
        if first.kind == .photo {
            frame = CIImage(contentsOf: first.url, options: [.applyOrientationProperty: true])
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: first.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            if let cg = try? await generator.image(at: StudioComposer.seconds(first.trimStart + 0.1)).image {
                frame = CIImage(cgImage: cg)
            }
        }
        guard let frame else { return }
        let context = CIContext()
        for filter in StudioFilter.allCases {
            let look = StudioLook(filter: filter, intensity: 1, adjust: project.adjust)
            let output = look.apply(to: frame)
            if let cg = context.createCGImage(output, from: frame.extent) {
                previews[filter] = UIImage(cgImage: cg)
            }
        }
    }
}

private struct AdjustSheet: View {
    let project: StudioProject
    let change: ((inout StudioProject) -> Void) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                row("Brightness", "sun.max", project.adjust.brightness, -0.3...0.3) { v in change { $0.adjust.brightness = v } }
                row("Contrast", "circle.lefthalf.filled", project.adjust.contrast, 0.5...1.5) { v in change { $0.adjust.contrast = v } }
                row("Saturation", "drop", project.adjust.saturation, 0...2) { v in change { $0.adjust.saturation = v } }
                row("Warmth", "thermometer.medium", project.adjust.warmth, -1...1) { v in change { $0.adjust.warmth = v } }
                if !project.adjust.isNeutral {
                    Section {
                        Button("Reset", role: .destructive) { change { $0.adjust = StudioAdjust() } }
                    }
                }
            }
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ symbol: String, _ value: Double, _ range: ClosedRange<Double>,
                     set: @escaping (Double) -> Void) -> some View {
        Section {
            Slider(value: Binding(get: { value }, set: set), in: range) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: symbol).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(String(format: "%+.0f", (value - (range.lowerBound + range.upperBound) / 2) / (range.upperBound - range.lowerBound) * 200))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        } header: {
            Text(title)
        }
    }
}

extension UIColor {
    /// "#RRGGBB"
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}

/// A bottom-toolbar tool: the symbol over a small title.
private struct ToolLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.font(.system(size: 18, weight: .medium))
            configuration.title.font(.caption2.weight(.medium))
        }
        .frame(minWidth: 52)
    }
}
