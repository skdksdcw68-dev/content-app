import SwiftUI

/// The Brand questions, one screen at a time, the way onboarding asks them.
///
/// Abel, 23 Sep 2026: "the You page is good, but I wish the brand thing is
/// like onboarding." The Brand page stays as the form for editing one thing;
/// this is the run-through -- a bar at the top, one question per screen, a
/// single choice moves on by itself, a multiple choice has Continue or Skip,
/// and the answers are written once at the end into the same profile the
/// form edits.
struct BrandFlowView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    private let questions: [OnboardingQuestion] =
        BrandQuestions.audienceGroup + BrandQuestions.contentGroup + [BrandQuestions.voice] + BrandQuestions.writingGroup

    @State private var index = 0
    @State private var choices: [String: Set<String>] = [:]
    @State private var saving = false

    private let settle: Duration = .milliseconds(400)
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var question: OnboardingQuestion { questions[min(index, questions.count - 1)] }
    private var chosen: Set<String> { choices[question.id] ?? [] }
    private var progress: Double { Double(index + 1) / Double(questions.count + 1) }
    private var isLast: Bool { index == questions.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .animation(.snappy(duration: 0.4), value: progress)

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

                if question.selection == .multiple || isLast {
                    Button {
                        advance()
                    } label: {
                        Group {
                            if saving {
                                ProgressView().tint(Theme.onAccent)
                            } else {
                                Text(isLast ? "Save" : (chosen.isEmpty ? "Skip" : "Continue"))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(RemiFilledButtonStyle())
                    .controlSize(.large)
                    .disabled(saving)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas)
            .navigationTitle("Your brand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if index > 0 {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { index -= 1 }
                        } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
            }
            .animation(.snappy(duration: 0.25), value: index)
            .onAppear(perform: load)
            .interactiveDismissDisabled(saving)
        }
    }

    // MARK: - Moving through

    private func tap(_ option: OnboardingQuestion.Option) {
        withAnimation(.snappy(duration: 0.18)) {
            var set = chosen
            if question.selection == .single {
                set = set.contains(option.id) ? [] : [option.id]
            } else if set.contains(option.id) {
                set.remove(option.id)
            } else {
                set.insert(option.id)
            }
            choices[question.id] = set
        }
        guard question.selection == .single, !isLast else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let answered = index
        Task {
            try? await Task.sleep(for: settle)
            // Only if this is still the question on screen: a second tap in
            // the settle, or Back, must not skip one.
            if index == answered { advance() }
        }
    }

    private func advance() {
        if isLast {
            Task { await save() }
        } else {
            withAnimation(.snappy(duration: 0.25)) { index += 1 }
        }
    }

    // MARK: - Load and save

    private func load() {
        let profile = session.brand?.profile ?? [:]
        var picked: [String: Set<String>] = [:]
        for question in questions {
            let answers = Set(profile[question.id]?.answers ?? [])
            picked[question.id] = Set(question.options.filter { answers.contains($0.label) }.map(\.id))
        }
        choices = picked
    }

    private func save() async {
        guard let brand = session.brand else { return }
        saving = true
        defer { saving = false }

        // Into the profile the form edits, keeping what it already holds --
        // the typed answers, and anything not asked here.
        var profile = brand.profile ?? [:]
        for question in questions {
            let set = choices[question.id] ?? []
            let picked = question.options.filter { set.contains($0.id) }.map(\.label)
            if picked.isEmpty {
                profile.removeValue(forKey: question.id)
            } else {
                profile[question.id] = BrandAnswer(title: question.title, answers: picked)
            }
        }

        let voice = BrandQuestions.voice.options.first { (choices["voice"] ?? []).contains($0.id) }
        let tone = voice.map { "\($0.label). \($0.detail ?? "")".trimmingCharacters(in: .whitespaces) }

        if await session.saveBrandProfile(name: brand.name, niche: brand.niche, audience: brand.audience, profile: profile, tone: tone) {
            dismiss()
        }
    }
}
