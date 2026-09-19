import SwiftUI

/// First run.
///
///   welcome -> what did you build -> who is it for -> what's your voice
///           -> connect an account -> connect a generator -> in
///
/// Everything it collects writes to something that already exists: the two
/// questions fill `brands.niche` and `brands.audience`, and the voice fills
/// `brand_settings.tone`. Onboarding is not a second place these live -- it is
/// the first way they get filled in, which is why coming back to You → Your
/// brand shows exactly what was answered here.
struct OnboardingFlowView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if session.onboarding != .welcome {
                            Button { session.onboardingBack() } label: {
                                Image(systemName: "chevron.left").fontWeight(.semibold)
                            }
                            .accessibilityLabel("Back")
                        }
                    }
                }
                // 🔴 There was a `.transition(.asymmetric(…))` here and it did
                // nothing. A transition describes how *the view it is attached
                // to* enters and leaves, and this one is attached outside the
                // switch — to a view that never enters or leaves. SwiftUI saw
                // one view whose contents changed, so the text swapped in place
                // and the only thing that visibly moved was the button at the
                // bottom, which had an animation of its own. That was "the page
                // is only changing at the bottom".
                //
                // This is exactly what email-app does, and it works there: a
                // plain switch, one animation keyed to the step, and SwiftUI's
                // own crossfade between the two branches. Same duration, so the
                // two apps feel like the same hand made them.
                .animation(.snappy(duration: 0.25), value: session.onboarding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.onboarding {
        case .welcome:
            OnboardingWelcome()

        case .name:
            OnboardingName()

        case .question(let index):
            // Guarded: a stored step can outlive a question being removed from
            // the set, and an out-of-range index would crash on launch.
            if index < OnboardingQuestion.all.count {
                OnboardingQuestionView(question: OnboardingQuestion.all[index])
            } else {
                OnboardingConnect(kind: .account)
            }

        case .connectAccount:
            OnboardingConnect(kind: .account)

        case .pro:
            // Closable: Pro is offered, never required to get in.
            PaywallView(onClose: { session.onboardingNext() })
                .toolbar(.hidden, for: .navigationBar)

        case .done:
            Color.clear
        }
    }
}

// MARK: - Welcome

/// Deliberately still.
///
/// It had a staggered entrance and a slow drift on the artwork. Both went: this
/// is the first thing anybody sees, and making them wait four tenths of a second
/// for the button to finish arriving is charging them for a flourish before they
/// have agreed to anything. It is drawn once, complete.
private struct OnboardingWelcome: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            OnboardingArt(name: "welcome-hero", fallback: "promo-plan")
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("You built something.\nLet's tell people about it.")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Autocast writes your posts, makes the videos, and puts them out on time. You say yes; it does the rest.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)

            Spacer(minLength: 24)

            Button { session.onboardingNext() } label: {
                Text("Get started")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Theme.canvas)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The picture. Falls back rather than leaving a hole, so the flow ships before
/// the art does and improves when it lands.
private struct OnboardingArt: View {
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

// MARK: - Your name

/// "What should we call you?" -- the account is the person. What they are
/// promoting is optional and names the brand the planner writes for.
private struct OnboardingName: View {
    @Environment(AppSession.self) private var session
    @State private var name = ""
    @State private var promoting = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let progress = session.onboarding.progress {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                        .padding(.bottom, 2)
                }
                Text("What should we call you?")
                    .font(.title2.bold())
                Text("This is your Autocast account. Your TikTok, YouTube and Instagram connect to it later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            VStack(spacing: 12) {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.next)
                    .focused($focused)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                TextField("What you’re promoting (optional)", text: $promoting)
                    .textContentType(.organizationName)
                    .submitLabel(.done)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 16)

            Button {
                Task {
                    saving = true
                    await session.saveName(name, promoting: promoting)
                    saving = false
                    session.onboardingNext()
                }
            } label: {
                Group {
                    if saving { ProgressView() } else { Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Skip" : "Continue") }
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .disabled(saving)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(Theme.canvas)
        .onAppear {
            name = session.displayName ?? ""
            if let brand = session.brand?.name, brand != "My brand" { promoting = brand }
            focused = name.isEmpty
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

// MARK: - One question

/// The only question screen. Adding or reordering questions never touches this.
private struct OnboardingQuestionView: View {
    let question: OnboardingQuestion

    @Environment(AppSession.self) private var session

    private var chosen: Set<String> { session.onboardingAnswers[question.id] ?? [] }

    /// Two columns, the way email-app lays its options out. A wrapping field of
    /// chips packed tighter and read worse: the eye has no column to run down,
    /// so finding one option among twelve became a scan rather than a glance.
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                // No per-element stagger. email-app's question screen has none,
                // and the reason is not restraint for its own sake: a page that
                // crossfades in while its twelve tiles separately fade up is two
                // animations competing over the same half second, and the second
                // one is still arriving when somebody has already reached for a
                // tile. The page arrives as one thing.
                if question.isDetailed {
                    VStack(spacing: 10) {
                        ForEach(question.options) { option in
                            DetailedOption(option: option, isChosen: chosen.contains(option.id)) {
                                toggle(option)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(question.options) { option in
                            OptionTile(option: option, isChosen: chosen.contains(option.id)) {
                                toggle(option)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .scrollIndicators(.hidden)

            // Never disabled. A greyed-out button on the first screens of an app
            // nobody has committed to yet is a dead end wearing the clothes of a
            // control: nothing to tap and no way past a question you have no
            // answer to. Every one of these has a workable default, so skipping
            // costs a little quality and nothing else -- and saying "Skip" is
            // honest about that.
            Button { session.onboardingNext() } label: {
                Text(chosen.isEmpty ? "Skip" : "Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .contentTransition(.opacity)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .tint(chosen.isEmpty ? Color.secondary : Theme.accent)
            .controlSize(.large)
            .animation(.snappy(duration: 0.2), value: chosen.isEmpty)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = session.onboarding.progress {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                    .padding(.bottom, 2)
                    // The bar animating between steps is the thing that makes
                    // six screens feel like one flow rather than six screens.
                    .animation(.snappy(duration: 0.4), value: progress)
            }

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
    }

    private func toggle(_ option: OnboardingQuestion.Option) {
        withAnimation(.snappy(duration: 0.18)) {
            session.onboardingToggle(option, in: question)
        }
    }
}

// MARK: - Option chrome

/// A tile in the two-column grid: symbol above label.
private struct OptionTile: View {
    let option: OnboardingQuestion.Option
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: option.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 26, alignment: .leading)

                Text(option.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(isChosen ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Theme.surface))
                    .overlay(shape.strokeBorder(isChosen ? Theme.accent : .clear, lineWidth: 1.5))
            }
            // A small settle on pick, so choosing feels like it landed.
            .scaleEffect(isChosen ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}

/// A row for options that carry a description.
private struct DetailedOption: View {
    let option: OnboardingQuestion.Option
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isChosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.primary)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? Theme.accent : Color(.tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(isChosen ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Theme.surface))
                    .overlay(shape.strokeBorder(isChosen ? Theme.accent : .clear, lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}
