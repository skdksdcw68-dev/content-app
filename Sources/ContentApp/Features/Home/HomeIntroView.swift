import SwiftUI

/// The first thing Home shows, once: a short motion piece of an iPhone with a
/// Dynamic Island, the camera zooming in and out across what Autocast does.
///
/// Netro, 19 Oct 2026: "when a user opens the app for the first time... a good
/// recorded video with good motion graphics or zoom in and zoom out with an
/// iPhone glass that has an iPhone frame. I'm talking about a perfect dynamic
/// island." Drawn rather than played from a file: sharp on every screen, a few
/// kilobytes instead of megabytes, and it shows this app's own words.
///
/// One clock drives everything (`t`, in seconds), so the choreography is the
/// same on every phone and stops when it ends -- nothing loops.
struct HomeIntroView: View {
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false

    /// Total length; the button appears at the end.
    static let length: Double = 9.2

    var body: some View {
        ZStack {
            // 🔴 Drawn ONCE, outside the clock. Netro, 19 Oct 2026: "the video
            // looks lagging". The 90pt blur behind the phone was being blurred
            // again on every frame -- the single most expensive thing on the
            // screen, and it never changes.
            IntroBackdrop()
            TimelineView(.animation(minimumInterval: nil, paused: finished)) { context in
                let t = reduceMotion ? Self.length : min(context.date.timeIntervalSince(start), Self.length)
                stage(t)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(Self.length + 0.1))
            finished = true
        }
        .statusBarHidden()
    }

    // MARK: - The stage

    private func stage(_ t: Double) -> some View {
        let camera = Camera(t)
        return ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                IntroPhone(t: t)
                    // Room for the drop shadow and side buttons: a drawing
                    // group cuts off whatever falls outside its own frame.
                    .padding(.horizontal, 40)
                    .padding(.top, 30)
                    .padding(.bottom, 64)
                    // Rendered by Metal into one image, THEN scaled and turned
                    // in 3D: the frame, glass, island and screen are drawn once
                    // a frame as a single texture instead of each layer being
                    // transformed and composited on its own.
                    .drawingGroup(opaque: false, colorMode: .extendedLinear)
                    .scaleEffect(camera.scale)
                    .offset(y: camera.lift)
                    .rotation3DEffect(.degrees(camera.tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
                    .rotation3DEffect(.degrees(camera.tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                    .opacity(camera.opacity)
                Spacer(minLength: 0)
                caption(t)
                    .padding(.bottom, 18)
                Button {
                    onDone()
                } label: {
                    Text("Get started")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .controlSize(.large)
                .padding(.horizontal, 28)
                .opacity(fade(t, 8.4, 9.0))
                .offset(y: 20 * (1 - fade(t, 8.4, 9.0)))
                .allowsHitTesting(t > 8.4)
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if t < 8.4 {
                Button("Skip") { onDone() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
        }
    }

    /// What each part of the piece is about, under the phone.
    ///
    /// While the camera is up at the Dynamic Island the phone fills the screen
    /// and covers this place, so the caption steps aside and the island says
    /// it ("Posted to TikTok") -- the first cut had "It posts itself" sitting on
    /// the phone's screen (seen in the 19 Oct recording).
    private func caption(_ t: Double) -> some View {
        let lines: [(String, String, Double, Double)] = [
            ("Ask for a video", "Say what you want, in your words.", 0.6, 3.1),
            ("Autocast makes it", "On the best video models.", 3.1, 5.0),
            ("It posts itself", "And tells you how it's doing.", 5.0, 8.4),
            ("Your content, on autopilot", "Plans, videos, captions and posting.", 8.4, 99),
        ]
        let zoomedIn = ease(t, 5.4, 5.8) * (1 - ease(t, 7.9, 8.3))
        return ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let shown = fade(t, line.2, line.2 + 0.35) * (1 - fade(t, line.3 - 0.25, line.3))
                VStack(spacing: 6) {
                    Text(line.0)
                        .font(.system(size: 26, weight: .heavy))
                    Text(line.1)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .opacity(shown)
                .offset(y: 10 * (1 - shown))
            }
        }
        .frame(height: 70)
        .opacity(1 - zoomedIn)
    }
}

/// The still part of the stage: the night gradient and the glow behind the
/// phone. Its own view, outside the clock, so it is drawn once and kept.
private struct IntroBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.05, blue: 0.14), Color(red: 0.14, green: 0.10, blue: 0.32), .black],
                startPoint: .top, endPoint: .bottom
            )
            Circle()
                .fill(Theme.accent.opacity(0.35))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(y: -40)
        }
        .drawingGroup()
        .ignoresSafeArea()
    }
}

// MARK: - The camera

/// Where the camera is at time `t`: rises in at an angle, pushes into the chat,
/// eases back for the video, flies up to the Dynamic Island, then pulls out.
private struct Camera {
    let scale: Double
    let lift: Double
    let tiltX: Double
    let tiltY: Double
    let opacity: Double

    init(_ t: Double) {
        let rise = ease(t, 0, 1.1)
        let push = ease(t, 1.1, 2.4)
        let ease1 = ease(t, 3.0, 3.8)
        let toIsland = ease(t, 5.6, 6.4)
        let out = ease(t, 7.9, 8.9)

        var scale = 0.72 + 0.18 * rise          // 0.72 -> 0.90
        scale += 0.16 * push                    // -> 1.06, into the chat
        scale -= 0.10 * ease1                   // -> 0.96, room for the video
        scale += 0.52 * toIsland                // -> 1.48, up to the island
        scale = scale - (scale - 0.84) * out    // -> 0.84, the closing frame
        self.scale = scale

        var lift = 160 * (1 - rise)
        lift += 150 * toIsland                  // the island comes to the centre
        lift -= 150 * out
        self.lift = lift

        self.tiltX = 24 * (1 - rise) + 4 * ease1 * (1 - toIsland)
        self.tiltY = -28 * (1 - rise) + 10 * ease1 * (1 - toIsland) - 6 * out * (1 - out)
        self.opacity = fade(t, 0, 0.5)
    }
}

/// 0 before `a`, 1 after `b`, a smooth S between.
private func ease(_ t: Double, _ a: Double, _ b: Double) -> Double {
    let x = min(max((t - a) / (b - a), 0), 1)
    return x * x * (3 - 2 * x)
}

private func fade(_ t: Double, _ a: Double, _ b: Double) -> Double { ease(t, a, b) }

// MARK: - The phone

/// An iPhone: titanium frame, black bezel, glass screen, Dynamic Island.
private struct IntroPhone: View {
    let t: Double

    private let width: CGFloat = 250
    private let height: CGFloat = 520
    private let corner: CGFloat = 46

    var body: some View {
        ZStack(alignment: .top) {
            // Frame: a brushed edge with a highlight along one side.
            RoundedRectangle(cornerRadius: corner + 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: 0.78), Color(white: 0.42), Color(white: 0.7), Color(white: 0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: width + 12, height: height + 12)
                .shadow(color: .black.opacity(0.55), radius: 30, y: 24)

            // Bezel and screen.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.black)
                .frame(width: width, height: height)
                .padding(6)
                .overlay(alignment: .top) {
                    IntroScreen(t: t)
                        .frame(width: width - 14, height: height - 14)
                        .clipShape(RoundedRectangle(cornerRadius: corner - 6, style: .continuous))
                        .padding(.top, 13)
                }
                .overlay(alignment: .top) {
                    DynamicIsland(t: t)
                        .padding(.top, 22)
                }
                // Glass: a soft sheen across the top.
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.14), .clear, .clear], startPoint: .topLeading, endPoint: .center))
                        .frame(width: width, height: height)
                        .allowsHitTesting(false)
                }

            // Side buttons.
            Capsule().fill(Color(white: 0.5)).frame(width: 3, height: 56)
                .offset(x: width / 2 + 7, y: 150)
            Capsule().fill(Color(white: 0.5)).frame(width: 3, height: 34)
                .offset(x: -(width / 2 + 7), y: 120)
            Capsule().fill(Color(white: 0.5)).frame(width: 3, height: 34)
                .offset(x: -(width / 2 + 7), y: 166)
        }
        .frame(width: width + 12, height: height + 12)
    }
}

/// The island: a pill that wakes into a live activity when the post goes out,
/// then tucks back in.
private struct DynamicIsland: View {
    let t: Double

    var body: some View {
        let open = ease(t, 6.0, 6.45) * (1 - ease(t, 7.7, 8.1))
        let width = 86 + (196 - 86) * open
        let height = 26 + (54 - 26) * open
        ZStack {
            Capsule(style: .continuous)
                .fill(.black)
                .frame(width: width, height: height)
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.green).frame(width: 26, height: 26)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(0.5 + 0.5 * ease(t, 6.3, 6.6))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Posted to TikTok")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Coffee shop · just now")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: width, height: height)
            .opacity(ease(t, 6.25, 6.55) * (1 - ease(t, 7.55, 7.8)))
        }
    }
}

// MARK: - What is on the screen

private struct IntroScreen: View {
    let t: Double

    var body: some View {
        ZStack {
            Color(red: 0.97, green: 0.97, blue: 0.99)
            chat
                .opacity(1 - ease(t, 3.0, 3.4))
            making
                .opacity(ease(t, 3.0, 3.4) * (1 - ease(t, 5.4, 5.8)))
            posted
                .opacity(ease(t, 5.4, 5.8))
        }
    }

    /// Someone asks; the answer arrives.
    private var chat: some View {
        let ask = "Make a 10s video about my coffee shop"
        let typed = Int(Double(ask.count) * ease(t, 1.0, 2.2))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Autocast")
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
            Spacer()
            HStack {
                Spacer(minLength: 40)
                Text(String(ask.prefix(typed)))
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(typed > 0 ? 1 : 0)
            }
            HStack {
                Text("On it. Making your video now ✨")
                    .font(.system(size: 12))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                Spacer(minLength: 40)
            }
            .opacity(ease(t, 2.4, 2.7))
            .offset(y: 8 * (1 - ease(t, 2.4, 2.7)))
            Capsule()
                .fill(Color.white)
                .frame(height: 34)
                .overlay(alignment: .leading) {
                    Text("Message").font(.system(size: 11)).foregroundStyle(.gray).padding(.leading, 14)
                }
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 12)
    }

    /// The video being made: a card filling with colour as the ring closes.
    private var making: some View {
        let progress = ease(t, 3.4, 5.1)
        return VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.orange, Color.brown, Color(red: 0.25, green: 0.15, blue: 0.1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 150, height: 250)
                    .saturation(progress)
                    .overlay {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.9))
                            .opacity(progress)
                    }
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 54, height: 54)
                    .opacity(1 - ease(t, 4.9, 5.2))
            }
            Text(progress < 1 ? "Making your video…" : "Ready")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75))
        }
    }

    /// Posted: the video playing, and its views counting up.
    private var posted: some View {
        let views = Int(12_400 * ease(t, 6.6, 8.0))
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color.orange, Color.brown, Color(red: 0.2, green: 0.12, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1 + 0.06 * ease(t, 5.6, 8.0))
            VStack(alignment: .leading, spacing: 4) {
                Text("@coffeeshop")
                    .font(.system(size: 12, weight: .bold))
                Text("Fresh beans, every morning ☕️")
                    .font(.system(size: 11))
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text(views.formatted(.number.notation(.compactName)))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .padding(.top, 2)
            }
            .foregroundStyle(.white)
            .padding(14)
            .padding(.bottom, 10)
        }
    }
}
