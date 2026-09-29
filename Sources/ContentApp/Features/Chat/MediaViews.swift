import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - Size and caption

/// How big a picture or video sits in the conversation: its real shape, on the
/// agent's side, never wider than a comfortable column or taller than a
/// screenful.
///
/// Computed, not left to layout. An image told only "fit, at most 380 tall"
/// took the full column width and centred the picture inside it -- which is why
/// results sat in the middle of the chat however the card was aligned.
/// A result in a conversation is a thumbnail, not a poster. 250x400 filled most
/// of the page for one picture -- "tooo big" -- and a tall one pushed the reply
/// that made it off the screen. Tap opens it properly.
func mediaSize(width: Int?, height: Int?) -> CGSize {
    let aspect: CGFloat = {
        if let width, let height, width > 0, height > 0 { return CGFloat(width) / CGFloat(height) }
        return 9.0 / 16.0
    }()
    let maxWidth: CGFloat = 200, maxHeight: CGFloat = 260
    var size = CGSize(width: maxWidth, height: maxWidth / aspect)
    if size.height > maxHeight { size = CGSize(width: maxHeight * aspect, height: maxHeight) }
    return size
}

/// The corner every result shares. Smaller than the cards around it, because a
/// picture with a 20-point radius reads as a sticker.
private let mediaCorner: CGFloat = 14

/// The line under a result: which model, what setting, what it cost.
private func mediaCaption(_ artifact: Artifact) -> String {
    var parts: [String] = []
    if let label = artifact.body.modelLabel { parts.append(label) }
    if let resolution = artifact.body.resolution {
        parts.append(resolution.hasSuffix("k") ? resolution.uppercased() : resolution)
    }
    if let seconds = artifact.body.seconds { parts.append("\(Int(seconds.rounded()))s") }
    let cost = artifact.actualCost ?? artifact.estimatedCost
    if let amount = cost?.amount, let unit = cost?.unit {
        parts.append("\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(unit)")
    }
    return parts.joined(separator: " · ")
}

private func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Image

/// A picture that was made, at its real shape. Tap to open it full screen.
///
/// Drawn from the phone's copy once there is one (see `MediaCache`), and read
/// from memory synchronously when the row comes back on screen -- so scrolling
/// up and down a conversation never shows the spinner twice.
struct ImageCard: View {
    let artifact: Artifact
    let onAnimate: (Artifact) -> Void
    var onReference: ((Artifact) -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var picture: UIImage?
    @State private var viewing = false

    private var size: CGSize { mediaSize(width: artifact.body.width, height: artifact.body.height) }
    private var pixels: CGFloat { max(size.width, size.height) * displayScale }
    private var key: NSString { MediaCache.key(artifact.id, "\(Int(pixels))") }

    var body: some View {
        let shown = picture ?? MediaCache.shared.image(key)

        VStack(alignment: .leading, spacing: 6) {
            Button { viewing = true } label: {
                ZStack {
                    if let shown {
                        Image(uiImage: shown).resizable().scaledToFill()
                    } else {
                        Theme.surface.overlay { ProgressView().controlSize(.small) }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: mediaCorner, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: mediaCorner, style: .continuous))
            }
            .buttonStyle(PressButtonStyle())
            .disabled(shown == nil)
            .accessibilityLabel("Open the image")
            .contextMenu { MediaMenu(artifact: artifact, onAnimate: onAnimate, onReference: onReference) }

            MediaFooting(artifact: artifact, onAnimate: onAnimate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: artifact.id) {
            guard picture == nil else { return }
            picture = await session.picture(of: artifact, longest: pixels)
        }
        .fullScreenCover(isPresented: $viewing) {
            MediaViewer(artifact: artifact, preview: shown, onAnimate: onAnimate, onReference: onReference)
        }
    }
}

// MARK: - Video

/// A video the way a feed shows one: playing on its own, silently, on a loop,
/// at its real shape. The speaker turns sound on; tap anywhere else to open it
/// full screen.
///
/// Plays the phone's copy, never a link: a link was a fresh download each time
/// the row came back on screen. Its first frame sits underneath, so the row is
/// never an empty box while the player gets going.
struct VideoCard: View {
    let artifact: Artifact

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var file: URL?
    @State private var poster: UIImage?
    @State private var muted = true
    @State private var viewing = false
    /// How far the download has got, for the percentage over the poster.
    @State private var arriving: (received: Int64, expected: Int64?)?
    /// Opened full screen, because the editor is a screen rather than a sheet
    /// and this card can sit inside a scrolling conversation.
    @State private var editing: EditableClip?

    private var size: CGSize { mediaSize(width: artifact.body.width, height: artifact.body.height) }
    private var pixels: CGFloat { max(size.width, size.height) * displayScale }
    private var posterKey: NSString { MediaCache.key(artifact.id, "poster\(Int(pixels))") }

    var body: some View {
        let shownFile = file ?? session.cachedCopy(of: artifact)
        let shownPoster = poster ?? MediaCache.shared.image(posterKey)

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let shownPoster {
                    Image(uiImage: shownPoster).resizable().scaledToFill()
                } else {
                    Theme.surface
                }
                if let shownFile {
                    LoopingVideo(url: shownFile, muted: muted, playing: !viewing)
                } else if let arriving {
                    // The percentage, the way ElevenLabs shows one: the number
                    // and nothing else. It says whether to wait, which a
                    // spinner never does. No total means no percentage -- the
                    // view falls back to bytes rather than inventing one.
                    DownloadProgressView(
                        fraction: arriving.expected.map { Double(arriving.received) / Double(max($0, 1)) },
                        received: arriving.received,
                        title: "",
                        compact: true,
                        onDark: shownPoster != nil
                    )
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: mediaCorner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: mediaCorner, style: .continuous))
            .onTapGesture { if shownFile != nil { viewing = true } }
            .contextMenu {
                MediaMenu(artifact: artifact, onAnimate: nil) { file in
                    Task { editing = await EditableClip.of(file) }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let seconds = artifact.body.seconds {
                    Text(clock(seconds))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    muted.toggle()
                    PlaybackAudio.sound(!muted)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(muted ? "Turn sound on" : "Mute")
            }

            MediaFooting(artifact: artifact, onAnimate: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: artifact.id) {
            if file == nil {
                // Through the streaming path, so there is a number to show
                // while it comes rather than a spinner that says nothing.
                for await step in session.fileStream(of: artifact) {
                    switch step {
                    case .progress(let received, let expected):
                        arriving = (received, expected)
                    case .done(let url):
                        arriving = nil
                        file = url
                    case .failed:
                        arriving = nil
                    }
                }
            }
            if poster == nil { poster = await session.poster(of: artifact, longest: pixels) }
        }
        .onDisappear {
            if !muted {
                muted = true
                PlaybackAudio.sound(false)
            }
        }
        .fullScreenCover(isPresented: $viewing) {
            MediaViewer(artifact: artifact, preview: shownPoster)
        }
        .fullScreenCover(item: $editing) { editable in
            NavigationStack { EditorView(clips: [editable.clip]) }
        }
    }
}

// MARK: - Audio

/// Music or a voice line, as a player rather than a file to open.
///
/// The same shape as everything else made here: the actual thing, on the
/// agent's side, with what it was made with underneath. Plays the phone's
/// copy, so replaying it costs nothing.
struct AudioCard: View {
    let artifact: Artifact

    @Environment(AppSession.self) private var session
    @State private var file: URL?
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var progress: Double = 0
    @State private var watcher: Any?

    private var length: Double? { artifact.body.seconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.accent))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressButtonStyle())
                .disabled(file == nil && session.cachedCopy(of: artifact) == nil)
                .accessibilityLabel(playing ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 6) {
                    Text(artifact.body.prompt ?? artifact.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // A plain line filling as it plays: a waveform we did not
                    // measure would be decoration pretending to be data.
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule().fill(Theme.accent)
                                .frame(width: max(0, min(1, progress)) * proxy.size.width)
                        }
                    }
                    .frame(height: 4)
                }

                if let length {
                    Text(clock(length))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 280)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface)
            }

            MediaFooting(artifact: artifact, onAnimate: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: artifact.id) {
            guard file == nil else { return }
            file = session.cachedCopy(of: artifact)
            if file == nil { file = await session.localCopy(of: artifact) }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if playing {
            player?.pause()
            playing = false
            return
        }
        guard let url = file ?? session.cachedCopy(of: artifact) else { return }
        PlaybackAudio.sound(true)
        let engine = player ?? AVPlayer(url: url)
        player = engine
        if watcher == nil {
            watcher = engine.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
            ) { time in
                // Hopping back to the main actor: the observer's queue is main,
                // but the compiler cannot know that.
                let seconds = time.seconds
                Task { @MainActor in advance(to: seconds) }
            }
        }
        engine.play()
        playing = true
    }

    private func advance(to seconds: Double) {
        let total = player?.currentItem?.duration.seconds
        let whole = (total?.isFinite == true ? total : length) ?? 0
        guard whole > 0 else { return }
        progress = seconds / whole
        if seconds >= whole - 0.05 {
            player?.seek(to: .zero)
            player?.pause()
            playing = false
            progress = 0
        }
    }

    private func stop() {
        player?.pause()
        playing = false
        if let watcher { player?.removeTimeObserver(watcher) }
        watcher = nil
        PlaybackAudio.sound(false)
    }
}

// MARK: - What can be done with it

/// Under a result: one quiet line saying what made it, and Animate as a word.
///
/// The row of buttons that used to sit here -- a blue pill, then a glass one,
/// then grey icons -- was the thing he disliked most about results. Everything
/// they did is still here: long-press the picture, or open it.
private struct MediaFooting: View {
    let artifact: Artifact
    let onAnimate: ((Artifact) -> Void)?

    private var caption: String { mediaCaption(artifact) }

    var body: some View {
        HStack(spacing: 10) {
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let onAnimate {
                Button("Animate") { onAnimate(artifact) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.leading, 2)
    }
}

/// Everything that can be done with a result, where iOS puts it: a long press.
///
/// Shown from the card and from the viewer, so the two never drift apart.
private struct MediaMenu: View {
    let artifact: Artifact
    let onAnimate: ((Artifact) -> Void)?

    /// Handed the local file when "Add to Video Editor" is tapped. The card
    /// owns the presentation: 🔴 a `navigationDestination` or a cover declared
    /// inside `contextMenu` content is never attached to the hierarchy, so the
    /// menu item would have looked right and done nothing.
    ///
    /// Declared BEFORE `onReference` on purpose: a trailing closure binds to
    /// the first closure parameter it can, and `VideoCard` hands this one its
    /// closure that way.
    var onAddToEditor: ((URL) -> Void)? = nil
    /// Sets this picture up as the reference for the next request.
    var onReference: ((Artifact) -> Void)? = nil

    @Environment(AppSession.self) private var session
    @State private var file: URL?

    var body: some View {
        // ElevenLabs' order, with the items Autocast can actually carry out.
        //
        // Theirs reads Upscale / Edit / Lip sync / Add to Video Editor / Copy
        // prompt / Download / Delete. The first three want a model chosen for
        // this file, which is the generate path and not wired here yet, and
        // there is no way to delete an artifact at all -- so they are absent
        // rather than present and dead. A menu item that does nothing is the
        // same fault as the "Needs attention" rows that could not be tapped.
        Group {
            if let onReference, artifact.kind == "image" {
                Button { onReference(artifact) } label: {
                    Label("Use as reference", systemImage: "photo.badge.plus")
                }
            }
            if let onAnimate {
                Button { onAnimate(artifact) } label: {
                    Label("Animate", systemImage: "sparkles")
                }
            }
            if artifact.kind == "video", let file, let onAddToEditor {
                Button { onAddToEditor(file) } label: {
                    Label("Add to Video Editor", systemImage: "film.stack")
                }
            }
            if let prompt = artifact.body.prompt, !prompt.isEmpty {
                Button { UIPasteboard.general.string = prompt } label: {
                    Label("Copy prompt", systemImage: "doc.on.doc")
                }
            }
            Button { Task { _ = await session.saveToPhotos(artifact) } } label: {
                Label("Download", systemImage: "arrow.down.to.line")
            }
            if let file {
                ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        .task(id: artifact.id) {
            file = session.cachedCopy(of: artifact)
            if file == nil { file = await session.localCopy(of: artifact) }
        }
    }
}

/// One video on its way to the editor. Identifiable so it can drive a cover.
struct EditableClip: Identifiable, Hashable {
    let clip: StudioClip
    var id: UUID { clip.id }

    /// Reads the file's real length, the way `VideoReviewView` does, so
    /// trimming, speed and volume all work on it without a special case.
    static func of(_ file: URL) async -> EditableClip? {
        let asset = AVURLAsset(url: file)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else { return nil }
        return EditableClip(clip: StudioClip(
            kind: .video,
            url: file,
            sourceDuration: seconds,
            trimEnd: seconds
        ))
    }
}

// MARK: - Full screen

/// A result, full screen, the way ChatGPT opens one: close on the left; more,
/// save and Share on the right; what can be made of it along the bottom. Pinch
/// to look closer, drag down to put it away.
struct MediaViewer: View {
    let artifact: Artifact
    /// What the card was already showing, so the viewer opens on a picture
    /// rather than a spinner while the full-size one is read.
    var preview: UIImage? = nil
    var onAnimate: ((Artifact) -> Void)? = nil
    /// Puts this picture into the next request as a reference, so what is
    /// typed next is made from it (Abel, 29 Sep 2026: "when you are trying to
    /// use an image for a video preference, or an image preference, it's not
    /// going to attach it, and it's not going to use it").
    var onReference: ((Artifact) -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picture: UIImage?
    @State private var file: URL?
    @State private var player: LoopingPlayer?
    /// How far it is zoomed and panned, kept apart from the gesture still in
    /// flight so the two never get added twice.
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panning: CGSize = .zero
    /// The drag that puts it away: down, and a little sideways so it follows
    /// the finger the way Photos does.
    @State private var drag: CGFloat = 0
    @State private var slide: CGFloat = 0
    @State private var notice: String?
    @State private var saving = false
    @State private var saves = 0
    /// The facts pill, toggled by ⓘ.
    @State private var showingInfo = false
    /// This video on its way into the editor.
    @State private var editing: EditableClip?

    private var isVideo: Bool { artifact.kind == "video" }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(0.7, abs(drag) / 500))
                .ignoresSafeArea()

            content
                .offset(x: slide, y: drag)
        }
        .overlay(alignment: .top) { topBar.opacity(drag == 0 ? 1 : 0) }
        .overlay(alignment: .bottom) { bottomBar.opacity(drag == 0 ? 1 : 0) }
        .overlay(alignment: .bottom) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 130)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: drag == 0)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .presentationBackground(.clear)
        .sensoryFeedback(.success, trigger: saves)
        .task { await load() }
        .onDisappear {
            player?.player.pause()
            PlaybackAudio.sound(false)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isVideo {
            if let player {
                VideoPlayer(player: player.player)
                    .ignoresSafeArea()
            } else if let preview {
                Image(uiImage: preview).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        } else if let shown = picture ?? preview {
            Image(uiImage: shown)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.vertical, 88)
                .scaleEffect(zoom * pinch)
                .offset(x: pan.width + panning.width, y: pan.height + panning.height)
                .gesture(pinchToZoom)
                .simultaneousGesture(moveIt)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.3)) {
                        if zoom > 1.01 {
                            zoom = 1
                            pan = .zero
                        } else {
                            zoom = 2.5
                        }
                    }
                }
        } else {
            ProgressView().tint(.white)
        }
    }

    /// Pinch to look closer, and it STAYS closer -- it used to snap back to 1
    /// the moment the fingers came off, so there was nothing to move.
    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { pinch = $0.magnification }
            .onEnded { value in
                withAnimation(.spring(duration: 0.3)) {
                    zoom = min(max(zoom * value.magnification, 1), 5)
                    pinch = 1
                    if zoom <= 1.01 {
                        zoom = 1
                        pan = .zero
                    }
                }
            }
    }

    /// 🔴 Measured in the screen's own space, not the picture's.
    ///
    /// Abel, 29 Sep 2026: "you just click and try to move the image, and it
    /// glitches." The drag was written against the image's LOCAL coordinates
    /// while the same drag moved the image -- so every frame the finger's
    /// position was re-measured from a picture that had just moved under it,
    /// which fed straight back into the next frame: a jitter that grew with
    /// the movement. `.global` does not move when the picture does.
    ///
    /// Zoomed in, a drag pans; at rest, a drag follows the finger and lets go
    /// of the viewer when it goes far enough.
    private var moveIt: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if zoom > 1.01 {
                    panning = value.translation
                } else {
                    drag = value.translation.height
                    slide = value.translation.width * 0.6
                }
            }
            .onEnded { value in
                if zoom > 1.01 {
                    // How far the picture can travel grows with the zoom, so
                    // it can be moved to its edges and never off the screen.
                    let reach = (zoom - 1) * 200
                    withAnimation(.spring(duration: 0.3)) {
                        pan = CGSize(
                            width: max(-reach, min(reach, pan.width + value.translation.width)),
                            height: max(-reach, min(reach, pan.height + value.translation.height))
                        )
                        panning = .zero
                    }
                } else if abs(value.translation.height) > 120 || abs(value.predictedEndTranslation.height) > 400 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) {
                        drag = 0
                        slide = 0
                    }
                }
            }
    }

    /// 🔴 Laid out the way the screenshots are. Abel, 26 Sep 2026: "the way
    /// while generating, the preview, when u click the video and everything."
    ///
    /// Back on the left; ONE pill on the right holding info and the menu.
    /// Share-as-a-white-button and a bare save icon were three separate
    /// controls saying overlapping things -- they live in the bottom-right
    /// pill now, where his reference puts them.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                circle("chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Spacer()

            HStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showingInfo.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About this")

                Menu {
                    if isVideo, file != nil {
                        Button {
                            Task {
                                if let file, let clip = await EditableClip.of(file) { editing = clip }
                            }
                        } label: {
                            Label("Add to Video Editor", systemImage: "film.stack")
                        }
                    }
                    if let onReference, !isVideo {
                        Button {
                            dismiss()
                            onReference(artifact)
                        } label: {
                            Label("Use as reference", systemImage: "photo.badge.plus")
                        }
                    }
                    if let onAnimate, !isVideo {
                        Button {
                            dismiss()
                            onAnimate(artifact)
                        } label: {
                            Label("Animate", systemImage: "sparkles")
                        }
                    }
                    if let prompt = artifact.body.prompt, !prompt.isEmpty {
                        Button {
                            UIPasteboard.general.string = prompt
                            flash("Prompt copied")
                        } label: {
                            Label("Copy prompt", systemImage: "doc.on.doc")
                        }
                    }
                    Button(action: save) {
                        Label("Download", systemImage: "arrow.down.to.line")
                    }
                    if let file {
                        ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    /// The prompt in quiet grey with the two pills under it: what can be made
    /// of this on the left, share and download on the right.
    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 14) {
            if showingInfo {
                info
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let prompt = artifact.body.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            HStack {
                if isVideo {
                    Button {
                        Task {
                            if let file, let clip = await EditableClip.of(file) { editing = clip }
                        }
                    } label: {
                        circle("film.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(file == nil)
                    .accessibilityLabel("Add to Video Editor")
                } else {
                    // The two things a picture is for: something to make the
                    // next one from, and something to set moving.
                    HStack(spacing: 10) {
                        if let onReference {
                            Button {
                                dismiss()
                                onReference(artifact)
                            } label: {
                                circle("photo.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use as reference")
                        }
                        if let onAnimate {
                            Button {
                                dismiss()
                                onAnimate(artifact)
                            } label: {
                                circle("sparkles")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Animate")
                        }
                    }
                }

                Spacer()

                HStack(spacing: 0) {
                    if let file {
                        ShareLink(item: file) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: save) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    .accessibilityLabel("Download")
                }
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 16)
        .fullScreenCover(item: $editing) { editable in
            NavigationStack { EditorView(clips: [editable.clip]) }
        }
    }

    /// What this is, said in facts: the model, the shape, the length. Toggled
    /// by ⓘ rather than always drawn, because the result is the point.
    private var info: some View {
        VStack(spacing: 4) {
            if let model = artifact.body.modelLabel {
                Text(model).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            }
            HStack(spacing: 10) {
                if let w = artifact.body.width, let h = artifact.body.height {
                    Text("\(w)×\(h)")
                }
                if let resolution = artifact.body.resolution {
                    Text(resolution)
                }
                if let seconds = artifact.body.seconds {
                    Text(clock(seconds))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
    }

    private func load() async {
        file = session.cachedCopy(of: artifact)
        if file == nil { file = await session.localCopy(of: artifact) }
        if isVideo {
            guard let file, player == nil else { return }
            let looping = LoopingPlayer(url: file)
            PlaybackAudio.sound(true)
            looping.player.play()
            player = looping
        } else if picture == nil {
            // The whole picture, for looking closely -- the card holds a
            // smaller one.
            picture = await session.picture(of: artifact, longest: 3000)
        }
    }

    private func save() {
        saving = true
        Task {
            switch await session.saveToPhotos(artifact) {
            case .saved:
                saves += 1
                flash("Saved to Photos")
            case .notAllowed:
                flash("Allow Photos access in Settings")
            case .failed:
                flash("That didn't save")
            }
            saving = false
        }
    }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.2)) {
                if notice == text { notice = nil }
            }
        }
    }
}

// MARK: - Playback

/// An AVPlayerLayer that loops, plays while it is on screen and wanted, and
/// stops when it leaves -- a scrolled-past video should not keep decoding, and
/// one hidden behind the full-screen viewer should not play twice.
private struct LoopingVideo: UIViewRepresentable {
    let url: URL
    let muted: Bool
    var playing = true

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = muted
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.wantsToPlay = playing
        if playing { player.play() }
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.player?.isMuted = muted
        view.wantsToPlay = playing
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        view.playerLayer.player?.pause()
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        var wantsToPlay = true {
            didSet { if wantsToPlay != oldValue { apply() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            if window != nil, wantsToPlay { playerLayer.player?.play() } else { playerLayer.player?.pause() }
        }
    }
}

/// The full-screen player's loop, held for as long as the viewer is open.
@MainActor
final class LoopingPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL) {
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }
}

/// Sound only when somebody asked for it. A muted video playing in the chat
/// mixes with whatever they are listening to; tapping for sound, or opening
/// it full screen, plays through even with the ringer switch off -- the way
/// every video app behaves, and without which "tap for sound" did nothing on
/// a silenced phone.
enum PlaybackAudio {
    static func sound(_ on: Bool) {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(on ? .playback : .ambient, mode: on ? .moviePlayback : .default)
        try? audio.setActive(true)
    }
}
