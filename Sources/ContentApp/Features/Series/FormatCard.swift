import AVKit
import SwiftUI

/// The step bar of Start a series (Abel, 5 Nov 2026: "in the middle of the
/// split, add something like a checkmark inside"): a bar per step, a check on
/// each one finished, the current one half filled.
struct SeriesStepBar: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                ZStack {
                    Capsule()
                        .fill(index < current ? Theme.accent : Color.track)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            if index == current {
                                GeometryReader { proxy in
                                    Capsule().fill(Theme.accent).frame(width: proxy.size.width / 2, height: 4)
                                }
                                .frame(height: 4)
                            }
                        }
                    if index < current {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Theme.accent))
                            .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 20)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// A sample video playing on a loop, muted: what a format looks like.
struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
        coordinator.looper = nil
    }

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// One format to pick: its sample video, a Watch button, its name, a line,
/// and what a video costs.
struct FormatCard: View {
    let template: ContentTemplate
    let isChosen: Bool
    let cost: String?
    let choose: () -> Void
    let watch: () -> Void

    var body: some View {
        Button(action: choose) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = template.previewURL {
                        LoopingVideo(url: url)
                    } else {
                        StyleCover(slug: template.slug, symbol: template.symbol)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(template.tagline)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                    if let cost {
                        Text(cost)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .padding(.top, 4)
                    }
                }
                .padding(12)
            }
            .frame(height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: isChosen ? 3 : 0)
            }
            .overlay(alignment: .bottomTrailing) {
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Theme.accent)
                        .padding(10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isChosen ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if template.previewURL != nil {
                Button(action: watch) {
                    Label("Watch", systemImage: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Watch a sample of \(template.name)")
            }
        }
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}

/// A format's sample, full screen with sound, and the button that picks it.
struct FormatPreview: View {
    let template: ContentTemplate
    let use: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(template.name)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text(template.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Button(action: use) {
                    Text("Use this format")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                .padding(.top, 6)
            }
            .padding(20)
            .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .padding(16)
            .accessibilityLabel("Close")
        }
        .task {
            if player == nil, let url = template.previewURL {
                let made = AVPlayer(url: url)
                made.actionAtItemEnd = .none
                player = made
                made.play()
            }
        }
        .onDisappear { player?.pause() }
    }
}
