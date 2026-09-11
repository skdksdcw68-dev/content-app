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
private func mediaSize(width: Int?, height: Int?) -> CGSize {
    let aspect: CGFloat = {
        if let width, let height, width > 0, height > 0 { return CGFloat(width) / CGFloat(height) }
        return 9.0 / 16.0
    }()
    let maxWidth: CGFloat = 250, maxHeight: CGFloat = 400
    var size = CGSize(width: maxWidth, height: maxWidth / aspect)
    if size.height > maxHeight { size = CGSize(width: maxHeight * aspect, height: maxHeight) }
    return size
}

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
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(PressButtonStyle())
            .disabled(shown == nil)
            .accessibilityLabel("Open the image")

            MediaActions(artifact: artifact, onAnimate: onAnimate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: artifact.id) {
            guard picture == nil else { return }
            picture = await session.picture(of: artifact, longest: pixels)
        }
        .fullScreenCover(isPresented: $viewing) {
            MediaViewer(artifact: artifact, preview: shown, onAnimate: onAnimate)
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
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture { if shownFile != nil { viewing = true } }
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

            MediaActions(artifact: artifact, onAnimate: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: artifact.id) {
            if file == nil { file = await session.localCopy(of: artifact) }
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
    }
}

// MARK: - What can be done with it

/// Under a result: Animate in words, because it is the thing this app adds,
/// then the quiet icons every chat app has -- share, save -- and what it was
/// made with.
private struct MediaActions: View {
    let artifact: Artifact
    let onAnimate: ((Artifact) -> Void)?

    @Environment(AppSession.self) private var session
    @State private var file: URL?
    @State private var saving = false
    @State private var outcome: AppSession.SaveOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                if let onAnimate {
                    Button { onAnimate(artifact) } label: {
                        Label("Animate", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.trailing, 8)
                }

                if let file {
                    ShareLink(item: file) { icon("square.and.arrow.up") }
                        .accessibilityLabel("Share")
                } else {
                    icon("square.and.arrow.up").opacity(0.35)
                }

                Button(action: save) {
                    icon(outcome == .saved ? "checkmark" : "arrow.down.to.line")
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel("Save to Photos")
            }

            let caption = outcome == .notAllowed
                ? "Turn on Photos access for Autocast in Settings to save."
                : outcome == .failed ? "That didn't save. Try again." : mediaCaption(artifact)
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
        .sensoryFeedback(.success, trigger: outcome == .saved)
        .task(id: artifact.id) {
            file = session.cachedCopy(of: artifact)
            if file == nil { file = await session.localCopy(of: artifact) }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
    }

    private func save() {
        saving = true
        Task {
            let result = await session.saveToPhotos(artifact)
            withAnimation { outcome = result }
            saving = false
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { outcome = nil }
        }
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

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picture: UIImage?
    @State private var file: URL?
    @State private var player: LoopingPlayer?
    @State private var zoom: CGFloat = 1
    @State private var drag: CGFloat = 0
    @State private var notice: String?
    @State private var saving = false
    @State private var saves = 0

    private var isVideo: Bool { artifact.kind == "video" }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(0.7, abs(drag) / 500))
                .ignoresSafeArea()

            content
                .offset(y: drag)
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
                .scaleEffect(zoom)
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom = max(1, $0.magnification) }
                        .onEnded { _ in withAnimation(.spring(duration: 0.3)) { zoom = 1 } }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard zoom == 1 else { return }
                            drag = value.translation.height
                        }
                        .onEnded { value in
                            if abs(value.translation.height) > 120 || abs(value.predictedEndTranslation.height) > 400 {
                                dismiss()
                            } else {
                                withAnimation(.spring(duration: 0.3)) { drag = 0 }
                            }
                        }
                )
        } else {
            ProgressView().tint(.white)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                circle("xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer()

            Menu {
                Section(mediaCaption(artifact)) {
                    if let prompt = artifact.body.prompt, !prompt.isEmpty {
                        Button {
                            UIPasteboard.general.string = prompt
                            flash("Prompt copied")
                        } label: {
                            Label("Copy prompt", systemImage: "doc.on.doc")
                        }
                    }
                }
            } label: {
                circle("ellipsis")
            }
            .accessibilityLabel("More")

            Button(action: save) {
                circle("arrow.down.to.line")
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityLabel("Save to Photos")

            if let file {
                ShareLink(item: file) {
                    Text("Share")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .frame(height: 46)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(PressButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let onAnimate, !isVideo {
            VStack(spacing: 8) {
                Button {
                    dismiss()
                    onAnimate(artifact)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)

                Text("Animate")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 16)
        }
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
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
