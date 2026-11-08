import SwiftUI
import UIKit
import AVFoundation

/// The pieces the first run is drawn with, taken one for one from the
/// onboarding mockup (https://claude.ai/artifact/7QujxtntQAHCRsoMyE7mEN): its
/// colours, its timing curves, its buttons and its glass. Abel, 8 Nov 2026:
/// "clone 100% of the look from the onboarding mockup ... every single thing
/// should look like the mockup".
///
/// The mockup draws a 390 x 844 pt iPhone screen. `MockupCanvas` lays every
/// screen out in those same points and scales it to the phone, so a number
/// here is the number in the mockup's CSS.

// MARK: - Colours

/// The mockup's colour tokens (`.phone` and `.phone.dark`), light and dark.
enum OB {
    /// --cv, --sf: the page and a card on it.
    static let canvas = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    /// --tx2, --tx3, --fill, --sheen.
    static let text2 = Color(.secondaryLabel)
    static let text3 = Color(.tertiaryLabel)
    static let fill = Color(.tertiarySystemFill)
    static let sheen = Color(.systemGray5)
    static let accent = Theme.accent
    static let accentSoft = dyn(0x5C4DE6, 0.12, 0x8070F5, 0.18)
    static let accentGlow = dyn(0x5C4DE6, 0.20, 0x8070F5, 0.30)
    static let glass = dyn(0xFFFFFF, 0.74, 0x2C2C30, 0.72)
    static let glassLine = dyn(0x000000, 0.07, 0xFFFFFF, 0.10)
    /// Bevel's dark pill, and its asleep colour.
    static let pill = dyn(0x1C1C1E, 1, 0xFFFFFF, 1)
    static let pillText = dyn(0xFFFFFF, 1, 0x000000, 1)
    static let pillOff = dyn(0xC7C7CC, 1, 0x3A3A3C, 1)
    static let pillOffText = dyn(0xFFFFFF, 1, 0xEBEBF5, 0.35)
    /// The account page's rising purple.
    static let glow1 = dyn(0x7B6CF0, 0.55, 0x4838BE, 0.55)
    static let glow2 = dyn(0x5C4DE6, 1, 0x3A2DB0, 1)
    static let glow3 = dyn(0x3E2FD0, 1, 0x1B1268, 1)
    /// The soft haze behind the calm pages.
    static let haze1 = dyn(0x5C4DE6, 0.16, 0x8070F5, 0.26)
    static let haze2 = dyn(0xAAB4CD, 0.45, 0x50506E, 0.30)
    static let separator = dyn(0x3C3C43, 0.18, 0x545458, 0.6)
    /// The privacy vault's metal.
    static let vault1 = dyn(0xFFFFFF, 1, 0x3C3C42, 1)
    static let vault2 = dyn(0xE2E1EB, 1, 0x1D1D21, 1)
    static let vault3 = dyn(0xFFFFFF, 0.95, 0xFFFFFF, 0.08)
    /// A notification banner.
    static let banner = dyn(0xF6F6F8, 0.8, 0x28282B, 0.78)
    static let bannerLine = dyn(0x000000, 0.05, 0xFFFFFF, 0.08)
    /// The brand purple, the same in both appearances (#5C4DE6).
    static let purple = hex(0x5C4DE6)
    static let green = dyn(0x1E8E5A, 1, 0x4CD07A, 1)

    static func dyn(_ light: UInt32, _ lightAlpha: CGFloat, _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static func hex(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(uiColor: rgb(hex, CGFloat(alpha)))
    }

    /// The mockup's one easing for anything that moves between places: CSS
    /// cubic-bezier(.2,.85,.25,1). It settles without overshooting, so
    /// nothing bounces (Abel, 8 Nov 2026).
    static func settle(_ duration: Double) -> Animation {
        .timingCurve(0.2, 0.85, 0.25, 1, duration: duration)
    }
}

// MARK: - Time

/// The mockup's timing helpers, so its timelines port number for number.
/// Times are in milliseconds, as in the mockup.
enum Tw {
    static func c01(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { c01((t - a) / (b - a)) }
    static func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
    static func inOutC(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func inOutQ(_ x: Double) -> Double { x < 0.5 ? 16 * pow(x, 5) : 1 - pow(-2 * x + 2, 5) / 2 }
    static func outC(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func inC(_ x: Double) -> Double { x * x * x }
    static func outBack(_ x: Double) -> Double {
        let c1 = 1.5
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
    static func spring(_ p: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        return 1 - exp(-6 * p) * cos(9.5 * p)
    }
    /// Fades in from `a` over `fin`, and out from `b` over `fout`.
    static func fade(_ t: Double, _ a: Double, _ fin: Double, _ b: Double? = nil, _ fout: Double = 1) -> Double {
        let shown = seg(t, a, a + fin)
        guard let b else { return shown }
        return shown * (1 - seg(t, b, b + fout))
    }
    /// 2,481 · 38.2K · 1.2M, as the mockup counts.
    static func count(_ value: Double) -> String {
        let n = value.rounded()
        if n < 10_000 { return Int(n).formatted(.number.locale(Locale(identifier: "en_US"))) }
        if n < 1_000_000 { return String(format: n < 100_000 ? "%.1fK" : "%.0fK", n / 1000) }
        return String(format: "%.1fM", n / 1_000_000)
    }
    /// 9s · 2m 14s.
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(String(format: "%02d", s % 60))s"
    }
}

/// Milliseconds since this view appeared, every frame. Paused under Reduce
/// Motion, where `still` is shown instead.
struct ObClock<Content: View>: View {
    let still: Double?
    let content: (Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    init(still: Double? = nil, @ViewBuilder content: @escaping (Double) -> Content) {
        self.still = still
        self.content = content
    }

    var body: some View {
        let paused = reduceMotion && still != nil
        TimelineView(.animation(paused: paused)) { context in
            if paused, let still {
                content(still)
            } else {
                content(context.date.timeIntervalSince(start) * 1000)
            }
        }
    }
}

// MARK: - The mockup's screen

/// Lays a screen out in the mockup's own 390 x 844 points and scales it to fit
/// the phone, top aligned under the real status bar. On every iPhone with Face
/// ID the shape is the same as the mockup's, so it fills the screen; an older,
/// shorter phone gets it a little smaller, centred.
struct MockupCanvas<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width / 390, geo.size.height / 844)
            content
                .frame(width: 390, height: 844, alignment: .topLeading)
                .scaleEffect(k, anchor: .topLeading)
                .frame(width: 390 * k, height: 844 * k, alignment: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Puts a view where the mockup's CSS does: `left` and `top`, with a width
    /// (from `left` and `right`) and a height when it has them.
    func at(_ x: CGFloat, _ y: CGFloat, w: CGFloat? = nil, h: CGFloat? = nil, align: Alignment = .topLeading) -> some View {
        frame(width: w, height: h, alignment: align)
            .offset(x: x, y: y)
    }
}

/// CSS `radial-gradient(RX RY at CX CY, color, transparent STOP)`: an
/// elliptical glow, drawn in its parent's points.
struct CSSGlow: View {
    let color: Color
    let rx: CGFloat
    let ry: CGFloat
    let cx: CGFloat
    let cy: CGFloat
    var stop: CGFloat = 1

    var body: some View {
        RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: rx * stop)
            .frame(width: rx * 2, height: rx * 2)
            .scaleEffect(x: 1, y: ry / rx)
            .position(x: cx, y: cy)
            .allowsHitTesting(false)
    }
}

/// `.qbg`: the calm pages' haze, purple top right and grey bottom left.
struct QuestionHaze: View {
    var body: some View {
        ZStack {
            CSSGlow(color: OB.haze1, rx: 331.5, ry: 354.5, cx: 343.2, cy: 67.5, stop: 0.72)
            CSSGlow(color: OB.haze2, rx: 331.5, ry: 379.8, cx: 31.2, cy: 810.2, stop: 0.72)
        }
        .frame(width: 390, height: 844)
        .opacity(0.8)
        .allowsHitTesting(false)
    }
}

/// `.tour .haze`: the same two glows, a little wider, behind the tour.
struct TourHaze: View {
    var body: some View {
        ZStack {
            CSSGlow(color: OB.haze1, rx: 351, ry: 464.2, cx: 343.2, cy: 118.2, stop: 0.7)
            CSSGlow(color: OB.haze2, rx: 351, ry: 422, cx: 19.5, cy: 742.7, stop: 0.7)
        }
        .frame(width: 390, height: 844)
        .allowsHitTesting(false)
    }
}

// MARK: - The P

/// Postpilot's mark in the icon's own 1024 units: the P, and the paper plane
/// inside it (the mockup's `P` and `PL` paths).
enum PostpilotMark {
    static var p: Path {
        var path = Path()
        path.move(to: CGPoint(x: 256, y: 430))
        path.addArc(center: CGPoint(x: 482, y: 430), radius: 226,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: 543, y: 204))
        path.addArc(center: CGPoint(x: 543, y: 429.5), radius: 225.5,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: 420, y: 655))
        path.addLine(to: CGPoint(x: 420, y: 756))
        path.addArc(center: CGPoint(x: 338, y: 756), radius: 82,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }

    static var plane: Path {
        var path = Path()
        path.move(to: CGPoint(x: 398, y: 390))
        path.addLine(to: CGPoint(x: 618, y: 358))
        path.addQuadCurve(to: CGPoint(x: 626, y: 374), control: CGPoint(x: 632, y: 357))
        path.addLine(to: CGPoint(x: 490, y: 547))
        path.addQuadCurve(to: CGPoint(x: 472, y: 543), control: CGPoint(x: 478, y: 557))
        path.addLine(to: CGPoint(x: 475, y: 452))
        path.addLine(to: CGPoint(x: 398, y: 410))
        path.addQuadCurve(to: CGPoint(x: 398, y: 390), control: CGPoint(x: 386, y: 400))
        path.closeSubpath()
        return path
    }
}

/// One part of the mark, fitted into a square.
struct MarkShape: Shape {
    var plane = false

    func path(in rect: CGRect) -> Path {
        let unit = (plane ? PostpilotMark.plane : PostpilotMark.p)
        return unit
            .applying(CGAffineTransform(scaleX: rect.width / 1024, y: rect.height / 1024))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The mark on a tile: purple with a white P (the app icon), or white with a
/// purple P (the account page's).
struct MarkTile: View {
    let size: CGFloat
    var inverted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(inverted ? Color.white : OB.purple)
            ZStack {
                MarkShape().fill(inverted ? OB.purple : Color.white)
                MarkShape(plane: true).fill(inverted ? Color.white : OB.purple)
            }
            .frame(width: size * 0.68, height: size * 0.68)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Buttons

/// Shrinks to 0.95 while held, as the mockup's `.press`.
struct ObPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// `.btn`: the purple pill, 52 high.
struct ObPurpleButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 350, height: 52)
                .background(OB.accent, in: Capsule())
        }
        .buttonStyle(ObPressStyle())
    }
}

/// `.bv-btn`: Bevel's pill, asleep (grey) until it is ready, then dark, with a
/// small pop as it wakes.
struct BevelPill: View {
    let title: String
    var on: Bool
    var busy = false
    var width: CGFloat? = 350
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().tint(OB.pillText)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                }
            }
            .foregroundStyle(on ? OB.pillText : OB.pillOffText)
            .frame(width: width, height: 54)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(on ? OB.pill : OB.pillOff, in: Capsule())
            .animation(.easeOut(duration: 0.3), value: on)
        }
        .buttonStyle(ObPressStyle())
    }
}

/// `.bv-skip`: the quiet grey pill.
struct BevelSkip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 350, height: 54)
                .background(OB.fill, in: Capsule())
        }
        .buttonStyle(ObPressStyle())
    }
}

// MARK: - Glass, logos, banners

extension View {
    /// `.gl`: soft glass on the haze.
    func obGlass(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(OB.glass)
            }
            .shadow(color: Color(red: 30 / 255, green: 20 / 255, blue: 90 / 255).opacity(0.06), radius: 12, y: 8)
        }
        .overlay(shape.strokeBorder(OB.glassLine, lineWidth: 0.5))
    }
}

/// The networks' marks (`.lg.tt`, `.lg.ig`, `.lg.yt`), by the mockup's short ids.
struct PlatformMark: View {
    let id: String
    let size: CGFloat

    var body: some View {
        Group {
            switch id {
            case "tt", "tiktok": BrandLogo.tiktok.view
            case "ig", "reels", "instagram": BrandLogo.instagram.view
            default: BrandLogo.youtube.view
            }
        }
        .frame(width: size, height: size)
    }
}

/// `.ios-n`: a real iOS notification banner.
struct IOSBanner: View {
    let title: String
    let line: String
    /// Nil for Postpilot's own icon, or a network's short id.
    var platform: String?
    var width: CGFloat = 302

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let platform {
                    PlatformMark(id: platform, size: 38)
                } else {
                    Image("app-mark").resizable().scaledToFit()
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("now").font(.system(size: 13)).foregroundStyle(OB.text2)
                }
                Text(line)
                    .font(.system(size: 15))
                    .tracking(-0.18)
                    .lineSpacing(0.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 11, bottom: 12, trailing: 15))
        .frame(width: width, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(OB.banner)
            }
            .shadow(color: .black.opacity(0.2), radius: 16, y: 12)
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(OB.bannerLine, lineWidth: 0.5))
    }
}

/// `.shim`: grey words with a brighter band passing through them, the way the
/// chat's progress line works.
struct ObShimmer: View {
    let text: String
    let t: Double
    var done = false
    var size: CGFloat = 15

    var body: some View {
        let base = Text(text).font(.system(size: size))
        if done {
            base.foregroundStyle(OB.text2)
        } else {
            let p = 1.3 - 1.6 * (t.truncatingRemainder(dividingBy: 1800) / 1800)
            base.foregroundStyle(OB.text2)
                .overlay {
                    base.foregroundStyle(Color.primary)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: min(max(1 - p - 0.12, 0), 1)),
                                    .init(color: .black, location: min(max(1 - p, 0), 1)),
                                    .init(color: .clear, location: min(max(1 - p + 0.12, 0), 1)),
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                        }
                }
        }
    }
}

// MARK: - Media

/// Test clips and stills shipped inside the app for onboarding (Abel, 8 Nov
/// 2026: "just to see how good it's looking, not for production").
enum OnboardingMedia {
    static func video(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp4")
    }

    static func image(_ name: String) -> UIImage? {
        Bundle.main.path(forResource: name, ofType: "jpg").flatMap(UIImage.init(contentsOfFile:))
    }
}

/// A bundled still, filling its box. Empty (never white) if it is missing.
struct MediaStill: View {
    let name: String

    var body: some View {
        if let image = OnboardingMedia.image(name) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.clear
        }
    }
}

/// A bundled clip on its own first frame: the still shows at once and the clip
/// fades in over it once it is playing, so there is never a black or white
/// frame. A new `restart` value plays it again from the start.
struct OnboardingClip: View {
    let name: String
    var restart = 0
    var loops = true

    @State private var playing = false

    var body: some View {
        ZStack {
            MediaStill(name: name)
            if let url = OnboardingMedia.video(name) {
                ClipPlayer(url: url, restart: restart, loops: loops) { playing = true }
                    .opacity(playing ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: playing)
            }
        }
        .clipped()
    }
}

/// AVPlayer, muted, filling its box. Tells once it is really showing frames.
private struct ClipPlayer: UIViewRepresentable {
    let url: URL
    let restart: Int
    let loops: Bool
    let started: () -> Void

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = loops ? .none : .pause
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(player, loops: loops, started: started)
        context.coordinator.restart = restart
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        guard context.coordinator.restart != restart, let player = uiView.playerLayer.player else { return }
        context.coordinator.restart = restart
        player.seek(to: .zero)
        player.play()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        uiView.playerLayer.player?.pause()
        coordinator.detach()
    }

    final class Coordinator {
        var restart = 0
        private var end: NSObjectProtocol?
        private var ready: NSKeyValueObservation?

        func attach(_ player: AVPlayer, loops: Bool, started: @escaping () -> Void) {
            if loops {
                end = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
                ) { [weak player] _ in
                    player?.seek(to: .zero)
                    player?.play()
                }
            }
            ready = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
                if player.timeControlStatus == .playing {
                    DispatchQueue.main.async { started() }
                }
            }
        }

        func detach() {
            if let end { NotificationCenter.default.removeObserver(end) }
            end = nil
            ready = nil
        }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
