import SwiftUI

/// The first screen: a 9 s ad for Postpilot made of the app's own screens,
/// playing inside a real-looking iPhone (Abel, 8 Nov 2026: "there was a white
/// one with a white editor ... on a real-looking frame"; the first welcome of
/// the mockup, https://claude.ai/artifact/JkiQE6ST4dKV7bymndZppP). An idea is
/// typed, the script is written, the voice recorded, every scene edited on a
/// timeline, and the finished video -- the pig reel -- is posted and climbs.
struct OnboardingWelcome: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        MockupCanvas {
            ZStack(alignment: .topLeading) {
                CSSGlow(color: OB.accentGlow, rx: 258.5, ry: 294.4, cx: 195, cy: 301.6, stop: 0.72)
                    .frame(width: 390, height: 844)

                ObClock(still: 6900) { time in
                    ZStack(alignment: .topLeading) {
                        WelcomeDevice(time: time).at(69, 64)
                        AdNotes(t: time.truncatingRemainder(dividingBy: AdStory.length)).at(46, 88)
                    }
                    .frame(width: 390, height: 844, alignment: .topLeading)
                }

                Text("Viral videos, made and posted for you")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.3)
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .at(24, 616, w: 342, align: .top)

                ObPurpleButton(title: "Get Started") { session.onboardingNext() }
                    .at(20, 724)

                Button { session.goToEmail(.login) } label: {
                    Text("Already have an account? **Sign In**")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .at(0, 792, w: 390, align: .top)
            }
        }
    }
}

// MARK: - The story

/// What the ad shows: the pig reel, from the idea to the posted video.
enum AdStory {
    static let length = 9000.0
    static let idea = "A pig that went to war"
    static let title = "The pig that went to war"
    static let lines: [(String, String)] = [
        ("Hook", "A soldier strapped explosives to a pig."),
        ("Then", "It walked straight into the enemy base."),
        ("End", "Nobody expected what came next."),
    ]
    static let voice = "Storyteller"
    static let hook = "A soldier strapped explosives to a pig."
    static let captions = ["SOLDIER", "PIG", "READY", "WALKS", "BASE", "THEN"]
    static let handle = "@pigstories"
    static let caption = "The pig that went to war"
    static let likes = 2_900_000.0
    static let comments = 96_100.0
    static let shares = 212_000.0
    static let saves = 304_000.0
    static let notes: [(String, String, String)] = [
        ("tt", "TikTok", "Your video passed 1M views"),
        ("ig", "Instagram", "maya.k and 2,318 others liked your reel"),
        ("yt", "YouTube", "12.4K new subscribers this week"),
    ]
    /// Where each scene flies in from: x, y, turn.
    static let flyFrom: [(Double, Double, Double)] = [
        (-90, -170, -16), (30, -230, 12), (130, -140, -9), (-140, 130, 14), (50, 200, -11), (150, 80, 9),
    ]

    /// The mockup's `whip`: a page slides in from the right with a little
    /// motion blur, holds, and slides out to the left.
    struct Whip {
        var x = 0.0
        var blur = 0.0
        var opacity = 1.0
    }

    static func whip(_ t: Double, _ a: Double, _ b: Double) -> Whip? {
        let w = 260.0
        if t < a || t > b + w { return nil }
        var out = Whip()
        if a > 0, t < a + w {
            let p = Tw.c01((t - a) / w)
            out.x = 390 * (1 - Tw.inOutQ(p))
            out.blur = 12 * sin(.pi * p)
        }
        if t > b {
            let q = Tw.c01((t - b) / w)
            out.x = -390 * Tw.inOutQ(q)
            out.blur = 12 * sin(.pi * q)
        }
        if a == 0 { out.opacity *= Tw.seg(t, 0, 220) }
        return out
    }
}

extension View {
    fileprivate func whip(_ w: AdStory.Whip) -> some View {
        offset(x: w.x)
            .blur(radius: w.blur > 0.4 ? w.blur : 0)
            .opacity(w.opacity)
    }
}

// MARK: - The phone

/// `.dev`: a 252 x 532 iPhone, dark bezel, Dynamic Island, side buttons,
/// tilting very slightly as it floats.
private struct WelcomeDevice: View {
    let time: Double

    var body: some View {
        let t = time.truncatingRemainder(dividingBy: AdStory.length)
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        ZStack(alignment: .topLeading) {
            side(x: -3, y: 110, h: 44)
            side(x: -3, y: 166, h: 44)
            side(x: 252, y: 150, h: 70)

            shape.fill(OB.hex(0x0B0B0E))
                .overlay(shape.strokeBorder(OB.hex(0x2E2E34), lineWidth: 1.5))
                .shadow(color: OB.hex(0x140E3C, 0.28), radius: 25, y: 26)
                .shadow(color: .black.opacity(0.12), radius: 7, y: 6)
                .frame(width: 252, height: 532)

            WelcomeAd(t: t)
                .frame(width: 390, height: 860, alignment: .topLeading)
                .scaleEffect(0.6103, anchor: .topLeading)
                .frame(width: 238, height: 518, alignment: .topLeading)
                .background(LinearGradient(colors: [OB.hex(0x2B2470), OB.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 37, style: .continuous))
                .offset(x: 7, y: 7)

            Capsule().fill(.black)
                .frame(width: 74, height: 21)
                .offset(x: 89, y: 13)
        }
        .frame(width: 252, height: 532, alignment: .topLeading)
        .rotation3DEffect(.degrees(1.4 * sin(time / 2100)), axis: (x: 1, y: 0, z: 0), perspective: 0.3)
        .rotation3DEffect(.degrees(3.2 * sin(time / 1450)), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
        .offset(y: 3 * sin(time / 1700))
    }

    private func side(x: CGFloat, y: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(OB.hex(0x1E1E22))
            .frame(width: 3, height: h)
            .offset(x: x, y: y)
    }
}

/// What plays on the phone's screen, drawn at 390 x 860 and scaled down.
private struct WelcomeAd: View {
    let t: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            OB.canvas
            if let w = AdStory.whip(t, 0, 1500) { AdChatPage(t: t).whip(w) }
            if let w = AdStory.whip(t, 1500, 2750) { AdScriptPage(t: t).whip(w) }
            if let w = AdStory.whip(t, 2750, 3800) { AdVoicePage(t: t).whip(w) }
            if t >= 3800, t < 5200 { AdEditPage(t: t) }
            if t >= 4950 { AdPostPage(t: t) }
            AdStatusBar(light: t >= 5150 && t < 8900)
        }
        .frame(width: 390, height: 860, alignment: .topLeading)
        .clipped()
    }
}

private struct AdStatusBar: View {
    let light: Bool

    var body: some View {
        HStack {
            Text("9:41").font(.system(size: 17, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(light ? Color.white : Color.primary)
        .padding(.leading, 52)
        .padding(.trailing, 40)
        .padding(.top, 8)
        .frame(width: 390, height: 58)
    }
}

// MARK: - 1. The idea is typed

private struct AdChatPage: View {
    let t: Double

    var body: some View {
        let zoom = Tw.lerp(1.2, 1, Tw.inOut(Tw.seg(t, 0, 1100)))
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Text("New chat")
                    .font(.system(size: 17, weight: .semibold))
                    .at(0, 58, w: 390, h: 44, align: .center)
                Text("A")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [OB.hex(0x7B6CF0), OB.hex(0xC08BF2)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    .at(338, 64)
                bubble
                AdComposer(text: typed, sent: t >= 1180, sending: t > 1060 && t < 1180)
                    .at(14, 770)
            }
            .frame(width: 390, height: 860, alignment: .topLeading)
            .scaleEffect(zoom, anchor: UnitPoint(x: 0.5, y: 810.0 / 860.0))

            KineticWords(words: ["Type", "an", "*idea."], t: t, start: 120)
                .at(26, 104, w: 338)
        }
    }

    private var typed: String {
        let count = Int(Double(AdStory.idea.count) * Tw.seg(t, 250, 1050))
        return String(AdStory.idea.prefix(count))
    }

    @ViewBuilder
    private var bubble: some View {
        if t >= 1180 {
            let p = Tw.spring(Tw.seg(t, 1180, 1560))
            HStack {
                Spacer(minLength: 0)
                Text(AdStory.idea)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: 280, alignment: .trailing)
            }
            .frame(width: 372)
            .opacity(Tw.c01((t - 1180) / 140))
            .scaleEffect(0.9 + 0.1 * p)
            .offset(y: (1 - p) * 170)
            .at(0, 560)
        }
    }
}

/// The chat bar as the app draws it: +, the words, the mic or the send arrow.
private struct AdComposer: View {
    let text: String
    let sent: Bool
    let sending: Bool

    var body: some View {
        let typing = !text.isEmpty && !sent
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(OB.fill, in: Circle())
            Group {
                if sent || text.isEmpty {
                    HStack(spacing: 1) {
                        if !sent { Cursor() }
                        Text("Ask Postpilot").foregroundStyle(OB.text3)
                    }
                } else {
                    HStack(spacing: 1) {
                        Text(text)
                        Cursor()
                    }
                }
            }
            .font(.system(size: 17))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if typing {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(OB.accent, in: Circle())
                    .scaleEffect(sending ? 0.84 : 1)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(OB.text2)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 362, height: 52)
        .background(OB.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(OB.glassLine, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 11, y: 8)
    }
}

/// `.cr`: the blinking text cursor.
private struct Cursor: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(OB.accent)
                .frame(width: 2, height: 20)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - 2. The script

private struct AdScriptPage: View {
    let t: Double

    var body: some View {
        let ready = t >= 2450
        ZStack(alignment: .topLeading) {
            KineticWords(words: ["It", "writes", "the", "*script."], t: t, start: 1640)
                .at(26, 104, w: 338)

            AdProgressLine(text: "Writing the script · \(1 + Int((t - 1500) / 180))s", t: t)
                .at(26, 262, w: 338)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    AdIcon(symbol: "list.clipboard")
                    Text(ready ? "Plan ready · 6 scenes" : "Writing the script")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(OB.accent)
                        .scaleEffect(ready ? Tw.outBack(Tw.seg(t, 2450, 2650)) : 0)
                }
                Text(AdStory.title)
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.375)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .opacity(Tw.seg(t, 1720, 1900))
                ForEach(0..<3, id: \.self) { index in
                    scriptLine(index)
                        .frame(minHeight: 23, alignment: .topLeading)
                        .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(width: 354, alignment: .topLeading)
            .background(OB.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 15, y: 10)
            .at(18, 302)
        }
        .frame(width: 390, height: 860, alignment: .topLeading)
        .background(OB.canvas)
    }

    private func scriptLine(_ index: Int) -> some View {
        let start = 1850 + Double(index) * 230
        let line = AdStory.lines[index]
        let count = Int(Double(line.1.count) * Tw.seg(t, start, start + 220))
        let typing = t >= start && count < line.1.count
        let key = Text(t >= start ? line.0 + "  " : "").bold().foregroundColor(OB.accent)
        let body = Text(String(line.1.prefix(count)))
        let cursor = Text(typing ? "▍" : "").foregroundColor(OB.accent)
        return (key + body + cursor)
            .font(.system(size: 17))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.a-pl`: the grey progress line with its shine, and a chevron.
private struct AdProgressLine: View {
    let text: String
    let t: Double

    var body: some View {
        HStack(spacing: 6) {
            ObShimmer(text: text, t: t, size: 17)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OB.text3)
            Spacer(minLength: 0)
        }
    }
}

/// `.a-ic`: a glyph on a soft purple tile.
private struct AdIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(OB.accent)
            .frame(width: 36, height: 36)
            .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 3. The voice

private struct AdVoicePage: View {
    let t: Double

    var body: some View {
        let p = Tw.seg(t, 2900, 3700)
        ZStack(alignment: .topLeading) {
            KineticWords(words: ["It", "records", "the", "*voice."], t: t, start: 2870)
                .at(26, 104, w: 338)

            AdProgressLine(text: "Recording the voiceover…", t: t)
                .at(26, 262, w: 338)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    AdIcon(symbol: "waveform")
                    Text(AdStory.voice)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("0:\(String(format: "%02d", Int(p * 30))) / 0:30")
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(OB.text2)
                }
                VoiceBars(t: t, progress: p)
                    .frame(height: 96)
                    .padding(.top, 22)
                    .padding(.bottom, 16)
                karaoke(p)
            }
            .padding(20)
            .frame(width: 354, alignment: .topLeading)
            .background(OB.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 15, y: 10)
            .at(18, 302)
        }
        .frame(width: 390, height: 860, alignment: .topLeading)
        .background(OB.canvas)
    }

    /// The hook, each word lighting up as it is spoken.
    private func karaoke(_ p: Double) -> some View {
        let words = AdStory.hook.split(separator: " ").map(String.init)
        let lit = Int(p * Double(words.count) + 0.0001)
        var text = Text("")
        for (index, word) in words.enumerated() {
            let piece = Text(index == 0 ? word : " " + word)
                .foregroundColor(index < lit ? Color.primary : OB.text3)
            text = text + piece
        }
        return text
            .font(.system(size: 24, weight: .bold))
            .tracking(-0.24)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.a-wave`: 44 bars, lit as far as the voice has got.
private struct VoiceBars: View {
    let t: Double
    let progress: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<44, id: \.self) { index in
                let b = Double(index)
                let base = 14 + abs(sin(b * 1.7) * 0.6 + sin(b * 0.43 + 1) * 0.4) * 70
                let on = b / 44 <= progress
                let live = 0.55 + 0.45 * abs(sin(t / 95 + b * 0.9))
                RoundedRectangle(cornerRadius: 3)
                    .fill(OB.accent)
                    .frame(height: on ? base * live : base * 0.45)
                    .opacity(on ? 1 : 0.25)
            }
        }
    }
}

// MARK: - 4. The edit

private struct AdEditPage: View {
    let t: Double

    var body: some View {
        let enter = Tw.seg(t, 3800, 4060)
        let x = t < 4060 ? 390 * (1 - Tw.inOutQ(enter)) : 0
        let blur = t < 4060 ? 12 * sin(.pi * enter) : 0
        let opacity = t >= 4950 ? 1 - Tw.seg(t, 4950, 5200) : 1
        ZStack(alignment: .topLeading) {
            KineticWords(words: ["It", "edits", "every", "*scene."], t: t, start: 3920)
                .at(26, 104, w: 338)

            AdProgressLine(text: "Putting the video together", t: t)
                .at(26, 262, w: 338)

            EditTimeline(t: t).at(0, 300, w: 390, h: 340)
        }
        .frame(width: 390, height: 860, alignment: .topLeading)
        .background(OB.canvas)
        .offset(x: x)
        .blur(radius: blur > 0.4 ? blur : 0)
        .opacity(opacity)
    }
}

/// The editor: six scenes flying into a row, captions landing on them, the
/// voice, caption and music lanes, and the playhead running across.
private struct EditTimeline: View {
    let t: Double

    var body: some View {
        let lanes = Tw.seg(t, 3950, 4150)
        ZStack(alignment: .topLeading) {
            voiceLane.opacity(lanes).at(12, 120, w: 366, h: 40)
            captionLane.at(12, 170, w: 366, h: 30)
            musicLane.opacity(lanes).at(12, 210, w: 366, h: 30)

            ForEach(0..<6, id: \.self) { index in
                scene(index).at(12 + 62 * CGFloat(index), 0)
            }

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(OB.accent).frame(width: 3, height: 256)
                Circle().fill(OB.accent).frame(width: 13, height: 13).offset(y: 2)
            }
            .frame(width: 13, height: 256, alignment: .top)
            .opacity(t >= 4280 ? 1 : 0)
            .at(7 + 363 * Tw.seg(t, 4300, 4950), -8)
        }
        .frame(width: 390, height: 340, alignment: .topLeading)
    }

    private func captionProgress(_ index: Int) -> Double {
        let start = 4250 + Double(index) * 90
        return Tw.seg(t, start, start + 200)
    }

    private func scene(_ index: Int) -> some View {
        let start = 3880 + Double(index) * 70
        let p = Tw.spring(Tw.seg(t, start, start + 560))
        let from = AdStory.flyFrom[index]
        let cp = captionProgress(index)
        return ZStack {
            MediaStill(name: "sc-\(index + 1)")
            StrokedWord(text: AdStory.captions[index], size: 11, stroke: 1.2)
                .scaleEffect(cp > 0 ? Tw.outBack(cp) : 0)
                .position(x: 28, y: 62)
        }
        .frame(width: 56, height: 100)
        .background(OB.fill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 6)
        .scaleEffect(0.55 + 0.45 * p)
        .rotationEffect(.degrees(from.2 * (1 - p)))
        .offset(x: from.0 * (1 - p), y: from.1 * (1 - p))
        .opacity(Tw.c01((t - start) / 120))
    }

    private var voiceLane: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<70, id: \.self) { index in
                let v = Double(index)
                RoundedRectangle(cornerRadius: 1)
                    .fill(OB.text2)
                    .frame(height: 6 + abs(sin(v * 1.3) * 0.7 + sin(v * 0.37) * 0.3) * 24)
                    .opacity(0.6)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: 366, height: 40)
        .background(OB.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var captionLane: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<6, id: \.self) { index in
                Text(AdStory.captions[index])
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(OB.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 56, height: 30)
                    .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(captionProgress(index))
                    .offset(x: 62 * CGFloat(index))
            }
        }
        .frame(width: 366, height: 30, alignment: .topLeading)
    }

    private var musicLane: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
            WavyLine().stroke(OB.accent, lineWidth: 2.5).frame(height: 18)
            Text("Music")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(OB.accent)
        .padding(.horizontal, 10)
        .frame(width: 366, height: 30)
        .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// The music lane's gentle wave.
private struct WavyLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let step = rect.width / 20
        path.move(to: CGPoint(x: rect.minX, y: mid))
        for i in 0..<20 {
            let x0 = rect.minX + CGFloat(i) * step
            let up: CGFloat = i % 2 == 0 ? -1 : 1
            path.addQuadCurve(to: CGPoint(x: x0 + step, y: mid),
                              control: CGPoint(x: x0 + step / 2, y: mid + up * rect.height * 0.45))
        }
        return path
    }
}

/// White heavy capitals with a black outline, as the videos' captions are.
struct StrokedWord: View {
    let text: String
    let size: CGFloat
    var stroke: CGFloat = 1.5
    var color: Color = .white

    var body: some View {
        let word = Text(text).font(.system(size: size, weight: .black))
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) * .pi / 4
                word.foregroundStyle(.black)
                    .offset(x: cos(angle) * stroke, y: sin(angle) * stroke)
            }
            word.foregroundStyle(color)
        }
        .fixedSize()
    }
}

// MARK: - 5. Posted

/// The finished reel zooms up out of the timeline to fill the phone, is
/// posted to three places, and the counts climb while hearts float up.
private struct AdPostPage: View {
    let t: Double

    var body: some View {
        let zp = Tw.spring(Tw.seg(t, 4950, 5420))
        let s = Tw.lerp(56.0 / 390.0, 1, zp)
        let cx = Tw.lerp(164, 195, zp)
        let cy = Tw.lerp(350, 430, zp)
        let ending = Tw.seg(t, 8750, 9000)
        let settled = t >= 8750
        ZStack(alignment: .topLeading) {
            Color(white: 0.07)
            OnboardingClip(name: "viral")
                .frame(width: 390, height: 860)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .clear, location: 0.38),
                .init(color: .clear, location: 0.80),
                .init(color: .black.opacity(0.3), location: 1),
            ], startPoint: .bottom, endPoint: .top)

            PostedChip(t: t).at(0, 186, w: 390, align: .top)
            PostRail(t: t).at(306, 0, w: 72, h: 710, align: .bottom)
            PostMeta().at(18, 0, w: 282, h: 804, align: .bottomLeading)
            FloatingHearts(t: t).at(332, 410)
        }
        .frame(width: 390, height: 860, alignment: .topLeading)
        .mask {
            RoundedRectangle(cornerRadius: max(0.01, 58 * (1 - zp)), style: .continuous)
                .padding(.vertical, 82 * (1 - zp))
        }
        .scaleEffect(settled ? 1 - 0.06 * ending : s, anchor: .topLeading)
        .offset(x: settled ? 0 : cx - 195 * s, y: settled ? 0 : cy - 430 * s)
        .blur(radius: settled && ending > 0.04 ? 8 * ending : 0)
        .opacity(1 - ending)
    }
}

/// "Posting to 3 apps…", the three marks ticking green one by one.
private struct PostedChip: View {
    let t: Double

    var body: some View {
        let p = Tw.spring(Tw.seg(t, 5300, 5700))
        HStack(spacing: 8) {
            ForEach(Array(["tt", "ig", "yt"].enumerated()), id: \.offset) { index, id in
                let ok = t >= 5500 + Double(index) * 200
                PlatformMark(id: id, size: 28)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255), in: Circle())
                            .overlay(Circle().stroke(Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.9), lineWidth: 2))
                            .offset(x: 5, y: 5)
                            .scaleEffect(ok ? 1 : 0)
                            .animation(.timingCurve(0.2, 0.9, 0.3, 1.5, duration: 0.3), value: ok)
                    }
            }
            Text(t < 6000 ? "Posting to 3 apps…" : "Posted to TikTok, Instagram, YouTube")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 16))
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
        .background(Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.62), in: Capsule())
        .environment(\.colorScheme, .dark)
        .opacity(Tw.c01((t - 5300) / 150))
        .offset(y: (1 - p) * -70)
    }
}

/// TikTok's right-hand rail: the creator, likes, comments, shares, saves.
private struct PostRail: View {
    let t: Double

    var body: some View {
        let climb = 1 - pow(1 - Tw.seg(t, 5250, 8750), 2.4)
        let liked = t >= 5350
        VStack(spacing: 20) {
            Circle()
                .fill(LinearGradient(colors: [OB.hex(0x7B6CF0), OB.hex(0xC08BF2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .overlay(alignment: .bottom) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(OB.hex(0xFE2C55), in: Circle())
                        .offset(y: 10)
                }
                .padding(.bottom, 6)
            item("heart.fill", Tw.count(AdStory.likes * climb), tint: liked ? OB.hex(0xFE2C55) : .white,
                 pop: liked ? Tw.outBack(Tw.seg(t, 5350, 5600)) : 1)
            item("ellipsis.bubble.fill", Tw.count(AdStory.comments * climb))
            item("arrowshape.turn.up.right.fill", Tw.count(AdStory.shares * climb))
            item("bookmark.fill", Tw.count(AdStory.saves * climb))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }

    private func item(_ symbol: String, _ value: String, tint: Color = .white, pop: Double = 1) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(tint)
                .scaleEffect(pop)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
        }
    }
}

private struct PostMeta: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AdStory.handle).font(.system(size: 18, weight: .bold))
            Text(AdStory.caption).font(.system(size: 16))
            Text("♫ Original sound").font(.system(size: 14)).opacity(0.9)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

/// Nine hearts drifting up the right side.
private struct FloatingHearts: View {
    let t: Double

    var body: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { index in
                let h = Double(index)
                let age = t - (5400 + h * 360)
                if age >= 0, age <= 1500 {
                    let opacity = age < 200 ? age / 200 : 1 - (age - 200) / 1300
                    Image(systemName: "heart.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(OB.hex(0xFE2C55))
                        .scaleEffect(0.6 + 0.5 * min(1, age / 260))
                        .rotationEffect(.degrees(sin(h * 2.1) * 18))
                        .offset(x: sin(age / 170 + h) * 12, y: -190 * age / 1500)
                        .opacity(opacity)
                }
            }
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - The pings beside the phone

/// Three notifications popping out over the phone's edge as the video climbs.
private struct AdNotes: View {
    let t: Double
    private static let at: [Double] = [6150, 6950, 7750]

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(0..<3, id: \.self) { index in
                note(index)
            }
        }
        .frame(width: 298, height: 120, alignment: .top)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func note(_ index: Int) -> some View {
        let age = t - Self.at[index]
        if age >= 0 {
            let p = Tw.spring(Tw.c01(age / 500))
            let newer = Self.at.indices.filter { $0 > index && t >= Self.at[$0] }.count
            let out = Tw.seg(t, 8750, 8950)
            let y = (1 - p) * -50 + Double(newer) * 13 - 60 * out
            let scale = (0.9 + 0.1 * p) * (1 - 0.05 * Double(newer))
            let fade = newer >= 2 ? 0 : 1 - 0.3 * Double(newer)
            let opacity = Tw.c01(age / 160) * fade * (1 - out)
            let item = AdStory.notes[index]
            GlassNote(platform: item.0, title: item.1, line: item.2)
                .scaleEffect(scale, anchor: .top)
                .offset(y: y)
                .opacity(opacity)
                .zIndex(Double(10 + index))
        }
    }
}

/// `.nt`: a glass notification with a network's mark.
private struct GlassNote: View {
    let platform: String
    let title: String
    let line: String

    var body: some View {
        HStack(spacing: 11) {
            PlatformMark(id: platform, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(title).font(.system(size: 14.5, weight: .bold))
                    Spacer(minLength: 4)
                    Text("now").font(.system(size: 13)).foregroundStyle(OB.text2)
                }
                Text(line).font(.system(size: 14)).lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 298, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(OB.glass)
            }
            .shadow(color: .black.opacity(0.2), radius: 17, y: 14)
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(OB.glassLine, lineWidth: 0.5))
    }
}

// MARK: - Words that rise into place

/// `.kt`: big words, each rising out of its own slot, one after another, the
/// last one in purple (marked with a leading `*`).
struct KineticWords: View {
    let words: [String]
    let t: Double
    let start: Double
    var size: CGFloat = 38

    var body: some View {
        WordFlow(spacing: size * 0.26, lineHeight: size * 1.04) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, raw in
                let accent = raw.hasPrefix("*")
                let word = accent ? String(raw.dropFirst()) : raw
                let p = Tw.c01((t - start - Double(index) * 55) / 420)
                Text(word)
                    .font(.system(size: size, weight: .heavy))
                    .tracking(-size * 0.03)
                    .foregroundStyle(accent ? OB.accent : Color.primary)
                    .fixedSize()
                    .offset(y: (1 - Tw.outBack(p)) * 1.18 * size * 1.2)
                    .padding(.bottom, size * 0.1)
                    .clipped()
                    .padding(.bottom, -size * 0.1)
            }
        }
    }
}

/// Lays words out left to right, wrapping onto new lines.
struct WordFlow: Layout {
    let spacing: CGFloat
    let lineHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 338
        let rows = arrange(subviews, width: width)
        return CGSize(width: width, height: CGFloat(rows.count) * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (line, row) in rows.enumerated() {
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + CGFloat(line) * lineHeight),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let w = subviews[index].sizeThatFits(.unspecified).width
            if x > 0, x + w > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(index)
            x += w + spacing
        }
        return rows
    }
}
