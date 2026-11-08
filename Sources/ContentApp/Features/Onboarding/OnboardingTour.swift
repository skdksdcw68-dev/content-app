import SwiftUI

/// The first screen: an ad for what Postpilot does, playing, before anybody is
/// asked anything (Abel, 7 Nov 2026: "the onboarding shouldn't be something they
/// have to choose before they understand the app"). Cal AI's shape, our look.
struct OnboardingVideoWelcome: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
            OnboardingPromo()
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary, lineWidth: 5))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .frame(maxHeight: .infinity)
                .aspectRatio(9 / 16, contentMode: .fit)
                .padding(.top, 8)
                .accessibilityLabel("A video made with Postpilot")

            Text("Viral videos, made and posted for you")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)
                .padding(.top, 18)

            OnboardingButton(title: "Get Started") { session.onboardingNext() }
                .padding(.top, 16)

            Button {
                session.goToEmail(.login)
            } label: {
                Text("Already have an account? **Sign In**")
                    .font(.subheadline)
            }
            .tint(.primary)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - How it works

/// What the three pages say. Data, so the flow counts them instead of
/// hard-coding "three".
enum OnboardingTour {
    struct Page {
        let title: String
        let line: String
    }

    static let pages: [Page] = [
        Page(title: "Videos in any style", line: "Swipe through the kinds Postpilot makes."),
        Page(title: "It makes every video", line: "Script, voice, scenes and captions, done for you."),
        Page(title: "Fresh videos, every day", line: "A new one is made and posted on a schedule."),
    ]
}

/// One "how it works" page: a title at the top, one moving picture, dots,
/// Continue. Swipe left or right to move between the pages.
struct OnboardingTourView: View {
    let page: Int

    @Environment(AppSession.self) private var session

    var body: some View {
        let content = OnboardingTour.pages[min(page, OnboardingTour.pages.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            Text(content.title)
                .font(.system(size: 30, weight: .bold))
                .padding(.horizontal, 20)

            Text(content.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 6)

            Group {
                switch page {
                case 0: FormatCarousel()
                case 1: MakingShowpiece()
                default: WeekOfVideos()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(page)
            .transition(.opacity)

            HStack(spacing: 6) {
                ForEach(0..<OnboardingTour.pages.count, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: index == page ? 16 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
            .animation(.snappy(duration: 0.25), value: page)

            OnboardingButton(title: "Continue") { session.onboardingNext() }
                .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { drag in
                guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                if drag.translation.width < -50 {
                    session.onboardingNext()
                } else if drag.translation.width > 50 {
                    session.onboardingBack()
                }
            }
        )
        // Soft glass: a faint purple haze top right, grey bottom left.
        .softGlassBackground()
    }
}

// MARK: - Page 1: formats

/// Four kinds of video side by side. Swipe, and the one in the middle plays.
private struct FormatCarousel: View {
    private let cards: [(String, String, String)] = [
        ("3D story", "viral", "viral"),
        ("Did you know?", "fmt-facts", "fmt-facts"),
        ("Scary story", "fmt-scary", "fmt-scary"),
        ("Motivation", "fmt-motivation", "fmt-motivation"),
    ]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(cards, id: \.0) { card in
                    VStack(spacing: 10) {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.19, green: 0.14, blue: 0.55), Color(red: 0.07, green: 0.05, blue: 0.20)], startPoint: .top, endPoint: .bottom)
                            MediaStill(name: card.2)
                            if let url = OnboardingMedia.video(card.1) {
                                SampleLoopVideo(url: url)
                            }
                        }
                        .frame(width: 190, height: 338)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)

                        Text(card.0).font(.subheadline.weight(.semibold))
                    }
                    .scrollTransition(axis: .horizontal) { content, phase in
                        content
                            .scaleEffect(phase.isIdentity ? 1 : 0.88)
                            .opacity(phase.isIdentity ? 1 : 0.6)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 90, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Page 2: it makes every video

/// The real chat flow, slowed down: the idea typed, the plan ticking, the
/// scenes appearing one by one, the finished video popping out. About 20 s,
/// looping. A function of the clock, so it cannot get out of step.
private struct MakingShowpiece: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let idea = "A pig that went to war"
    private static let steps = ["Writing the script", "Recording the voice", "Making the scenes", "Adding captions"]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 18.0 : context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 22)
            VStack(spacing: 14) {
                bubble(t)
                stepsList(t)
                ZStack {
                    scenes(t)
                    finished(t)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
    }

    private func bubble(_ t: Double) -> some View {
        let typed = Int(Double(Self.idea.count) * ramp(t, 0.3, 2.3))
        return Text(String(Self.idea.prefix(typed)) + (typed < Self.idea.count ? "|" : ""))
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: Capsule())
    }

    private func stepsList(_ t: Double) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                let begins = 3.0 + 2.2 * Double(index)
                let on = ramp(t, begins, begins + 0.5)
                let done = ramp(t, begins + 1.8, begins + 2.1) > 0.5
                HStack(spacing: 12) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(done ? Theme.accent : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(step)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(0.35 + 0.65 * on)
                .offset(y: CGFloat((1 - on) * 10))
            }
        }
    }

    /// Six scenes, one every 0.7 s, then they melt away.
    private func scenes(_ t: Double) -> some View {
        let names = ["sc-1", "sc-2", "sc-3", "sc-4", "sc-5", "sc-6"]
        return HStack(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let r = ramp(t, 11.8 + 0.7 * Double(index), 12.5 + 0.7 * Double(index))
                MediaStill(name: name)
                    .frame(width: 48, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .blur(radius: CGFloat((1 - r) * 8))
                    .opacity(r)
            }
        }
        .opacity(1 - ramp(t, 16.6, 17.2))
    }

    private func finished(_ t: Double) -> some View {
        let r = ramp(t, 17.0, 17.8)
        return ZStack {
            if let url = OnboardingMedia.video("viral") {
                SampleLoopVideo(url: url)
            }
        }
        .frame(width: 106, height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
        .scaleEffect(0.8 + 0.2 * r)
        .opacity(r)
    }
}

// MARK: - Page 3: every day

/// A week filling up with videos, the views counting up.
private struct WeekOfVideos: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private let days: [(String, String)] = [
        ("Mon", "w-chair"), ("Tue", "fmt-facts"), ("Wed", "viral"), ("Thu", "w-afro"),
        ("Fri", "w-friends"), ("Sat", "fmt-motivation"), ("Sun", "fmt-scary"),
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 8.0 : context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 11)
            VStack(spacing: 22) {
                VStack(spacing: 2) {
                    Text(views(t))
                        .font(.system(size: 44, weight: .bold))
                        .monospacedDigit()
                    Text("views this week")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let r = ramp(t, 0.4 + 0.6 * Double(index), 1.0 + 0.6 * Double(index))
                        let making = index == days.count - 1
                        VStack(spacing: 6) {
                            MediaStill(name: day.1)
                                .frame(width: 44, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    if making {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(.black.opacity(0.4))
                                            .overlay(ProgressView().tint(.white).scaleEffect(0.7))
                                    }
                                }
                                .offset(y: CGFloat((1 - r) * -24))
                                .opacity(r)
                            Text(day.0)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Sunday’s video is being made for 6:30 PM")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(ramp(t, 5.6, 6.2))
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
        }
    }

    private func views(_ t: Double) -> String {
        let value = Int(1_840_000 * ramp(t, 0.6, 7.0))
        return value.formatted(.number)
    }
}
