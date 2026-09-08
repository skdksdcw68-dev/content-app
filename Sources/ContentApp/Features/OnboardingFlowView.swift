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
                OnboardingQuestionView(question: OnboardingQuestion.all[index])
            } else {
                OnboardingConnect(kind: .account)
            }

        case .connectAccount:
            OnboardingConnect(kind: .account)

        case .connectGenerator:
            OnboardingConnect(kind: .generator)

        case .done:
            Color.clear
        }
    }
}

// MARK: - Welcome

private struct OnboardingWelcome: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // The artwork already in the bundle rather than a new asset. It is
            // the same picture the carousel uses for planning, which is the
            // thing this screen is promising.
            OnboardingArt(name: "promo-plan")
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("You built something.\nLet's tell people about it.")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)

                Text("Autocast writes your posts, makes the videos, and puts them out on time. You say yes; it does the rest.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 32)

            Spacer(minLength: 24)

            Button { session.onboardingNext() } label: {
                Text("Get started")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Theme.canvas)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The picture, or a soft stand-in when the file is not in the bundle.
private struct OnboardingArt: View {
    let name: String

    var body: some View {
        Group {
            if let art = UIImage(named: name) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
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
                    ChipField(
                        options: question.options,
                        chosen: chosen,
                        toggle: toggle
                    )
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
            }
            .buttonStyle(.borderedProminent)
            .tint(chosen.isEmpty ? Color.secondary : Theme.accent)
            .controlSize(.large)
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
            }

            Text(question.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            Text(question.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// Chips that wrap, because the labels are of wildly different lengths and a
/// two-column grid would leave "An app" occupying the same box as "Software
/// people pay for".
private struct ChipField: View {
    let options: [OnboardingQuestion.Option]
    let chosen: Set<String>
    let toggle: (OnboardingQuestion.Option) -> Void

    var body: some View {
        // The system's own flow layout. Hand-rolling wrapping with
        // GeometryReader is the classic way to end up with something that
        // breaks at one Dynamic Type size and nobody notices for a month.
        FlowLayout(spacing: 10) {
            ForEach(options) { option in
                Button { toggle(option) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: option.symbol)
                            .font(.caption.weight(.semibold))
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(chosen.contains(option.id) ? Theme.onAccent : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        chosen.contains(option.id) ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen.contains(option.id) ? [.isSelected, .isButton] : .isButton)
            }
        }
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
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(Theme.surface)
                    .overlay(shape.strokeBorder(isChosen ? Theme.accent : .clear, lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}
