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

/// Apple Health's "Private and Secure" page, in our colours (Abel, 10 Nov
/// 2026, picked from Mobbin): one glossy icon, a bold title, a few plain
/// lines and the pill. Nothing counts down, so Continue works at once. Only
/// claims that are true: the videos and photos ARE stored on our server, so
/// that is never said.
struct OnboardingPrivacyView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private static let lines = [
        "To protect your privacy, your data is encrypted in transit and at rest.",
        "Your videos and photos belong to you, and we never sell or share your information.",
        "You can delete your account and everything in it, any time.",
    ]

    var body: some View {
        MockupCanvas {
            ZStack(alignment: .topLeading) {
                QuestionHaze()

                PrivacyIcon()
                    .at(140, 112, w: 110, h: 124)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.88)
                    .opacity(shown || reduceMotion ? 1 : 0)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Your Data is Private\nand Secure")
                        .font(.system(size: 26, weight: .bold))
                        .tracking(-0.39)
                        .foregroundStyle(Color(.label))
                        .padding(.bottom, 2)

                    ForEach(Self.lines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 17))
                            .lineSpacing(3)
                            .foregroundStyle(OB.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button { openURL(AutocastLinks.privacy) } label: {
                        Label("Learn more…", systemImage: "info.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(OB.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .opacity(shown || reduceMotion ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 8)
                .at(28, 268, w: 334)

                BevelPill(title: "Continue", on: true) {
                    session.onboardingNext(from: .privacy)
                }
                .at(20, 748)
            }
            .frame(width: 390, height: 844, alignment: .topLeading)
        }
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.6)) { shown = true }
        }
    }
}

/// The glossy icon: a purple shield with a white lock, lit from the top.
private struct PrivacyIcon: View {
    var body: some View {
        ZStack {
            PrivacyShield()
                .fill(LinearGradient(colors: [OB.hex(0x9A8BFF), OB.hex(0x5C4DE6)], startPoint: .top, endPoint: .bottom))
                .shadow(color: OB.hex(0x2B2470, 0.28), radius: 14, y: 10)
            PrivacyShield()
                .fill(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0)], startPoint: .top, endPoint: .center))
            Image(systemName: "lock.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: OB.hex(0x2B2470, 0.3), radius: 3, y: 2)
                .offset(y: -4)
        }
        .frame(width: 110, height: 124)
    }
}

/// A rounded shield, flat on top the way Apple's heart is full.
private struct PrivacyShield: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addCurve(to: CGPoint(x: w * 0.96, y: h * 0.16), control1: CGPoint(x: w * 0.66, y: h * 0.1), control2: CGPoint(x: w * 0.8, y: h * 0.15))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h), control1: CGPoint(x: w * 1.0, y: h * 0.62), control2: CGPoint(x: w * 0.78, y: h * 0.88))
        p.addCurve(to: CGPoint(x: w * 0.04, y: h * 0.16), control1: CGPoint(x: w * 0.22, y: h * 0.88), control2: CGPoint(x: 0, y: h * 0.62))
        p.addCurve(to: CGPoint(x: w * 0.5, y: 0), control1: CGPoint(x: w * 0.2, y: h * 0.15), control2: CGPoint(x: w * 0.34, y: h * 0.1))
        p.closeSubpath()
        return p
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
