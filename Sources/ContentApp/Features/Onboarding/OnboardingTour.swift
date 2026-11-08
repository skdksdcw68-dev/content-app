import SwiftUI

// MARK: - How it works

/// What the three pages say. Data, so the flow counts them instead of
/// hard-coding "three".
enum OnboardingTour {
    struct Page {
        let title: String
        let line: String
    }

    static let pages: [Page] = [
        Page(title: "Videos in any style", line: "3D stories, facts, scary stories, motivation and more. Swipe to watch a few."),
        Page(title: "It makes every video", line: "Script, voice, pictures and captions. Done in minutes."),
        Page(title: "Fresh videos, every day", line: "It picks what’s trending, makes the video and posts it for you."),
    ]
}

/// The mockup's pager: three pages side by side, dragged with the finger,
/// dots, and Continue. Dragging the style cards on the first page moves the
/// cards only, never the page (Abel, 8 Nov 2026: "unless they swipe out of the
/// video, please don't actually change the page").
struct OnboardingTourView: View {
    let page: Int

    @Environment(AppSession.self) private var session
    @State private var shownPage: Int?
    @State private var drag: CGFloat = 0

    var body: some View {
        let current = shownPage ?? page
        MockupCanvas {
            ZStack(alignment: .topLeading) {
                TourHaze()

                HStack(spacing: 0) {
                    ForEach(0..<OnboardingTour.pages.count, id: \.self) { index in
                        TourPage(index: index, active: index == current)
                    }
                }
                .frame(width: 390 * CGFloat(OnboardingTour.pages.count), height: 706, alignment: .leading)
                .offset(x: -390 * CGFloat(current) + drag)
                .frame(width: 390, height: 706, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(pagerDrag(current))

                HStack(spacing: 6) {
                    ForEach(0..<OnboardingTour.pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == current ? Color.primary : OB.text3)
                            .frame(width: index == current ? 18 : 6, height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: current)
                .at(0, 716, w: 390, align: .top)

                ObPurpleButton(title: "Continue") {
                    if current < OnboardingTour.pages.count - 1 {
                        show(current + 1)
                    } else {
                        session.onboardingNext(from: .tour(current))
                    }
                }
                .at(20, 748)
            }
        }
        .onChange(of: page) { _, new in
            guard new != shownPage else { return }
            withAnimation(OB.settle(0.44)) { shownPage = new }
        }
    }

    /// The mockup's pager drag: resists past the ends, turns the page past
    /// 70 pt or on a quick flick, and settles without a bounce.
    private func pagerDrag(_ current: Int) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width
                let atEnd = (current == 0 && dx > 0) || (current == OnboardingTour.pages.count - 1 && dx < 0)
                drag = atEnd ? dx * 0.35 : dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let speed = value.velocity.width / 1000
                var next = current
                if dx < -70 || speed < -0.45 { next += 1 } else if dx > 70 || speed > 0.45 { next -= 1 }
                next = max(0, min(OnboardingTour.pages.count - 1, next))
                show(next)
            }
    }

    private func show(_ next: Int) {
        withAnimation(OB.settle(0.44)) {
            drag = 0
            shownPage = next
        }
        if next != page { session.onboarding(goTo: .tour(next)) }
    }
}

/// One page: the title, the line under it, and its moving picture. Only the
/// page on show runs its clock, and it starts again each time it comes back.
private struct TourPage: View {
    let index: Int
    let active: Bool

    var body: some View {
        let content = OnboardingTour.pages[index]
        ZStack(alignment: .topLeading) {
            Text(content.title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.6)
                .at(20, 92, w: 350)

            Text(content.line)
                .font(.system(size: 15))
                .foregroundStyle(OB.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .at(20, 132, w: 330)

            art.at(0, 196, w: 390, h: 500)
        }
        .frame(width: 390, height: 706, alignment: .topLeading)
    }

    @ViewBuilder
    private var art: some View {
        switch index {
        case 0:
            FormatCarousel(active: active).at(0, 20, w: 390, h: 350)
        case 1:
            if active {
                ObClock(still: 21_500) { time in
                    MakingShowpiece(t: time.truncatingRemainder(dividingBy: MakingShowpiece.loop))
                }
            } else {
                MakingShowpiece(t: 0)
            }
        default:
            if active {
                ObClock(still: 7000) { time in
                    WeekOfVideos(t: min(time, 7000))
                }
            } else {
                WeekOfVideos(t: 0)
            }
        }
    }
}

// MARK: - Page 1: videos in any style

/// Four kinds of video side by side; the middle one plays. Drag them with the
/// finger: they follow it and settle on the nearest card.
private struct FormatCarousel: View {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Double = 0
    @State private var base: Double = 0
    @State private var dragging = false

    private struct Card {
        let name: String
        let symbol: String
        let media: String
        let colors: [Color]
    }

    private static let cards: [Card] = [
        Card(name: "3D story", symbol: "cube", media: "viral", colors: [OB.hex(0x4D297A), OB.hex(0x120D24)]),
        Card(name: "Did you know?", symbol: "lightbulb.fill", media: "fmt-facts", colors: [OB.hex(0x2978F5), OB.hex(0x5C47DB)]),
        Card(name: "Scary story", symbol: "moon.fill", media: "fmt-scary", colors: [OB.hex(0x4D297A), OB.hex(0x120D24)]),
        Card(name: "Motivation", symbol: "bolt.fill", media: "fmt-motivation", colors: [OB.hex(0xFA8C33), OB.hex(0xDB385C)]),
    ]

    var body: some View {
        let center = max(0, min(Self.cards.count - 1, Int(position.rounded())))
        ZStack(alignment: .top) {
            ForEach(Self.cards.indices, id: \.self) { index in
                let d = Double(index) - position
                let ad = abs(d)
                let scale = 1 - min(ad, 1.6) * 0.17
                let opacity = ad > 2.2 ? 0 : (ad > 1 ? 1 - (ad - 1) * 0.6 : 1 - ad * 0.25)
                card(Self.cards[index], playing: active && index == center)
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(reduceMotion ? 0 : d * 3))
                    .offset(x: d * 156)
                    .opacity(opacity)
                    .zIndex(100 - ad * 10)
            }
        }
        .padding(.top, 6)
        .frame(width: 390, height: 350, alignment: .top)
        .contentShape(Rectangle())
        // The cards' own drag. A child's gesture wins over the pager's, so a
        // swipe that starts on the cards never turns the page.
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        base = position
                    }
                    var next = base - value.translation.width / 156
                    let last = Double(Self.cards.count - 1)
                    if next < 0 { next *= 0.3 }
                    if next > last { next = last + (next - last) * 0.3 }
                    position = next
                }
                .onEnded { value in
                    dragging = false
                    let speed = value.velocity.width / 1000
                    let target = max(0, min(Double(Self.cards.count - 1), (position - speed * 2.2).rounded()))
                    withAnimation(OB.settle(0.42)) { position = target }
                }
        )
    }

    private func card(_ card: Card, playing: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                LinearGradient(colors: card.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                if playing {
                    OnboardingClip(name: card.media)
                } else {
                    MediaStill(name: card.media)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.4),
                ], startPoint: .bottom, endPoint: .top)
            }
            .frame(width: 196, height: 348)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: card.symbol).font(.system(size: 13, weight: .semibold))
                Text(card.name).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 11))
            .background(.black.opacity(0.34), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .padding(12)
        }
        .frame(width: 196, height: 348)
        .shadow(color: .black.opacity(0.24), radius: 17, y: 14)
        .allowsHitTesting(false)
    }
}

// MARK: - Page 2: it makes every video

/// The real chat flow at a calm pace, about 26 s: the prompt typed and sent,
/// the video card, the grey progress line, the script written line by line,
/// the voice, each picture as it is made, the captions, then the reel.
/// Every value is a function of the clock, so it can never get out of step.
struct MakingShowpiece: View {
    let t: Double

    static let loop = 27_600.0
    static let prompt = "A pig that went to war · 3D story, 30 sec"
    static let lines: [(String, String)] = [
        ("Hook", "A soldier strapped explosives to a pig."),
        ("Then", "It walked straight into the enemy base."),
        ("End", "Nobody expected what came next."),
    ]
    static let scenes = ["a soldier and his pig at night", "he gets the pig ready", "the explosives on its back",
                         "the pig sets off", "into the enemy base", "the remote in his hands"]
    static let words = ["A SOLDIER", "EXPLOSIVES", "PIG", "STRAIGHT", "BASE", "DISTANCE"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            bubble
            row
            settled
            progressLine
            MakingStage(t: t).at(16, 156, w: 358, h: 266)
            finished
            composer.at(14, 446)
        }
        .frame(width: 390, height: 500, alignment: .topLeading)
    }

    private var bubble: some View {
        let p = Tw.spring(Tw.seg(t, 2550, 3050))
        return HStack {
            Spacer(minLength: 0)
            Text(Self.prompt)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: 300, alignment: .trailing)
        }
        .frame(width: 374)
        .opacity(Tw.c01((t - 2550) / 180))
        .offset(y: (1 - p) * 360)
    }

    private var row: some View {
        let show = Tw.seg(t, 3200, 3500)
        return HStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OB.accent)
                .frame(width: 40, height: 40)
                .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Video · Photo video").font(.system(size: 15, weight: .semibold))
                Text("30 sec · 3D story · Storyteller · Bold pop")
                    .font(.system(size: 12))
                    .foregroundStyle(OB.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Open").font(.system(size: 15, weight: .semibold)).foregroundStyle(OB.accent)
        }
        .padding(.horizontal, 12)
        .frame(width: 358, height: 64)
        .background(OB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(show * (1 - Tw.seg(t, 4800, 5000)))
        .offset(y: (1 - show) * 10)
        .at(16, 54)
    }

    private var settled: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(OB.accent)
            Text("Photo video · 30 sec · 3D story · Storyteller · Bold pop")
                .font(.system(size: 14))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 358)
        .frame(minHeight: 56)
        .background(OB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(Tw.seg(t, 4800, 5050))
        .at(16, 54)
    }

    /// What it is doing and for how long, as the chat's progress line says it.
    private var progressLine: some View {
        let done = t >= 19_500
        let seconds = (t - 5200) / (19_500 - 5200) * 134
        return HStack(spacing: 5) {
            ObShimmer(text: done ? "Worked for 2m 14s" : stage + " · " + Tw.duration(seconds), t: t, done: done, size: 15)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OB.text3)
            Spacer(minLength: 0)
        }
        .opacity(Tw.seg(t, 5200, 5450))
        .at(18, 126, w: 354)
    }

    private var stage: String {
        if t < 9000 { return "Writing the script" }
        if t < 9600 { return "Plan ready: “The pig that went to war”, 6 scenes" }
        if t < 11_600 { return "Recording the voiceover…" }
        if t < 12_400 { return "Voiceover recorded: 30 seconds" }
        if t < 17_300 {
            let index = min(5, Int((t - 12_400) / 750))
            return "Making picture \(index + 1) of 6: \(Self.scenes[index])"
        }
        return "Putting the video together"
    }

    @ViewBuilder
    private var finished: some View {
        if t >= 19_500 {
            let p = Tw.spring(Tw.seg(t, 19_500, 20_100))
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [OB.hex(0x0B0820), OB.hex(0x2B2470)], startPoint: .topLeading, endPoint: .bottomTrailing)
                OnboardingClip(name: "viral")
                Text("30 s")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
            }
            .frame(width: 150, height: 267)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.32), radius: 25, y: 22)
            .scaleEffect(Tw.lerp(0.3, 1, p), anchor: UnitPoint(x: 0.5, y: 0.6))
            .opacity(Tw.c01((t - 19_500) / 150))
            .at(120, 150)
        }
    }

    private var composer: some View {
        let count = Int(Double(Self.prompt.count) * Tw.seg(t, 300, 2300))
        let sent = t >= 2550
        let typing = count > 0 && !sent
        return HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(OB.fill, in: Circle())
            HStack(spacing: 1) {
                if sent {
                    Text("Ask Postpilot").foregroundStyle(OB.text3)
                } else if count > 0 {
                    Text(String(Self.prompt.prefix(count))).truncationMode(.head)
                    BlinkCursor(height: 19)
                } else {
                    BlinkCursor(height: 19)
                    Text("Ask Postpilot").foregroundStyle(OB.text3)
                }
            }
            .font(.system(size: 16))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if typing {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(OB.accent, in: Circle())
                    .scaleEffect(t > 2350 && t < 2550 ? 0.84 : 1)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(OB.text2)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 362, height: 48)
        .glassEffect(.regular, in: Capsule())
    }
}

/// The blinking purple text cursor.
struct BlinkCursor: View {
    var height: CGFloat = 20

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(OB.accent)
                .frame(width: 2, height: height)
                .opacity(on ? 1 : 0)
        }
        .frame(width: 2, height: height)
    }
}

/// The white card where the video is made: the script, the voice, the six
/// pictures, the captions and the timeline.
private struct MakingStage: View {
    let t: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            OB.surface
            script.at(16, 14, w: 326)
            voice.at(16, 132, w: 326)
            Text("The pig that went to war · 30 s · 6 scenes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OB.text2)
                .lineLimit(1)
                .opacity(Tw.seg(t, 12_100, 12_350) * (1 - Tw.seg(t, 19_300, 19_500)))
                .at(14, 12, w: 330)
            lanes.at(14, 138, w: 330, h: 70)
            strip.at(14, 38, w: 330, h: 89)
            playhead
        }
        .frame(width: 358, height: 266, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(Tw.seg(t, 5200, 5500))
    }

    private var converge: Double { Tw.inOut(Tw.seg(t, 19_300, 19_600)) }

    private var script: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The pig that went to war")
                .font(.system(size: 17, weight: .bold))
                .padding(.bottom, 6)
            ForEach(0..<3, id: \.self) { index in
                scriptLine(index)
                    .frame(minHeight: 19, alignment: .topLeading)
                    .padding(.top, 5)
            }
        }
        .opacity(Tw.seg(t, 5400, 5700) * (1 - Tw.seg(t, 11_800, 12_100)))
    }

    private func scriptLine(_ index: Int) -> Text {
        let starts = [5900.0, 7000, 8100]
        let start = starts[index]
        guard t >= start else { return Text("") }
        let line = MakingShowpiece.lines[index]
        let key = Text(line.0 + "  ").bold().foregroundColor(OB.accent)
        let full = line.1
        var body: Text
        if index == 0, t >= 9600 {
            let words = full.split(separator: " ").map(String.init)
            let lit = Int(Double(words.count) * Tw.seg(t, 9700, 11_500) + 0.0001)
            body = Text("")
            for (k, word) in words.enumerated() {
                body = body + Text(k == 0 ? word : " " + word).foregroundColor(k < lit ? OB.accent : Color.primary)
            }
        } else {
            let count = Int(Double(full.count) * Tw.seg(t, start, start + 800))
            body = Text(String(full.prefix(count)))
            if count < full.count { body = body + Text("▍").foregroundColor(OB.accent) }
        }
        return (key + body).font(.system(size: 14))
    }

    private var voice: some View {
        let vp = Tw.seg(t, 9700, 11_500)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text("Storyteller")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OB.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<40, id: \.self) { index in
                    let b = Double(index)
                    let on = b / 40 <= vp
                    let h = 8 + abs(sin(b * 1.9) * 0.6 + sin(b * 0.5 + 2) * 0.4) * 56
                    RoundedRectangle(cornerRadius: 2)
                        .fill(OB.accent)
                        .frame(height: on ? h * (0.6 + 0.4 * abs(sin(t / 120 + b))) : 6)
                        .opacity(on ? 1 : 0)
                }
            }
            .frame(height: 70)
        }
        .opacity(Tw.seg(t, 9600, 9800) * (1 - Tw.seg(t, 11_800, 12_100)))
    }

    private var strip: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<6, id: \.self) { index in
                picture(index).offset(x: CGFloat(index) * 56)
            }
        }
        .frame(width: 330, height: 89, alignment: .topLeading)
        .opacity(Tw.seg(t, 12_100, 12_350))
    }

    private func picture(_ index: Int) -> some View {
        let start = 12_400 + Double(index) * 750
        let ready = start + 600
        let making = t >= start && t < ready
        let shown = t >= ready
        let rp = Tw.seg(t, ready, ready + 400)
        let cp = Tw.seg(t, 17_300 + Double(index) * 220, 17_300 + Double(index) * 220 + 260)
        let towardMiddle = (165 - (Double(index) * 56 + 25)) * converge
        return ZStack {
            OB.fill
            if making {
                SheenBand(t: t)
                Text("\(Int(99 * Tw.seg(t, start, ready)))%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(OB.text2)
            }
            if shown {
                MediaStill(name: "sc-\(index + 1)")
                    .frame(width: 50, height: 89)
                    .scaleEffect(Tw.lerp(1.14, 1, Tw.outC(rp)))
                    .blur(radius: rp < 1 ? 7 * (1 - rp) : 0)
            }
            StrokedWord(text: MakingShowpiece.words[index], size: 9.5, stroke: 1, color: OB.hex(0xFFE14D))
                .scaleEffect(cp > 0 ? Tw.outBack(cp) : 0)
                .position(x: 25, y: 55)
        }
        .frame(width: 50, height: 89)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity((t < start ? 0.55 : 1) * (1 - converge))
        .scaleEffect(1 - 0.45 * converge)
        .offset(x: towardMiddle)
    }

    private var lanes: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<64, id: \.self) { index in
                    let v = Double(index)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(OB.text2)
                        .frame(height: 4 + abs(sin(v * 1.1) * 0.7 + sin(v * 0.29) * 0.3) * 15)
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 5)
            .frame(width: 330, height: 26)
            .background(OB.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            ZStack(alignment: .topLeading) {
                ForEach(0..<6, id: \.self) { index in
                    let cp = Tw.seg(t, 17_300 + Double(index) * 220, 17_300 + Double(index) * 220 + 260)
                    Text(MakingShowpiece.words[index])
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(OB.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 50, height: 22)
                        .background(OB.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(cp)
                        .offset(x: CGFloat(index) * 56)
                }
            }
            .offset(y: 34)
        }
        .opacity(Tw.seg(t, 12_300, 12_550) * (1 - Tw.seg(t, 19_300, 19_500)))
    }

    private var playhead: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(OB.accent).frame(width: 2, height: 182)
            Circle().fill(OB.accent).frame(width: 10, height: 10).offset(y: -4)
        }
        .frame(width: 10, height: 182, alignment: .top)
        .opacity(t >= 17_600 && t < 19_100 ? 1 : 0)
        .at(10 + 328 * Tw.seg(t, 17_600, 19_000), 32)
    }
}

/// `.mk-sheen`: a soft grey band moving down a picture while it is made.
private struct SheenBand: View {
    let t: Double

    var body: some View {
        let phase = (t.truncatingRemainder(dividingBy: 2300)) / 1150
        let p = phase <= 1 ? phase : 2 - phase
        let eased = Tw.inOut(p)
        LinearGradient(colors: [.clear, OB.sheen, .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 49)
            .offset(y: Tw.lerp(-60, 60, eased))
    }
}

// MARK: - Page 3: fresh videos, every day

/// A week of posted videos fills in, the views climb, and Sunday's video is
/// already being made for 6:30 PM.
private struct WeekOfVideos: View {
    let t: Double

    private static let days: [(String, String, Double)] = [
        ("Mon", "w-chair", 212_000), ("Tue", "fmt-facts", 84_000), ("Wed", "viral", 2_900_000),
        ("Thu", "w-afro", 356_000), ("Fri", "w-friends", 97_000), ("Sat", "fmt-motivation", 640_000),
        ("Sun", "", 0),
    ]

    var body: some View {
        let e = 1 - pow(1 - Tw.seg(t, 300, 5200), 2.2)
        ZStack(alignment: .topLeading) {
            stat(e).at(16, 0, w: 358, h: 104)
            trending.at(0, 118, w: 390, align: .top)
            ForEach(0..<7, id: \.self) { index in
                day(index).at(16 + 52 * CGFloat(index), 164)
            }
            next.at(16, 332, w: 358, h: 150)
        }
        .frame(width: 390, height: 500, alignment: .topLeading)
    }

    private func stat(_ e: Double) -> some View {
        ZStack(alignment: .topLeading) {
            OB.surface
            VStack(alignment: .leading, spacing: 2) {
                Text("Views this week").font(.system(size: 13)).foregroundStyle(OB.text2)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Int(4_289_000 * e).formatted(.number.locale(Locale(identifier: "en_US"))))
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.64)
                        .monospacedDigit()
                    Text("+38%")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OB.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            WeekSparkline()
                .trim(from: 0, to: e)
                .stroke(OB.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 120, height: 44)
                .at(222, 44)
        }
        .frame(width: 358, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(Tw.seg(t, 0, 300))
    }

    private var trending: some View {
        let p = Tw.spring(Tw.seg(t, 700, 1150))
        return HStack(spacing: 6) {
            Image(systemName: "flame.fill").foregroundStyle(OB.hex(0xFF6A2B))
            Text("**Trending now:** 3D war stories")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(OB.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 7, y: 4)
        .scaleEffect(0.7 + 0.3 * p)
        .opacity(Tw.c01((t - 700) / 150))
    }

    private func day(_ index: Int) -> some View {
        let start = 1000 + Double(index) * 330
        let p = Tw.spring(Tw.seg(t, start, start + 520))
        let today = index == 6
        let entry = Self.days[index]
        return VStack(spacing: 5) {
            Text(today ? "Today" : entry.0)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(today ? OB.accent : OB.text2)
            ZStack {
                OB.fill
                if today {
                    SheenBand(t: t)
                } else {
                    MediaStill(name: entry.1)
                }
            }
            .frame(width: 46, height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if today {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(OB.accent, lineWidth: 2)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 7, y: 6)
            .scaleEffect(0.84 + 0.16 * p)
            .offset(y: (1 - p) * -44)

            if today {
                Text("6:30 PM")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OB.accent)
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(["tt", "ig", "yt"].enumerated()), id: \.offset) { k, id in
                        PlatformMark(id: id, size: 12)
                            .opacity(t >= start + 260 + Double(k) * 110 ? 1 : 0.18)
                    }
                }
                let grow = 1 - pow(1 - Tw.seg(t, start + 300, start + 1500), 2)
                Text(Tw.count(entry.2 * grow))
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
            }
        }
        .frame(width: 46)
        .opacity(Tw.c01((t - start) / 150))
    }

    private var next: some View {
        let p = Tw.spring(Tw.seg(t, 3400, 3900))
        let reveal = Tw.seg(t, 4800, 5100)
        return HStack(spacing: 14) {
            ZStack {
                OB.fill
                SheenBand(t: t)
                MediaStill(name: "fmt-scary")
                    .frame(width: 70, height: 124)
                    .opacity(reveal)
                    .blur(radius: reveal > 0 && reveal < 1 ? 6 * (1 - reveal) : 0)
            }
            .frame(width: 70, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Sunday, 6:30 PM").font(.system(size: 13, weight: .semibold)).foregroundStyle(OB.accent)
                Text("Lost among the lions").font(.system(size: 17, weight: .semibold))
                Text("Scary story · 30 s · Storyteller").font(.system(size: 13)).foregroundStyle(OB.text2)
                HStack(spacing: 5) {
                    PlatformMark(id: "tt", size: 20)
                    PlatformMark(id: "ig", size: 20)
                    PlatformMark(id: "yt", size: 20)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(width: 358, height: 150)
        .background(OB.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(Tw.c01((t - 3400) / 180))
        .offset(y: (1 - p) * 30)
    }
}

/// The views line climbing, in a 120 x 44 box.
private struct WeekSparkline: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(2, 40), (14, 36), (24, 38), (36, 30), (46, 32), (58, 24),
                                            (68, 26), (80, 16), (92, 18), (104, 8), (118, 3)]
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX + point.0 / 120 * rect.width, y: rect.minY + point.1 / 44 * rect.height)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
