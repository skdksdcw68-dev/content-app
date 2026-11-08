import SwiftUI

/// The splash: the mockup's variant A, "Flight" (Abel, 8 Nov 2026: "flight
/// pick"; https://claude.ai/artifact/WQmUHUEuJTe9UxcWZDe5TA).
///
/// iOS shows its own launch screen first (purple, the white P, `UILaunchScreen`
/// in project.yml), and the first frame here is exactly that picture. Then the
/// plane pulls back, flies a loop round the P and docks (1.5 s); while the app
/// is still loading the P breathes, never restarting; once it is ready the
/// plane shoots off and the P opens into the app.
///
/// Drawn on a Canvas from the mockup's own numbers (`splashkit.js`), so it is
/// the same motion, frame for frame. The same view covers signing out.
struct LaunchSplash: View {
    /// True once the session is ready.
    let ready: Bool
    let finished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    /// When the P starts to open, in ms from the start.
    @State private var openAt: Double?
    @State private var done = false

    var body: some View {
        TimelineView(.animation(paused: done)) { context in
            let t = context.date.timeIntervalSince(start) * 1000
            Canvas { canvas, size in
                SplashFrame(t: t, openAt: openAt, still: reduceMotion).draw(in: &canvas, size: size)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!done)
        .onAppear { openIfReady() }
        .onChange(of: ready) { _, _ in openIfReady() }
        .accessibilityHidden(true)
    }

    /// Opens once it is ready and the move has finished; never sooner, and
    /// never adds a wait of its own.
    private func openIfReady() {
        guard ready, openAt == nil else { return }
        let now = Date().timeIntervalSince(start) * 1000
        let at = reduceMotion ? now : max(now, SplashFrame.intro)
        openAt = at
        let end = at + (reduceMotion ? 220 : SplashFrame.holeAt + SplashFrame.hole)
        Task {
            try? await Task.sleep(for: .milliseconds(Int(end - now) + 20))
            done = true
            finished()
        }
    }
}

/// One frame of the splash at time `t` (ms).
struct SplashFrame {
    let t: Double
    let openAt: Double?
    let still: Bool

    static let intro = 1500.0
    static let holeAt = 90.0
    static let hole = 480.0

    /// The plane's middle, and the way it points, in icon units.
    private static let hx = 494.0
    private static let hy = 440.0
    private static let heading = atan2(364.0 - 440.0, 624.0 - 494.0)
    private static let fx = cos(heading)
    private static let fy = sin(heading)
    /// The plane's loop round the P, as offsets from home, in icon units.
    private static let loop: [(Double, Double)] = [
        (0, 0), (170, -200), (300, -430), (60, -600), (-270, -480),
        (-480, -130), (-470, 280), (-250, 520), (-130, 240),
    ]

    // MARK: Drawing

    func draw(in canvas: inout GraphicsContext, size: CGSize) {
        let m = motion()
        let cx = size.width / 2
        let cy = size.height / 2
        let unit = 128.0 / 768.0
        let qx = cx + (338 - 512) * unit
        let qy = cy + (640 - 521) * unit

        // The P, from icon units to the screen.
        let g = CGAffineTransform(translationX: -512, y: -521)
            .concatenating(CGAffineTransform(scaleX: unit * m.beat, y: unit * m.beat))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
            .concatenating(CGAffineTransform(translationX: -qx, y: -qy))
            .concatenating(CGAffineTransform(scaleX: m.k, y: m.k))
            .concatenating(CGAffineTransform(translationX: qx, y: qy))
        let p = PostpilotMark.p.applying(g)

        var layer = canvas
        layer.opacity = m.opacity

        // Purple, with the P cut out of it once it opens.
        var ground = Path(CGRect(origin: .zero, size: size).insetBy(dx: -60, dy: -60))
        if m.holeOn { ground.addPath(p) }
        layer.fill(ground, with: .color(OB.purple), style: FillStyle(eoFill: true))

        // A soft light behind the P as the plane docks.
        if m.halo > 0.001 {
            var halo = layer
            halo.opacity = m.opacity * m.halo
            let circle = Path(ellipseIn: CGRect(x: cx - 150, y: cy - 150, width: 300, height: 300))
            let light = Gradient(stops: [
                .init(color: .white.opacity(0.55), location: 0),
                .init(color: .white.opacity(0.16), location: 0.55),
                .init(color: .white.opacity(0), location: 1),
            ])
            halo.fill(circle, with: .radialGradient(light, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: 150))
        }

        // The white P.
        var letter = layer
        letter.opacity = m.opacity * m.fill
        letter.fill(p, with: .color(.white))

        // Inside the P: the light crossing it, and the plane in purple.
        let planeMove = CGAffineTransform(translationX: -Self.hx, y: -Self.hy)
            .concatenating(CGAffineTransform(scaleX: m.planeScale, y: m.planeScale))
            .concatenating(CGAffineTransform(rotationAngle: m.rot * .pi / 180))
            .concatenating(CGAffineTransform(translationX: Self.hx + m.dx, y: Self.hy + m.dy))
        let plane = PostpilotMark.plane.applying(planeMove.concatenating(g))

        var inside = layer
        inside.clip(to: p)
        inside.opacity = m.opacity * m.fill
        if m.gloss > 0, m.gloss < 1 {
            let shift = Tw.lerp(150, 900, m.gloss)
            let band = CGAffineTransform(translationX: shift, y: 0)
                .concatenating(CGAffineTransform(translationX: -512, y: -521))
                .concatenating(CGAffineTransform(rotationAngle: 25 * .pi / 180))
                .concatenating(CGAffineTransform(translationX: 512, y: 521))
                .concatenating(g)
            let rect = Path(CGRect(x: -110, y: -400, width: 220, height: 1800)).applying(band)
            let sheen = Gradient(stops: [
                .init(color: OB.purple.opacity(0), location: 0),
                .init(color: OB.purple.opacity(0.3), location: 0.5),
                .init(color: OB.purple.opacity(0), location: 1),
            ])
            inside.fill(rect, with: .linearGradient(sheen,
                                                    startPoint: CGPoint(x: -110, y: 0).applying(band),
                                                    endPoint: CGPoint(x: 110, y: 0).applying(band)))
        }
        inside.fill(plane, with: .color(OB.purple))

        // Outside the P: the trail and the plane in white.
        var outside = layer
        outside.clip(to: p, options: .inverse)
        if let trail = m.trail {
            let width = unit * m.beat * m.k
            for index in 0..<13 {
                guard let a = trail[index], let b = trail[index + 1] else { continue }
                var line = Path()
                line.move(to: CGPoint(x: Self.hx + a.x, y: Self.hy + a.y))
                line.addLine(to: CGPoint(x: Self.hx + b.x, y: Self.hy + b.y))
                var stroke = outside
                stroke.opacity = m.opacity * (0.08 + 0.8 * Double(index) / 12)
                let lineWidth = (5 + 22 * Double(index) / 12) * width
                stroke.stroke(line.applying(g), with: .color(.white),
                              style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        outside.fill(plane, with: .color(.white))
    }

    // MARK: Motion

    private struct Motion {
        var beat = 1.0
        var dx = 0.0
        var dy = 0.0
        var rot = 0.0
        var planeScale = 1.0
        var halo = 0.0
        var gloss = -1.0
        var fill = 1.0
        var k = 1.0
        var holeOn = false
        var opacity = 1.0
        var trail: [CGPoint?]?
    }

    private func motion() -> Motion {
        var m = Motion()
        if still {
            if let openAt { m.opacity = 1 - Tw.seg(t, openAt, openAt + 200) }
            return m
        }
        if t < Self.intro {
            introMove(&m)
        } else {
            let ti = t - Self.intro
            let b = bump(ti, 1800)
            m.dx = 8 * b * Self.fx
            m.dy = 8 * b * Self.fy
            m.rot = 1.6 * wave(ti, 1800)
            m.beat = 1 + 0.012 * wave(ti, 2600)
            m.halo = 0.12 * bump(ti, 2600)
        }
        m.gloss = t >= 1200 && t <= 1560 ? Tw.seg(t, 1200, 1560) : -1

        guard let openAt, t >= openAt else { return m }
        // The plane shoots off, leaving a trail.
        let lq = Tw.seg(t, openAt, openAt + 420)
        let travel = 2400 * Tw.inC(lq)
        let length = min(travel, 520)
        m.dx += travel * Self.fx
        m.dy += travel * Self.fy
        m.planeScale *= 1 + 0.3 * lq
        if lq > 0, lq < 1 {
            m.trail = (0..<14).map { j in
                let back = length * Double(13 - j) / 13
                return CGPoint(x: m.dx - back * Self.fx, y: m.dy - back * Self.fy)
            }
        } else {
            m.trail = nil
        }
        // The P opens from its stem into the app.
        let hs = openAt + Self.holeAt
        let hq = Tw.seg(t, hs, hs + Self.hole)
        m.holeOn = t >= hs
        m.k = 1 + 29 * Tw.inC(hq)
        m.fill = 1 - Tw.seg(t, hs, hs + 90)
        if m.holeOn { m.halo *= m.fill }
        return m
    }

    /// The first 1.5 s: pull back, the loop round the P, dock.
    private func introMove(_ m: inout Motion) {
        let an = Tw.inOut(Tw.seg(t, 150, 380))
        var back = -36 * an
        m.beat = 1 - 0.06 * an
        let fp = Tw.seg(t, 380, 1180)
        if fp > 0 {
            let u = Tw.inOut(fp)
            let pt = Self.path(u)
            back *= 1 - Tw.c01(fp / 0.15)
            m.dx = pt.x + back * Self.fx
            m.dy = pt.y + back * Self.fy
            var w = min(Tw.c01(fp / 0.1), Tw.c01((1 - fp) / 0.14))
            w = w * w * (3 - 2 * w)
            m.rot = angleDiff(atan2(pt.vy, pt.vx) - Self.heading) * w * 180 / .pi
            m.planeScale = 1 + 0.16 * sin(.pi * fp)
            m.beat = 0.94 + 0.06 * softSpring(Tw.seg(t, 380, 980))
            if fp < 1 {
                m.trail = (0..<14).map { j in
                    let uu = u - Double(13 - j) * 0.012
                    guard uu >= 0 else { return nil }
                    let q = Self.path(uu)
                    return CGPoint(x: q.x, y: q.y)
                }
            }
        } else {
            m.dx = back * Self.fx
            m.dy = back * Self.fy
        }
        if t >= 1180 {
            let d1 = 16 * sin(.pi * Tw.seg(t, 1180, 1330))
            let d2 = 5 * sin(.pi * Tw.seg(t, 1330, 1500))
            let d = d1 - d2
            m.dx += d * Self.fx
            m.dy += d * Self.fy
            m.beat *= 1 - 0.03 * sin(.pi * Tw.seg(t, 1180, 1360))
        }
        m.halo = 0.3 * sin(.pi * Tw.seg(t, 1180, 1500))
    }

    /// A point on the loop (Catmull-Rom through `loop`), and which way it is heading.
    private static func path(_ position: Double) -> (x: Double, y: Double, vx: Double, vy: Double) {
        let n = loop.count
        let u = Tw.c01(position)
        let f = u * Double(n)
        let i = min(n - 1, Int(f.rounded(.down)))
        let s = f - Double(i)
        let a = loop[(i - 1 + n) % n]
        let b = loop[i]
        let c = loop[(i + 1) % n]
        let d = loop[(i + 2) % n]
        return (catmull(a.0, b.0, c.0, d.0, s), catmull(a.1, b.1, c.1, d.1, s),
                slope(a.0, b.0, c.0, d.0, s), slope(a.1, b.1, c.1, d.1, s))
    }

    private static func catmull(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ s: Double) -> Double {
        let k1: Double = -a + c
        let k2: Double = 2 * a - 5 * b + 4 * c - d
        let k3: Double = -a + 3 * b - 3 * c + d
        return 0.5 * (2 * b + k1 * s + k2 * s * s + k3 * s * s * s)
    }

    private static func slope(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ s: Double) -> Double {
        let k1: Double = -a + c
        let k2: Double = 2 * a - 5 * b + 4 * c - d
        let k3: Double = -a + 3 * b - 3 * c + d
        return 0.5 * (k1 + 2 * k2 * s + 3 * k3 * s * s)
    }

    private func softSpring(_ p: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        return 1 - exp(-5.5 * p) * cos(9 * p)
    }

    private func wave(_ t: Double, _ period: Double) -> Double { sin(2 * .pi * t / period) }
    private func bump(_ t: Double, _ period: Double) -> Double { (1 - cos(2 * .pi * t / period)) / 2 }

    private func angleDiff(_ angle: Double) -> Double {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
