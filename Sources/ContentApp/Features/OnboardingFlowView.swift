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
                // Forward slides in from the right, back from the left, and the
                // outgoing screen leaves the way it came. Without the direction
                // the two feel identical and the flow stops having a shape.
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.snappy(duration: 0.3), value: session.onboarding)
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
                OnboardingQuestionView(question: OnboardingQuestion.all[index])
                    // Keyed by question, so moving between two of them is a
                    // real insertion and removal rather than SwiftUI quietly
                    // reusing the same view and changing its text.
                    .id(OnboardingQuestion.all[index].id)
            } else {
                OnboardingConnect(kind: .account)
            }

        case .connectAccount:
            OnboardingConnect(kind: .account).id("account")

        case .connectGenerator:
            OnboardingConnect(kind: .generator).id("generator")

        case .done:
            Color.clear
        }
    }
}

// MARK: - Entrance

/// Fades and lifts its content into place, after a delay.
///
/// The pattern email-app uses on its splash: state flipped in `onAppear` inside
/// `withAnimation`, staggered with `.delay`. Wrapped up here because a screen
/// with four staggered pieces would otherwise be four copies of the same three
/// lines, and they would drift apart.
private struct Entrance<Content: View>: View {
    var delay: Double = 0
    @ViewBuilder var content: Content

    @State private var shown = false

    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45).delay(delay)) { shown = true }
            }
    }
}

// MARK: - Welcome

private struct OnboardingWelcome: View {
    @Environment(AppSession.self) private var session

    @State private var floating = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Entrance {
                OnboardingArt(name: "welcome-hero", fallback: "promo-plan")
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    // A slow drift, so the screen is alive without asking for
                    // attention. Two and a half seconds each way is below the
                    // speed anything reads as animation.
                    .offset(y: floating ? -8 : 8)
                    .animation(
                        .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                        value: floating
                    )
                    .onAppear { floating = true }
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                Entrance(delay: 0.15) {
                    Text("You built something.\nLet's tell people about it.")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Entrance(delay: 0.28) {
                    Text("Autocast writes your posts, makes the videos, and puts them out on time. You say yes; it does the rest.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)

            Spacer(minLength: 24)

            Entrance(delay: 0.4) {
                Button { session.onboardingNext() } label: {
                    Text("Get started")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
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
                if question.isDetailed {
                    VStack(spacing: 10) {
                        ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                            Entrance(delay: 0.10 + Double(index) * 0.05) {
                                DetailedOption(option: option, isChosen: chosen.contains(option.id)) {
                                    toggle(option)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                            // Staggered by position, capped so the twelfth tile
                            // is not still arriving after somebody has already
                            // reached for it.
                            Entrance(delay: min(0.10 + Double(index) * 0.03, 0.4)) {
                                OptionTile(option: option, isChosen: chosen.contains(option.id)) {
                                    toggle(option)
                                }
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
            .buttonStyle(.borderedProminent)
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

            Entrance {
                Text(question.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Entrance(delay: 0.06) {
                Text(question.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
