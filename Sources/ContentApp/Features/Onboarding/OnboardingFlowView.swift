import SwiftUI
import UIKit

/// First run.
///
///   welcome -> six questions -> the ring -> what Autocast does
///           -> account -> email -> code -> verified -> in
///
/// Remi's `OnboardingFlowView`, move for move: steps are states rather than
/// pushed screens, one progress bar and one back chevron live here rather than
/// inside each screen, and every change of step is the same
/// `.snappy(duration: 0.25)`.
///
/// Nothing personal is asked before the app has been used. The name is asked
/// on one screen only -- email sign-up -- because Apple and Google already
/// hand theirs over, and asking anyway is what App Review rejects.
struct OnboardingFlowView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 🔴 One bar for the whole run, not one per screen. Drawn
                // inside each view it crossfades between screens instead of
                // sliding forward.
                if let progress = session.onboarding.progress {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .animation(.snappy(duration: 0.4), value: progress)
                }

                content
                    // Every screen takes the whole page. Without this a screen
                    // that sizes to its content is squeezed into a column
                    // while the two slide past each other.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The conditional lives inside the item, not around it:
                // ToolbarItem's content is a plain @ViewBuilder, which handles
                // `if` reliably.
                ToolbarItem(placement: .topBarLeading) {
                    if session.onboarding.canGoBack {
                        Button { session.onboardingBack() } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: session.onboarding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.onboarding {
        case .welcome:
            OnboardingWelcome()

        case .question(let index):
            // Guarded: a stored step can outlive a question being removed from
            // the set, and an out-of-range index would crash on launch.
            if index < OnboardingQuestion.all.count {
                OnboardingQuestionView(step: session.onboarding, question: OnboardingQuestion.all[index])
            } else {
                Color.clear.task { session.onboardingNext() }
            }

        case .building:
            OnboardingBuilding()

        case .included:
            OnboardingIncluded()

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

// MARK: - Welcome

/// Deliberately still. It is the first thing anybody sees, and making them wait
/// for a staggered entrance is charging them for a flourish before they have
/// agreed to anything.
private struct OnboardingWelcome: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            OnboardingArt(name: "welcome-hero", fallback: "hero-plan")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
                .layoutPriority(1)

            Text("Your content, posted for you")
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)

            Text("Plan a month, write the captions, and post to TikTok, YouTube and Instagram — you approve everything first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 10)

            OnboardingButton(title: "Get Started") { session.onboardingNext() }
                .padding(.top, 24)

            Button {
                session.goToEmail(.login)
            } label: {
                Text("Already have an account? **Sign In**")
                    .font(.subheadline)
            }
            .tint(.primary)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
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

// MARK: - One question

/// The only question screen. Adding or reordering questions never touches this.
///
/// A single-choice question has no button: tapping an answer *is* the answer,
/// so the pick lands, is seen, and the page moves on by itself (Abel, 21 Sep
/// 2026: "after choosing why do they have to choose a button?"). Only a
/// question that takes several answers keeps one, because there a tap cannot
/// mean "done".
private struct OnboardingQuestionView: View {
    let step: OnboardingStep
    let question: OnboardingQuestion

    @Environment(AppSession.self) private var session

    private var chosen: Set<String> { session.onboardingAnswers[question.id] ?? [] }

    /// How long the pick stays on screen before the page moves. Remi's 400ms:
    /// the selection animation is 0.18s and the page crossfade 0.25s, so
    /// anything shorter shows the pick for a sliver and reads as a jump.
    private let settle: Duration = .milliseconds(400)

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingPrompt.title(for: question))
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(question.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            ScrollView {
                if question.isDetailed {
                    VStack(spacing: 10) {
                        ForEach(question.options) { option in
                            DetailedOption(option: option, isChosen: chosen.contains(option.id)) {
                                tap(option)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(question.options) { option in
                            OptionTile(option: option, isChosen: chosen.contains(option.id)) {
                                tap(option)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .scrollIndicators(.hidden)

            if question.selection == .multiple {
                // Never disabled. Nothing picked costs a little quality and
                // nothing else, so it says "Skip" and lets them through.
                OnboardingButton(
                    title: chosen.isEmpty ? "Skip" : "Continue",
                    tint: chosen.isEmpty ? Color.secondary : Theme.accent
                ) {
                    session.onboardingNext(from: step)
                }
                .padding(.top, 10)
                .animation(.snappy(duration: 0.2), value: chosen.isEmpty)
            }
        }
    }

    private func tap(_ option: OnboardingQuestion.Option) {
        withAnimation(.snappy(duration: 0.18)) {
            session.onboardingToggle(option, in: question)
        }
        guard question.selection == .single else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let answered = step
        Task {
            try? await Task.sleep(for: settle)
            // Only moves on if this is still the question on screen: a second
            // tap inside the settle, or Back, must not skip one.
            session.onboardingNext(from: answered)
        }
    }
}

/// Onboarding asks the Brand page's questions as questions.
enum OnboardingPrompt {
    static func title(for question: OnboardingQuestion) -> String {
        switch question.id {
        case "category": return "What are you promoting?"
        case "goal": return "What’s your main goal?"
        case "audience": return "Who is it for?"
        case "styles": return "What kind of videos?"
        case "voice": return "What’s your voice?"
        case "cta": return "What should viewers do?"
        default: return question.title
        }
    }
}

// MARK: - The ring

/// The moment the answers are written to the brand. The ring is a clock, and
/// says so by naming what is actually being saved rather than inventing a
/// percentage for work nobody can measure.
private struct OnboardingBuilding: View {
    @Environment(AppSession.self) private var session

    /// What is being written, in the order it happens. Each line lands, ticks,
    /// and the next begins.
    private static let steps: [(String, String)] = [
        ("Your answers", "checklist"),
        ("What you're promoting", "sparkles"),
        ("Who it's for", "person.2"),
        ("How it should sound", "quote.bubble"),
        ("When it posts", "clock"),
    ]

    /// How many lines have landed.
    @State private var done = 0
    @State private var finished = false

    private let beat: Duration = .milliseconds(420)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    let landed = index < done
                    let current = index == done

                    HStack(spacing: 14) {
                        ZStack {
                            // The tick replaces the symbol in place, which is
                            // the whole animation: no ring, no percentage.
                            Image(systemName: landed ? "checkmark.circle.fill" : step.1)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(landed ? Theme.accent : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.bounce, value: landed)
                        }
                        .frame(width: 26)

                        Text(step.0)
                            .font(.body.weight(landed || current ? .semibold : .regular))
                            .foregroundStyle(landed || current ? Color.primary : Color.secondary)

                        Spacer(minLength: 0)
                    }
                    // The line being written is full strength, the ones still
                    // to come are faint: the eye always knows where it is.
                    .opacity(landed ? 1 : (current ? 1 : 0.35))
                    .offset(y: current ? 0 : 0)
                    .animation(.snappy(duration: 0.3), value: done)
                }
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 32)

            Text(finished ? "Ready" : "Setting up your brand")
                .font(.title3.weight(.semibold))
                .padding(.top, 40)
                .contentTransition(.opacity)
                .animation(.snappy(duration: 0.25), value: finished)

            Spacer(minLength: 0)

            Text("You can change any of this later in Profile.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 40)
        }
        // Fills the page, so nothing is squeezed into a column while the
        // screens slide (Abel's screenshot, 21 Sep 2026).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.impact(weight: .light), trigger: done)
        .task {
            for step in 1...Self.steps.count {
                try? await Task.sleep(for: beat)
                withAnimation(.snappy(duration: 0.3)) { done = step }
            }
            withAnimation(.snappy(duration: 0.25)) { finished = true }
            try? await Task.sleep(for: .milliseconds(450))
            session.onboardingNext()
        }
    }
}

// MARK: - What it does

/// What somebody gets, said before they are asked for anything.
private struct OnboardingIncluded: View {
    @Environment(AppSession.self) private var session

    private static let items: [(String, String)] = [
        ("calendar", "A month of posts, planned"),
        ("sparkles", "Captions and hashtags written with you"),
        ("paperplane", "Posting to TikTok, YouTube and Instagram"),
        ("hand.thumbsup", "Nothing goes out until you approve it"),
        ("chart.bar", "What worked, and what to post next"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 76))
                .foregroundStyle(Theme.accent)

            Text("Here’s what Autocast does")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 22)
                .padding(.horizontal, 24)

            Text("Everything below is yours from today.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.items, id: \.1) { item in
                    HStack(spacing: 14) {
                        Image(systemName: item.0)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        Text(item.1)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.top, 34)
            .padding(.horizontal, 36)

            Spacer()

            OnboardingButton(title: "Start posting") { session.onboardingNext() }
        }
    }
}
