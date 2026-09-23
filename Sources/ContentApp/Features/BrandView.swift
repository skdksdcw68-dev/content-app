import SwiftUI

/// What Autocast knows about your brand, and how you want it to sound.
///
/// Three sentences first -- the name, what it is, who it's for -- because the
/// planner writes from those. Then the questionnaire, one native picker per
/// question (Abel, 19 Sep 2026: "it should have a lots of selections and
/// questions, like onboarding"), saved to `brands.profile`. Then the facts,
/// each removable.
///
/// Everything saves together, from Save or on leaving the page.
struct BrandView: View {
    @Environment(AppSession.self) private var session

    @State private var name = ""
    @State private var niche = ""
    @State private var audience = ""
    /// Chosen option ids, by question id.
    @State private var choices: [String: Set<String>] = [:]
    /// Free-text answers, by question id.
    @State private var texts: [String: String] = [:]
    @State private var saved: Snapshot?
    @State private var saving = false
    /// The questions as a run-through, onboarding's way.
    @State private var runningQuestions = false

    private struct Snapshot: Equatable {
        var name: String
        var niche: String
        var audience: String
        var choices: [String: Set<String>]
        var texts: [String: String]
    }

    private var current: Snapshot {
        Snapshot(name: name, niche: niche, audience: audience, choices: choices, texts: texts)
    }

    private var dirty: Bool { saved != nil && saved != current }

    var body: some View {
        Form {
            // The whole questionnaire as screens, one question at a time --
            // Abel, 23 Sep 2026: "I wish the brand thing is like onboarding."
            // The rows below stay for changing one answer.
            Section {
                Button {
                    runningQuestions = true
                } label: {
                    SettingsRow("Go through the questions", symbol: "list.bullet.rectangle", accessory: .chevron)
                }
            } footer: {
                Text("Every question, one screen at a time. Your current answers are already filled in.")
            }

            Section {
                TextField("Name", text: $name)
                TextField("What it is, in a sentence or two", text: $niche, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Who it’s for", text: $audience, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("About")
            } footer: {
                Text("\"A journaling app that asks you one question a day\" beats \"productivity\". It writes only from what’s true here.")
            }

            Section("Audience and goal") {
                ForEach(BrandQuestions.audienceGroup) { question in
                    questionRow(question)
                }
            }

            Section("Content") {
                ForEach(BrandQuestions.contentGroup) { question in
                    questionRow(question)
                }
            }

            Section("Writing") {
                questionRow(BrandQuestions.voice)
                ForEach(BrandQuestions.writingGroup) { question in
                    questionRow(question)
                }
            }

            Section {
                ForEach(BrandQuestions.texts) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField(question.placeholder, text: Binding(
                            get: { texts[question.id] ?? "" },
                            set: { texts[question.id] = $0 }
                        ), axis: .vertical)
                        .lineLimit(1...4)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Words")
            }

            Section {
                NavigationLink { FactsView() } label: {
                    SettingsValueLabel("What it should know", symbol: "checklist",
                                       value: session.facts.isEmpty ? "None yet" : "\(session.facts.count)")
                }
            } footer: {
                Text("Facts are the only specifics it will ever state: features, prices, numbers. Add what’s true and it gets specific.")
            }
        }
        .fullScreenCover(isPresented: $runningQuestions, onDismiss: load) {
            BrandFlowView()
        }
        .navigationTitle("Brand")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(!dirty || saving)
            }
        }
        .pushedPage()
        .task {
            guard saved == nil else { return }
            load()
            await session.refreshFacts()
        }
        .onDisappear {
            // Leaving is saving: a page of forty choices should never be lost
            // to a back swipe.
            if dirty { Task { await save() } }
        }
    }

    // MARK: - Rows

    private func questionRow(_ question: OnboardingQuestion) -> some View {
        NavigationLink {
            QuestionPicker(question: question, chosen: Binding(
                get: { choices[question.id] ?? [] },
                set: { choices[question.id] = $0 }
            ))
        } label: {
            SettingsValueLabel(question.title, symbol: symbol(for: question.id), value: summary(question))
        }
    }

    private func summary(_ question: OnboardingQuestion) -> String {
        let picked = labels(question)
        switch picked.count {
        case 0: return "Not set"
        case 1: return picked[0]
        default: return "\(picked[0]) +\(picked.count - 1)"
        }
    }

    private func labels(_ question: OnboardingQuestion) -> [String] {
        let chosen = choices[question.id] ?? []
        return question.options.filter { chosen.contains($0.id) }.map(\.label)
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "category": "shippingbox"
        case "goal": "target"
        case "audience": "person.2"
        case "ages": "calendar"
        case "styles": "film.stack"
        case "formats": "video"
        case "length": "timer"
        case "voice": "quote.bubble"
        case "cta": "hand.tap"
        case "emoji": "face.smiling"
        case "hashtags": "number"
        case "language": "globe"
        default: "circle"
        }
    }

    // MARK: - Load and save

    private static var allQuestions: [OnboardingQuestion] {
        BrandQuestions.audienceGroup + BrandQuestions.contentGroup + [BrandQuestions.voice] + BrandQuestions.writingGroup
    }

    private func load() {
        let brand = session.brand
        name = brand?.name ?? ""
        niche = brand?.niche ?? ""
        audience = brand?.audience ?? ""
        let profile = brand?.profile ?? [:]
        var picked: [String: Set<String>] = [:]
        for question in Self.allQuestions {
            let answers = Set(profile[question.id]?.answers ?? [])
            picked[question.id] = Set(question.options.filter { answers.contains($0.label) }.map(\.id))
        }
        choices = picked
        var written: [String: String] = [:]
        for question in BrandQuestions.texts {
            written[question.id] = profile[question.id]?.answers.first ?? ""
        }
        texts = written
        saved = current
    }

    private func save() async {
        saving = true
        defer { saving = false }

        var profile: [String: BrandAnswer] = [:]
        for question in Self.allQuestions {
            let picked = labels(question)
            if !picked.isEmpty { profile[question.id] = BrandAnswer(title: question.title, answers: picked) }
        }
        for question in BrandQuestions.texts {
            let text = (texts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { profile[question.id] = BrandAnswer(title: question.title, answers: [text]) }
        }

        // The planner reads the voice from brand_settings.tone, written the
        // way onboarding writes it.
        let voice = BrandQuestions.voice.options.first { (choices["voice"] ?? []).contains($0.id) }
        let tone = voice.map { "\($0.label). \($0.detail ?? "")".trimmingCharacters(in: .whitespaces) }

        let snapshot = current
        if await session.saveBrandProfile(name: name, niche: niche, audience: audience, profile: profile, tone: tone) {
            saved = snapshot
        }
    }
}

/// One question, as a native list: a tick for what is chosen.
struct QuestionPicker: View {
    let question: OnboardingQuestion
    @Binding var chosen: Set<String>

    var body: some View {
        List {
            Section {
                ForEach(question.options) { option in
                    Button {
                        toggle(option.id)
                    } label: {
                        HStack(spacing: 8) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(Color.primary)
                                    if let detail = option.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                SettingsIcon(option.symbol)
                            }
                            Spacer(minLength: 0)
                            if chosen.contains(option.id) {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen.contains(option.id) ? .isSelected : [])
                }
            } footer: {
                Text(question.subtitle)
            }

            if !chosen.isEmpty {
                Section {
                    Button("Clear", role: .destructive) { chosen = [] }
                }
            }
        }
        .navigationTitle(question.title)
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
    }

    private func toggle(_ id: String) {
        if question.selection == .single {
            chosen = chosen.contains(id) ? [] : [id]
        } else if chosen.contains(id) {
            chosen.remove(id)
        } else {
            chosen.insert(id)
        }
    }
}

/// The facts, one per row. Delete with Edit, a swipe, or a long press.
struct FactsView: View {
    @Environment(AppSession.self) private var session
    @State private var newFact = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Something true about your brand", text: $newFact, axis: .vertical)
                        .lineLimit(1...3)
                    Button {
                        Task { await add() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty || session.isWorking)
                    .accessibilityLabel("Add")
                }
            } footer: {
                Text("One fact per line, like \"Free to download, with a paid plan\". It will never claim anything that isn’t here.")
            }

            if !session.facts.isEmpty {
                Section {
                    ForEach(session.facts) { fact in
                        Text(fact.fact)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await session.forget(fact.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in
                        let gone = offsets.map { session.facts[$0].id }
                        Task { for id in gone { await session.forget(id) } }
                    }
                }
            }
        }
        .navigationTitle("What it should know")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !session.facts.isEmpty {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .pushedPage()
        .task { await session.refreshFacts() }
    }

    private func add() async {
        let fact = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return }
        if await session.remember(fact) { newFact = "" }
    }
}
