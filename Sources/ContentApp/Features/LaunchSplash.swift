import SwiftUI

/// The splash. iOS shows its own launch screen first (purple, the white P,
/// `UILaunchScreen` in project.yml) and this view draws the very same logo in
/// the very same place, so the two read as one. Then the logo moves while the
/// app finishes loading, and when it is ready the P opens into the app.
///
/// iOS can only show a still image before any code runs, and a video needs a
/// moment to load, so a video splash would show a black frame first. This is a
/// SwiftUI animation, which starts on the first frame (Abel, 7 Nov 2026).
///
/// It never adds a wait: the move takes under a second and plays while the
/// session loads. If the session is ready first, the move still finishes; if
/// it is slower, the P holds still until it is ready.
struct LaunchSplash: View {
    /// True once the session has left `.starting`.
    let ready: Bool
    let finished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The logo's box, in points. The artwork is drawn inside it exactly as the
    /// launch image is (a 768-unit window of the 1024 icon).
    private static let box: CGFloat = 128

    @State private var dip: CGFloat = 1
    @State private var planeOut: CGFloat = 0
    @State private var sweep: CGFloat = -1
    @State private var introDone = false
    @State private var open: CGFloat = 0
    @State private var fade: CGFloat = 1
    @State private var started = false

    var body: some View {
        ZStack {
            ground
            logo
        }
        .ignoresSafeArea()
        .task { await intro() }
        .onChange(of: ready) { _, _ in openIfReady() }
        .onChange(of: introDone) { _, _ in openIfReady() }
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    /// Purple, with the P cut out of it once it opens, so the app shows through.
    @ViewBuilder
    private var ground: some View {
        if open > 0 {
            Color("LaunchPurple")
                .mask {
                    ZStack {
                        Rectangle()
                        Image("launch-p")
                            .resizable()
                            .frame(width: Self.box, height: Self.box)
                            .scaleEffect(scale)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
        } else {
            Color("LaunchPurple")
        }
    }

    private var scale: CGFloat { 1 + 29 * open * open * open }

    private var logo: some View {
        ZStack {
            Image("launch-p")
                .resizable()
                .overlay { sweepLight.mask { Image("launch-p").resizable() } }
            PlaneShape()
                .fill(Color("LaunchPurple"))
                .overlay { PlaneShape().stroke(Color("LaunchPurple"), style: StrokeStyle(lineWidth: 2, lineJoin: .round)) }
                .rotationEffect(.degrees(-8 * Double(planeOut)), anchor: UnitPoint(x: 0.6, y: 0.55))
                .offset(x: 20 * planeOut, y: -20 * planeOut)
        }
        .frame(width: Self.box, height: Self.box)
        .scaleEffect(dip * (open > 0 ? scale : 1))
        .opacity(fade)
    }

    /// A soft light crossing the P, left to right.
    private var sweepLight: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, Color("LaunchPurple").opacity(0.3), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.5)
            .offset(x: sweep * proxy.size.width * 1.2 - proxy.size.width * 0.1)
            .opacity(sweep < 0 || sweep > 1 ? 0 : 1)
        }
    }

    // MARK: Timing

    /// The move, about 0.85 s: the P dips and springs back, the light crosses
    /// it, and the plane shoots up and right and settles.
    private func intro() async {
        guard !started else { return }
        started = true
        if reduceMotion {
            introDone = true
            return
        }
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(.easeInOut(duration: 0.18)) { dip = 0.85 }
        try? await Task.sleep(for: .milliseconds(140))
        withAnimation(.easeOut(duration: 0.15)) { planeOut = 1 }
        try? await Task.sleep(for: .milliseconds(40))
        withAnimation(.spring(duration: 0.55, bounce: 0.4)) { dip = 1 }
        withAnimation(.easeInOut(duration: 0.46)) { sweep = 1.2 }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.spring(duration: 0.55, bounce: 0.5)) { planeOut = 0 }
        try? await Task.sleep(for: .milliseconds(480))
        introDone = true
    }

    private func openIfReady() {
        guard ready, introDone, open == 0 else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { fade = 0 }
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                finished()
            }
            return
        }
        // The P stays white for a moment, then gives way to the app.
        withAnimation(.easeIn(duration: 0.48)) { open = 1 }
        withAnimation(.easeIn(duration: 0.2).delay(0.1)) { fade = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            finished()
        }
    }
}

/// The paper plane in the P, in the logo box's own coordinates (the icon's 1024
/// units, cropped to the 768-unit window the launch image uses).
private struct PlaneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 768
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 128) * unit, y: rect.minY + (y - 137) * unit)
        }
        var path = Path()
        path.move(to: point(394, 398))
        path.addLine(to: point(624, 364))
        path.addLine(to: point(482, 548))
        path.addLine(to: point(474, 452))
        path.closeSubpath()
        return path
    }
}
