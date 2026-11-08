import SwiftUI

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

/// Eases 0 to 1 between two moments.
func ramp(_ t: Double, _ from: Double, _ to: Double) -> Double {
    let x = min(max((t - from) / (to - from), 0), 1)
    return x * x * (3 - 2 * x)
}

/// An iOS notification banner: glass, the app's icon, a title, "now", a line.
struct PingBanner: View {
    let title: String
    let line: String

    var body: some View {
        HStack(spacing: 10) {
            Image("app-mark")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 4)
                    Text("now").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(line).font(.system(size: 14)).lineLimit(2)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .light)
    }
}

/// The first screen: an 18 second ad for what Postpilot does, at a calm pace
/// (the reference is @marqo.motion): one idea at a time, long holds, soft
/// light, words that blur in. The story is "A pig that went to war": typed as
/// an idea, made, and posted, with the views climbing. Every value is a
/// function of the clock, so it loops and can never get out of step.
struct OnboardingPromo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let length = 18.0
    private static let idea = "A pig that went to war"

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 12.5 : context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.length)
            ZStack {
                backdrop(t)
                video(t)
                iconBeat(t)
                ideaBeat(t)
                listBeat(t)
                bigWords(t)
                logoBeat(t)
            }
        }
        .clipped()
    }

    // MARK: Beats

    /// A deep purple night with a slow band of light.
    private func backdrop(_ t: Double) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.05, blue: 0.20), Color(red: 0.19, green: 0.14, blue: 0.55)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.45), .clear],
                center: UnitPoint(x: 0.5 + 0.25 * sin(t * 0.5), y: 0.95),
                startRadius: 0, endRadius: 280
            )
        }
    }

    /// 0 - 2.8: the app's icon, arriving.
    private func iconBeat(_ t: Double) -> some View {
        let shown = ramp(t, 0.1, 0.9) * (1 - ramp(t, 2.3, 2.8))
        return Image("app-mark")
            .resizable()
            .scaledToFit()
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .shadow(color: Color(red: 0.55, green: 0.45, blue: 1).opacity(0.6), radius: 28)
            .scaleEffect(0.9 + 0.1 * ramp(t, 0.1, 1.6) + 0.06 * ramp(t, 1.9, 2.8))
            .opacity(shown)
    }

    /// 2.8 - 6.2: "Got an idea?", then the idea typed into the bar.
    private func ideaBeat(_ t: Double) -> some View {
        let words = ["Got", "an", "idea?"]
        let typed = Int(Double(Self.idea.count) * ramp(t, 4.95, 5.95))
        let shown = ramp(t, 2.8, 3.0) * (1 - ramp(t, 6.0, 6.3))
        return ZStack {
            HStack(spacing: 8) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    let r = ramp(t, 3.0 + 0.16 * Double(index), 3.7 + 0.16 * Double(index))
                    Text(word)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                        .blur(radius: CGFloat((1 - r) * 10))
                        .opacity(r)
                        .offset(x: CGFloat((1 - r) * 14))
                }
            }
            .opacity(1 - ramp(t, 4.3, 4.7))

            VStack {
                Spacer()
                HStack {
                    Text(String(Self.idea.prefix(typed)))
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color(red: 0.36, green: 0.30, blue: 0.9), in: Circle())
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(.white.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                .padding(.horizontal, 18)
                .padding(.bottom, 26)
                .offset(y: CGFloat((1 - ramp(t, 4.45, 5.0)) * 60))
                .opacity(ramp(t, 4.45, 5.0))
            }
        }
        .opacity(shown)
    }

    /// 6.0 - 9.2: a light page, "Postpilot makes the rest", the steps picked out one by one.
    private func listBeat(_ t: Double) -> some View {
        let steps = ["Script.", "Voice.", "Scenes.", "Captions."]
        let shown = ramp(t, 6.0, 6.4) * (1 - ramp(t, 8.9, 9.2))
        return ZStack {
            Color(red: 0.96, green: 0.96, blue: 0.99)
            VStack(alignment: .leading, spacing: 8) {
                Text("Postpilot makes the rest.")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.bottom, 10)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    let on = ramp(t, 6.4 + 0.7 * Double(index), 6.4 + 0.7 * Double(index) + 0.65)
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(red: 0.36, green: 0.30, blue: 0.9))
                            .opacity(on)
                        Text(step)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(on > 0.5 ? Color.black : Color.black.opacity(0.22))
                        Color(red: 0.36, green: 0.30, blue: 0.9)
                            .frame(width: CGFloat(on) * 48, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(shown)
    }

    /// 9.0 - 16.4: the finished video, posted, with the views climbing and two pings.
    private func video(_ t: Double) -> some View {
        let shown = ramp(t, 9.0, 9.9) * (1 - ramp(t, 16.2, 16.6))
        let counts = ["2,481", "38.2K", "214K", "1.2M", "2.9M"]
        let index = min(counts.count - 1, max(0, Int((t - 11.9) / 0.7)))
        return ZStack {
            if let url = OnboardingMedia.video("viral") {
                SampleLoopVideo(url: url)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading) {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                    Text(t < 11.9 ? "0" : counts[index])
                        .contentTransition(.numericText())
                    Text("likes").foregroundStyle(.white.opacity(0.8))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(ramp(t, 11.6, 12.0))

            VStack(spacing: 8) {
                PingBanner(title: "Postpilot", line: "Posted to TikTok, Instagram and YouTube.")
                    .offset(y: CGFloat(-(1 - ramp(t, 11.95, 12.6)) * 140))
                    .opacity(ramp(t, 11.95, 12.3) * (1 - ramp(t, 13.2, 13.6)))
                PingBanner(title: "Postpilot", line: "Your video passed 1M views.")
                    .offset(y: CGFloat(-(1 - ramp(t, 13.15, 13.8)) * 140) - 70)
                    .opacity(ramp(t, 13.15, 13.5) * (1 - ramp(t, 14.7, 15.0)))
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .frame(maxHeight: .infinity, alignment: .top)

            Color.black.opacity(0.55 * ramp(t, 14.8, 15.2))
        }
        .opacity(shown)
    }

    /// 14.8 - 16.4: "Made." then "Posted."
    private func bigWords(_ t: Double) -> some View {
        func word(_ text: String, _ from: Double, _ to: Double) -> some View {
            let r = ramp(t, from, from + 0.4) * (1 - ramp(t, to - 0.15, to))
            return Text(text)
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(.white)
                .blur(radius: CGFloat((1 - ramp(t, from, from + 0.4)) * 12))
                .opacity(r)
        }
        return ZStack {
            word("Made.", 15.0, 15.7)
            word("Posted.", 15.75, 16.4)
        }
    }

    /// 16.4 - 18: the mark and the name, then back to the start.
    private func logoBeat(_ t: Double) -> some View {
        let sharp = ramp(t, 16.5, 17.1)
        return ZStack {
            Color(red: 0.36, green: 0.30, blue: 0.9)
            VStack(spacing: 10) {
                Image("launch-logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .blur(radius: CGFloat((1 - sharp) * 14))
                Text("Postpilot")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(ramp(t, 17.0, 17.5))
            }
        }
        .opacity(ramp(t, 16.4, 16.9) * (1 - ramp(t, 17.7, 18.0)))
    }
}
