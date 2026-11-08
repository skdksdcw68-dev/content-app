import SwiftUI

/// The calm steps of first run, drawn as the mockup draws them
/// (https://claude.ai/artifact/7QujxtntQAHCRsoMyE7mEN): what is true about
/// their data, and the ask for pings with a reason. No name is asked before
/// sign-up: App Review rejects it (5.1.1(v)), and Apple hands the name over.

extension View {
    /// A faint purple haze top right and grey bottom left, behind a page that
    /// is not drawn on the mockup's canvas.
    func softGlassBackground() -> some View {
        background {
            ZStack {
                RadialGradient(colors: [OB.haze1, .clear], center: UnitPoint(x: 0.88, y: 0.08), startRadius: 0, endRadius: 340)
                RadialGradient(colors: [OB.haze2, .clear], center: UnitPoint(x: 0.08, y: 0.96), startRadius: 0, endRadius: 340)
            }
            .opacity(0.8)
            .ignoresSafeArea()
        }
    }
}

// MARK: - Private by design

/// The vault locks while a ring fills for three seconds, three true promises
/// tick in one a second, and then Continue wakes. Only claims that are true:
/// the videos and photos ARE stored on our server, so that is never said.
struct OnboardingPrivacyView: View {
    @Environment(AppSession.self) private var session

    private static let promises: [(String, String)] = [
        ("Encrypted.", "Your data is encrypted, in transit and at rest."),
        ("Yours alone.", "Your videos and photos belong to you."),
        ("Delete any time.", "Delete your account and everything in it, any time."),
    ]

    var body: some View {
        MockupCanvas {
            ObClock(still: 5000) { t in
                ZStack(alignment: .topLeading) {
                    QuestionHaze()

                    PrivacyRing(progress: Tw.inOut(Tw.seg(t, 300, 3300)))
                        .at(45, 82, w: 300, h: 300)

                    Vault(t: t).at(85, 122, w: 220, h: 220)

                    Text("Private by design")
                        .font(.system(size: 26, weight: .bold))
                        .tracking(-0.39)
                        .at(28, 396, w: 334, align: .top)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(Self.promises.enumerated()), id: \.offset) { index, promise in
                            promiseRow(promise, start: 900 + Double(index) * 900, t: t)
                        }
                    }
                    .at(52, 446, w: 302)

                    Text("We never sell or share your information.")
                        .font(.system(size: 15, weight: .medium))
                        .multilineTextAlignment(.center)
                        .opacity(Tw.seg(t, 3450, 3850))
                        .at(36, 640, w: 318, align: .top)

                    BevelPill(title: "Continue", on: t >= 3350) {
                        guard t >= 3350 else { return }
                        session.onboardingNext(from: .privacy)
                    }
                    .at(20, 748)
                }
                .frame(width: 390, height: 844, alignment: .topLeading)
                .sensoryFeedback(.impact(weight: .light), trigger: t >= 3350)
            }
        }
    }

    private func promiseRow(_ promise: (String, String), start: Double, t: Double) -> some View {
        let q = Tw.seg(t, start, start + 450)
        let on = t >= start + 250
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(on ? OB.accent : Color.clear)
                Circle().strokeBorder(OB.text3, lineWidth: 1.5).opacity(on ? 0 : 1)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                    .opacity(on ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.4)
                    .animation(.timingCurve(0.2, 0.9, 0.3, 1.5, duration: 0.3), value: on)
            }
            .frame(width: 24, height: 24)
            .padding(.top, 1)
            .animation(.easeOut(duration: 0.25), value: on)

            VStack(alignment: .leading, spacing: 1) {
                Text(promise.0).font(.system(size: 17, weight: .semibold))
                Text(promise.1)
                    .font(.system(size: 13))
                    .foregroundStyle(OB.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(q)
        .offset(y: 10 * (1 - Tw.outC(q)))
    }
}

/// `.pring`: the 3 s ring round the vault.
private struct PrivacyRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().inset(by: 10).stroke(OB.fill, lineWidth: 5)
            Circle().inset(by: 10)
                .trim(from: 0, to: progress)
                .stroke(OB.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 300, height: 300)
    }
}

/// The soft metal vault: its door, hinges, the dial that turns as the ring
/// fills, and the little light that goes purple with a click when it locks.
private struct Vault: View {
    let t: Double

    var body: some View {
        let p = Tw.inOut(Tw.seg(t, 300, 3300))
        let locked = t >= 3350
        let click = sin(.pi * Tw.seg(t, 3350, 3600))
        let float = 4 * sin(t / 950)
        let glow = Tw.seg(t, 3350, 4100)
        let metal = LinearGradient(colors: [OB.vault1, OB.vault2], startPoint: .topLeading, endPoint: .bottomTrailing)
        let metalBack = LinearGradient(colors: [OB.vault2, OB.vault1], startPoint: .topLeading, endPoint: .bottomTrailing)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .fill(metal)
                .shadow(color: OB.hex(0x2B2470, 0.2), radius: 15, y: 16)
                .at(20, 20, w: 180, h: 180)
            RoundedRectangle(cornerRadius: 49, style: .continuous)
                .strokeBorder(OB.vault3, lineWidth: 1.5)
                .at(21, 21, w: 178, h: 178)
            Capsule().fill(metalBack).at(187, 64, w: 9, h: 26)
            Capsule().fill(metalBack).at(187, 130, w: 9, h: 26)
            Circle().fill(metalBack)
                .overlay(Circle().strokeBorder(OB.separator, lineWidth: 1))
                .at(46, 46, w: 128, h: 128)

            Dial(metal: metal, metalBack: metalBack)
                .rotationEffect(.degrees(-150 * (1 - p)))
                .at(0, 0, w: 220, h: 220)

            Circle()
                .stroke(OB.accent, lineWidth: 2)
                .frame(width: 2 * (6 + 16 * Tw.outC(glow)), height: 2 * (6 + 16 * Tw.outC(glow)))
                .opacity(locked && glow < 1 ? 0.8 * (1 - glow) : 0)
                .position(x: 164, y: 50)
            Circle()
                .fill(locked ? OB.accent : OB.text3)
                .frame(width: 10, height: 10)
                .position(x: 164, y: 50)
        }
        .frame(width: 220, height: 220, alignment: .topLeading)
        .scaleEffect(1 - 0.035 * click)
        .offset(y: float)
    }
}

/// The vault's dial: a plate, sixteen ticks, three spokes, the hub and its dot.
private struct Dial: View {
    let metal: LinearGradient
    let metalBack: LinearGradient

    var body: some View {
        ZStack {
            Circle().fill(metal)
                .frame(width: 98, height: 98)
                .shadow(color: .black.opacity(0.14), radius: 5, y: 5)
            Ticks()
                .stroke(OB.text3, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 220, height: 220)
            ForEach(0..<3, id: \.self) { index in
                Capsule().fill(metalBack)
                    .frame(width: 8, height: 40)
                    .offset(y: -20)
                    .rotationEffect(.degrees(Double(index) * 120))
            }
            Circle().fill(metal)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.14), radius: 5, y: 5)
            Circle().fill(OB.accent)
                .frame(width: 6.4, height: 6.4)
                .offset(y: -34)
        }
        .frame(width: 220, height: 220)
    }
}

/// Sixteen short ticks between radius 37 and 42 round the dial's centre.
private struct Ticks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        for i in 0..<16 {
            let a = Double(i) / 16 * 2 * .pi
            path.move(to: CGPoint(x: c.x + sin(a) * 37, y: c.y - cos(a) * 37))
            path.addLine(to: CGPoint(x: c.x + sin(a) * 42, y: c.y - cos(a) * 42))
        }
        return path
    }
}

// MARK: - Pings

/// Postpilot's pings land on a lock screen one by one and stack, like a real
/// iPhone. The system's own question only comes after "Turn on pings", so the
/// one real prompt is never wasted.
struct OnboardingPingsView: View {
    @Environment(AppSession.self) private var session
    @State private var asking = false

    var body: some View {
        MockupCanvas {
            ZStack(alignment: .topLeading) {
                QuestionHaze()

                ObClock(still: 4000) { t in
                    LockScreen(t: t)
                }
                .at(34, 112, w: 322, h: 410)

                Text("Get a ping when your video is ready")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.39)
                    .multilineTextAlignment(.center)
                    .at(28, 540, w: 334, align: .top)

                Text("And when it’s posted, and when it takes off. Nothing else.")
                    .font(.system(size: 15))
                    .foregroundStyle(OB.text2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .at(36, 608, w: 318, align: .top)

                BevelPill(title: "Turn on pings", on: true, busy: asking) {
                    guard !asking else { return }
                    asking = true
                    Task {
                        await session.askForPushOnce()
                        asking = false
                        session.onboardingNext(from: .pings)
                    }
                }
                .at(20, 690)

                Button { session.onboardingNext(from: .pings) } label: {
                    Text("Not now")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OB.text2)
                        .frame(width: 200, height: 30)
                }
                .buttonStyle(ObPressStyle())
                .at(95, 756)
            }
        }
    }
}

/// `.lk`: the lock screen, its wallpaper, the date and time, and the pings.
private struct LockScreen: View {
    let t: Double

    private static let pings = [
        "Your video is ready. Tap to watch “The pig that went to war”.",
        "Posted to TikTok, Instagram and YouTube.",
        "Your video hit 48K views.",
    ]
    private static let at: [Double] = [600, 1900, 3200]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [
                .init(color: OB.hex(0x1A1446), location: 0),
                .init(color: OB.hex(0x33288F), location: 0.42),
                .init(color: OB.hex(0x6E55CF), location: 0.72),
                .init(color: OB.hex(0xD9A1D6), location: 1),
            ], startPoint: UnitPoint(x: 0.37, y: 0), endPoint: UnitPoint(x: 0.63, y: 1))
            .blur(radius: 3)
            .padding(-14)

            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .at(0, 40, w: 322, align: .top)

            Text("9:41")
                .font(.system(size: 86, weight: .bold))
                .tracking(-3)
                .foregroundStyle(.white.opacity(0.96))
                .at(0, 54, w: 322, align: .top)

            ZStack(alignment: .top) {
                ForEach(0..<3, id: \.self) { index in
                    ping(index)
                }
            }
            .frame(width: 302, alignment: .top)
            .at(10, 188)

            lockButton("flashlight.off.fill").at(30, 332)
            lockButton("camera.fill").at(242, 332)

            Capsule().fill(.white).frame(width: 110, height: 5).at(106, 397)
        }
        .frame(width: 322, height: 410, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: OB.hex(0x1E145A, 0.25), radius: 25, y: 24)
    }

    /// One ping, sliding down into place and stepping back as newer ones land.
    @ViewBuilder
    private func ping(_ index: Int) -> some View {
        let age = t - Self.at[index]
        if age >= 0 {
            let p = Tw.spring(Tw.c01(age / 580))
            let depth = Self.at.indices
                .filter { $0 > index }
                .map { Tw.spring(Tw.seg(t, Self.at[$0], Self.at[$0] + 580)) }
                .reduce(0, +)
            let y = (1 - p) * -84 + depth * 12
            let scale = (0.95 + 0.05 * p) - depth * 0.05
            let opacity = Tw.c01(age / 150) * max(0, 1 - depth * 0.36)
            IOSBanner(title: "Postpilot", line: Self.pings[index], width: 302)
                .compositingGroup()
                .overlay {
                    // Stepped back, only the plate shows, as iOS stacks them.
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(OB.banner)
                        .opacity(depth > 0.5 ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: depth > 0.5)
                }
                .scaleEffect(scale, anchor: .top)
                .offset(y: y)
                .opacity(opacity)
                .zIndex(Double(10 + index))
        }
    }

    private func lockButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .background(.black.opacity(0.28), in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
    }
}
