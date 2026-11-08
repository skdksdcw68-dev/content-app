import SwiftUI
import UIKit

/// First run, drawn as the onboarding mockup draws it
/// (https://claude.ai/artifact/7QujxtntQAHCRsoMyE7mEN):
///
///   splash -> welcome -> how it works (3 pages) -> where you post -> privacy
///          -> pings -> the ring -> account -> email -> code -> in
///
/// No navigation bar and no scroll views: the mockup has neither, and their
/// bars and edge effects were the "walls" Abel saw on the old pages (8 Nov
/// 2026). The back button and the small progress bar are drawn here, once, in
/// the mockup's places. Screens slide the way the mockup slides them, on its
/// one easing curve, with no spring and no bounce.
struct OnboardingFlowView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The screen on show, and the one sliding away.
    @State private var shown: OnboardingStep?
    @State private var leaving: OnboardingStep?
    /// 0 -> 1 over a change of screen: the slide, and the fade beside it.
    @State private var move: Double = 1
    @State private var fade: Double = 1
    @State private var back = false
    @State private var soft = false
    @State private var transition = 0

    var body: some View {
        let current = shown ?? session.onboarding
        GeometryReader { geo in
            ZStack {
                ForEach(visible(current), id: \.screenKey) { step in
                    let isIn = step.screenKey == current.screenKey
                    screen(step)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: offset(isIn: isIn, width: geo.size.width))
                        .opacity(opacity(isIn: isIn))
                        .zIndex(isIn != back ? 2 : 1)
                        .allowsHitTesting(isIn)
                }
            }
        }
        .background(OB.canvas.dismissesKeyboardOnTap().ignoresSafeArea())
        .overlay { FlowChrome(step: current) { session.onboardingBack() } }
        .onChange(of: session.onboarding) { old, new in go(from: old, to: new) }
    }

    private func visible(_ current: OnboardingStep) -> [OnboardingStep] {
        if let leaving, leaving.screenKey != current.screenKey { return [leaving, current] }
        return [current]
    }

    // MARK: Moving between screens

    /// The mockup's `transition()`: forward, the new screen slides in from the
    /// right while the old one slips a third of the way left and fades; back
    /// is the mirror. Between the calm pages it is a 40 pt drift and a
    /// crossfade. Reduce Motion: a crossfade only.
    private func go(from old: OnboardingStep, to new: OnboardingStep) {
        let previous = shown ?? old
        guard previous.screenKey != new.screenKey else {
            shown = new
            return
        }
        back = new.order < previous.order
        soft = previous.isSoft && new.isSoft
        leaving = previous
        shown = new
        move = 0
        fade = 0
        transition += 1
        let token = transition
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : OB.settle(0.46)) { move = 1 }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.3 : 0.34)) { fade = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            if transition == token { leaving = nil }
        }
    }

    private func offset(isIn: Bool, width: CGFloat) -> CGFloat {
        if reduceMotion { return 0 }
        let rest = 1 - move
        if soft {
            return isIn ? (back ? -40 : 40) * rest : (back ? 40 : -40) * move
        }
        if isIn {
            return back ? -0.3 * width * rest : width * rest
        }
        return back ? width * move : -0.3 * width * move
    }

    private func opacity(isIn: Bool) -> Double {
        if reduceMotion || soft { return isIn ? fade : 1 - fade }
        if isIn { return back ? fade : 1 }
        return back ? 1 : 1 - fade
    }

    // MARK: Screens

    @ViewBuilder
    private func screen(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingWelcome()

        case .tour(let page):
            OnboardingTourView(page: page)

        case .question(let index):
            // Guarded: a stored step can outlive a question being removed.
            if index < OnboardingQuestion.all.count {
                WhereYouPostPage(step: step, question: OnboardingQuestion.all[index])
            } else {
                Color.clear.task { session.onboardingNext() }
            }

        case .privacy:
            OnboardingPrivacyView()

        case .pings:
            OnboardingPingsView()

        case .building:
            OnboardingRing()

        case .included:
            Color.clear.task { session.onboardingNext() }

        case .account:
            AccountScreen(
                onEmail: { session.goToEmail(.signup) },
                onLogin: { session.goToEmail(.login) },
                onDone: { session.onboarding(goTo: .verified($0)) }
            )

        case .email(let mode):
            EmailScreen(mode: mode) { address, name in
                session.pendingEmail = address
                session.pendingName = name
                session.onboarding(goTo: .code(mode))
            } onDone: { session.onboarding(goTo: .verified($0)) }

        case .code(let mode):
            CodeScreen(
                mode: mode,
                email: session.pendingEmail,
                name: session.pendingName,
                wasAnonymous: session.isAnonymous,
                onDone: { session.onboarding(goTo: .verified($0)) }
            )

        case .verified(let arrival):
            VerifiedScreen(arrival: arrival) { session.onboardingNext() }

        case .done:
            // RootView swaps this view out on .done.
            Color.clear
        }
    }
}

/// Where each screen sits in the run, and how it moves.
extension OnboardingStep {
    /// The tour's three pages are one screen that pages inside itself.
    var screenKey: String {
        if case .tour = self { return "tour" }
        return storedValue
    }

    var order: Int {
        switch self {
        case .welcome: return 0
        case .tour(let page): return 1 + page
        case .question(let index): return 10 + index
        case .privacy: return 30
        case .pings: return 31
        case .building: return 32
        case .included: return 33
        case .account: return 34
        case .email: return 35
        case .code: return 36
        case .verified: return 37
        case .done: return 38
        }
    }

    /// The calm pages, which drift into each other rather than slide.
    var isSoft: Bool {
        switch self {
        case .question, .privacy, .pings, .email, .code: return true
        default: return false
        }
    }

    /// The round glass back button, where the mockup has it.
    var showsBack: Bool {
        switch self {
        case .question, .privacy, .pings, .account, .email, .code: return true
        default: return false
        }
    }

    /// The short bar at the top: a third, two thirds, full, over the three
    /// calm pages, as the mockup fills it.
    var barFill: Double? {
        let questions = Double(OnboardingQuestion.all.count)
        switch self {
        case .question(let index): return Double(index + 1) / (questions + 2)
        case .privacy: return (questions + 1) / (questions + 2)
        case .pings: return 1
        default: return nil
        }
    }
}

/// The mockup's chrome: a round glass back button at 16, 58 and a 120 pt bar
/// at the top centre.
private struct FlowChrome: View {
    let step: OnboardingStep
    let goBack: () -> Void

    var body: some View {
        MockupCanvas {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: 390, height: 844).allowsHitTesting(false)

                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OB.accent)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .opacity(step.showsBack ? 1 : 0)
                .allowsHitTesting(step.showsBack)
                .at(16, 58)

                ZStack(alignment: .leading) {
                    Capsule().fill(OB.fill)
                    Capsule().fill(OB.accent)
                        .frame(width: 120 * (step.barFill ?? 0))
                        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45), value: step.barFill)
                }
                .frame(width: 120, height: 4)
                .opacity(step.barFill == nil ? 0 : 1)
                .allowsHitTesting(false)
                .at(135, 78)
            }
            .animation(.easeOut(duration: 0.25), value: step.showsBack)
            .animation(.easeOut(duration: 0.25), value: step.barFill == nil)
        }
    }
}

/// The picture. Falls back rather than leaving a hole, so the flow ships before
/// the art does and improves when it lands.
struct OnboardingArt: View {
    let name: String
    var fallback: String?

    var body: some View {
        Group {
            if let art = UIImage(named: name) ?? fallback.flatMap(UIImage.init(named:)) {
                Image(uiImage: art).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: Theme.mediaRadius, style: .continuous)
                    .fill(Theme.softAccent)
            }
        }
    }
}

// MARK: - Where do you post?

/// The mockup's page, exactly: a centred question, four soft glass rows
/// (TikTok, Instagram Reels, YouTube Shorts, All of the above) with a tick box
/// each, Skip always there, and Continue that wakes once something is picked.
private struct WhereYouPostPage: View {
    let step: OnboardingStep
    let question: OnboardingQuestion

    @Environment(AppSession.self) private var session

    private static let places: [(id: String, label: String)] = [
        ("tiktok", "TikTok"), ("reels", "Instagram Reels"), ("shorts", "YouTube Shorts"),
    ]

    private var chosen: Set<String> { session.onboardingAnswers[question.id] ?? [] }
    private var allChosen: Bool { Self.places.allSatisfy { chosen.contains($0.id) } }
    private var anyChosen: Bool { Self.places.contains { chosen.contains($0.id) } }

    var body: some View {
        MockupCanvas {
            ZStack(alignment: .topLeading) {
                QuestionHaze()

                Text(OnboardingPrompt.title(for: question))
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.39)
                    .multilineTextAlignment(.center)
                    .at(28, 142, w: 334, align: .top)

                Text("Pick all that apply. You connect them later.")
                    .font(.system(size: 15))
                    .foregroundStyle(OB.text2)
                    .multilineTextAlignment(.center)
                    .at(36, 182, w: 318, align: .top)

                ForEach(Array(Self.places.enumerated()), id: \.offset) { index, place in
                    PlaceRow(selected: chosen.contains(place.id), label: place.label) {
                        PlatformMark(id: place.id, size: 30)
                    } tap: {
                        toggle(place.id)
                    }
                    .at(20, 240 + 74 * CGFloat(index))
                }

                PlaceRow(selected: allChosen, label: "All of the above") {
                    Trio()
                } tap: {
                    toggleAll()
                }
                .at(20, 462)

                BevelSkip(title: "Skip") { session.onboardingNext(from: step) }
                    .at(20, 680)

                BevelPill(title: "Continue", on: anyChosen) {
                    session.onboardingNext(from: step)
                }
                .at(20, 748)
            }
        }
    }

    private func toggle(_ id: String) {
        var next = chosen
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        set(next)
    }

    private func toggleAll() {
        var next = chosen.subtracting(Self.places.map(\.id))
        if !allChosen { next.formUnion(Self.places.map(\.id)) }
        set(next)
    }

    private func set(_ next: Set<String>) {
        withAnimation(.easeOut(duration: 0.18)) { session.onboardingAnswers[question.id] = next }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// `.wrow`: one soft glass row, 350 x 62.
private struct PlaceRow<Mark: View>: View {
    let selected: Bool
    let label: String
    @ViewBuilder let mark: () -> Mark
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                mark().frame(width: 30, height: 30)
                Text(label)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TickBox(on: selected)
            }
            .padding(.horizontal, 16)
            .frame(width: 350, height: 62)
            .obGlass(radius: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(OB.accent, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}

/// `.cb`: a rounded tick box that fills purple.
private struct TickBox: View {
    let on: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(on ? OB.accent : Color.clear)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(OB.text3, lineWidth: 1.5)
                .opacity(on ? 0 : 1)
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .opacity(on ? 1 : 0)
                .scaleEffect(on ? 1 : 0.5)
                .animation(.timingCurve(0.2, 0.9, 0.3, 1.5, duration: 0.22), value: on)
        }
        .frame(width: 24, height: 24)
        .animation(.easeOut(duration: 0.18), value: on)
    }
}

/// `.trio`: the three marks overlapping, for All of the above.
private struct Trio: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            mark("tt").offset(x: 0, y: 0)
            mark("ig").offset(x: 13, y: 5)
            mark("yt").offset(x: 5, y: 13)
        }
        .frame(width: 30, height: 30, alignment: .topLeading)
    }

    private func mark(_ id: String) -> some View {
        PlatformMark(id: id, size: 17)
            .padding(1.5)
            .background(OB.surface, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            .padding(-1.5)
    }
}

/// Onboarding asks the Brand page's questions as questions.
enum OnboardingPrompt {
    static func title(for question: OnboardingQuestion) -> String {
        switch question.id {
        case "format": return "Pick your format"
        case "narrator": return "Pick the voice"
        case "category": return "What are you promoting?"
        case "goal": return "What’s your main goal?"
        case "audience": return "Who is it for?"
        case "styles": return "What kind of videos?"
        case "voice": return "What’s your voice?"
        case "cta": return "What should viewers do?"
        case "platforms": return "Where do you post?"
        case "formats": return "How are your videos made?"
        case "length": return "How long should they be?"
        case "cadence": return "How often should it post?"
        case "camera": return "Are you on camera?"
        case "avoid": return "Anything it should never do?"
        default: return question.title
        }
    }
}

// MARK: - The ring

/// The mockup's ring page: five lines saved one at a time, each turning full
/// strength and ticking, then "Ready", then on to the account.
private struct OnboardingRing: View {
    @Environment(AppSession.self) private var session

    private static let lines = [
        "Where you post", "Ideas picked for you", "Best times to post", "Your pings", "Your first video",
    ]

    /// How many lines are being written (current), and how many are done.
    @State private var current = 0
    @State private var done = 0
    @State private var ready = false

    var body: some View {
        MockupCanvas {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(Self.lines.enumerated()), id: \.offset) { index, line in
                        RingLine(text: line, active: index < current, done: index < done)
                    }
                }
                .frame(width: 270, alignment: .leading)
                .at(60, 292)

                Text(ready ? "Ready" : "Setting up your brand")
                    .font(.system(size: 20, weight: .semibold))
                    .contentTransition(.opacity)
                    .at(0, 537, w: 390, align: .top)

                Text("You can change any of this later in Profile.")
                    .font(.system(size: 13))
                    .foregroundStyle(OB.text3)
                    .at(0, 780, w: 390, align: .top)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: done)
        .task { await run() }
    }

    private func run() async {
        for index in 0..<Self.lines.count {
            withAnimation(.easeOut(duration: 0.3)) { current = index + 1 }
            try? await Task.sleep(for: .milliseconds(420))
            withAnimation(.easeOut(duration: 0.25)) { done = index + 1 }
        }
        try? await Task.sleep(for: .milliseconds(500))
        withAnimation(.easeOut(duration: 0.25)) { ready = true }
        try? await Task.sleep(for: .milliseconds(700))
        session.onboardingNext(from: .building)
    }
}

/// `.rl`: a circle that fills and ticks, and the line beside it.
private struct RingLine: View {
    let text: String
    let active: Bool
    let done: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(done ? OB.accent : Color.clear)
                Circle().strokeBorder(done ? OB.accent : OB.text3, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(done ? 1 : 0)
            }
            .frame(width: 24, height: 24)
            .scaleEffect(done ? 1.08 : 1)
            .animation(.easeOut(duration: 0.25), value: done)

            Text(text)
                .font(.system(size: 17, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : OB.text2)
        }
        .frame(height: 24)
        .opacity(active ? 1 : 0.35)
        .animation(.easeOut(duration: 0.3), value: active)
    }
}
