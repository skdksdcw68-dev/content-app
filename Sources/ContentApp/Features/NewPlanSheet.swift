import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Planning a month, as a flow.
///
/// It used to be one Form with every decision stacked in it -- import, brief,
/// length, frequency, a warning, a button -- and it read like a settings page
/// for the single most interesting thing the app does. Abel, 22 Sep 2026:
/// "plan a month thing, bro it needs actual a lots of screens not just one."
///
/// So it is onboarding's shape: one decision a screen, one progress bar and one
/// back chevron at the top, single choices advancing themselves. Nothing new is
/// asked -- the same four things go to the server -- but each one gets the room
/// to explain itself, and the last screen shows the month before it is written.
struct NewPlanSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Where in the flow. `route` is the writing path; the importing path
    /// branches off `.start` and never rejoins it.
    private enum Step: Hashable {
        case start
        case about, focus, length, cadence, destinations, knows, review
        case bring, paste

        /// How far along the writing path, for the one bar at the top. The
        /// import path has no bar: it is two taps, not a run of questions.
        var progress: Double? {
            switch self {
            case .about:        1.0 / 7
            case .focus:        2.0 / 7
            case .length:       3.0 / 7
            case .cadence:      4.0 / 7
            case .destinations: 5.0 / 7
            case .knows:        6.0 / 7
            case .review:       1
            default:            nil
            }
        }
    }

    @State private var step: Step = .start

    /// Prefilled from whatever was typed in Chat, so pressing "Plan a month"
    /// after writing a sentence does not throw the sentence away.
    @State private var brief: String

    @State private var focus: PlanFocus?
    @State private var days = 30
    @State private var postsPerDay = 1
    /// Where the posts go. Asked in the plan, not assumed (Abel, 23 Sep 2026:
    /// "make sure to ask the user where to post right after the plan").
    @State private var destinations: Set<String> = []
    @State private var showingPaywall = false

    @State private var pasted = ""
    @State private var showingFilePicker = false
    @State private var importing = false
    @State private var showingImportError = false
    @State private var importError = ""

    /// The longest plan this person's plan writes (the server enforces it too).
    private var maxDays: Int { session.subscription?.limits.planDays ?? 30 }

    /// Called with the proposal once it exists, so the caller can push the
    /// preview. The sheet does not navigate; it reports.
    let onProposed: (PlanProposal) -> Void

    /// Written out rather than left to the memberwise initialiser, which is
    /// private the moment a stored property is -- and every @State here is.
    init(brief: String, onProposed: @escaping (PlanProposal) -> Void) {
        _brief = State(initialValue: brief)
        self.onProposed = onProposed
    }

    /// Everything the planner may treat as true: the brand description, the
    /// brief typed here, and each remembered fact.
    private var knownFacts: Int {
        var count = session.facts.count
        if session.brand?.niche.isEmpty == false { count += 1 }
        if session.brand?.audience.isEmpty == false { count += 1 }
        if !brief.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        return count
    }

    private var total: Int { days * postsPerDay }

    private var typedBrief: String {
        brief.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var knowsTitle: String {
        knownFacts < 4 ? "It doesn’t know much about you yet" : "Here’s what it goes on"
    }

    private var knowsSubtitle: String {
        if knownFacts < 4 {
            return "It will not invent anything, so with little to go on it writes in general terms. Four or five things makes a visible difference."
        }
        return "\(knownFacts) things about your account. Everything it writes comes from these."
    }

    private var lengthOptions: [OnboardingQuestion.Option] {
        var out: [OnboardingQuestion.Option] = []
        for length in PlanLength.allCases {
            let detail: String = length.days > maxDays ? "Part of Autocast Pro" : length.detail
            out.append(OnboardingQuestion.Option(
                id: String(length.days),
                label: length.label,
                symbol: length.symbol,
                detail: detail
            ))
        }
        return out
    }

    private var cadenceOptions: [OnboardingQuestion.Option] {
        var out: [OnboardingQuestion.Option] = []
        for n in 1...3 {
            let label: String = n == 1 ? "One a day" : "\(n) a day"
            let detail: String = "\(days * n) posts in \(days) days"
            out.append(OnboardingQuestion.Option(
                id: String(n),
                label: label,
                symbol: "\(n).circle",
                detail: detail
            ))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 🔴 One bar for the whole flow, as onboarding does it. Drawn
                // inside each screen it crossfades between them instead of
                // sliding forward.
                if let progress = step.progress {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .animation(.snappy(duration: 0.4), value: progress)
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .start {
                        Button { back() } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                        .disabled(session.isPlanning)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if step == .start {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: step)
            // The wait, as onboarding's building screen: the whole sheet, not a
            // spinner in a row nobody is looking at.
            .overlay {
                if session.isPlanning {
                    BuildingLoader(
                        title: importing ? "Reading your plan" : "Writing \(total) posts",
                        detail: importing
                            ? "Finding every post in it and laying them onto days. Nothing is changed or added."
                            : "It writes ten at a time so the last ones are as good as the first. This takes a few seconds."
                    )
                    .background(Color(uiColor: .systemBackground))
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.25), value: session.isPlanning)
            .interactiveDismissDisabled(session.isPlanning)
            .task {
                await session.refreshFacts()
                // Start on the longest plan this account can write.
                if days > maxDays { days = maxDays }
            }
            // Presented from here: this is already a sheet, and the root's
            // paywall cannot appear on top of it.
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: Self.importTypes
            ) { result in
                if case .success(let url) = result {
                    Task { await importPlan(file: url) }
                }
            }
            .alert("Couldn't import that", isPresented: $showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError)
            }
        }
    }

    private var title: String {
        switch step {
        case .start:  "Plan a month"
        case .bring:  "Bring your own"
        case .paste:  "Paste a plan"
        case .review: "Ready"
        default:      ""
        }
    }

    // MARK: - The screens

    @ViewBuilder
    private var content: some View {
        switch step {
        case .start:   start
        case .about:   about
        case .focus:   focusStep
        case .length:  length
        case .cadence:      cadence
        case .destinations: whereTo
        case .knows:        knows
        case .review:       review
        case .bring:        bring
        case .paste:
            PastePlanView(text: $pasted) {
                Task { await importPlan(text: pasted) }
            }
        }
    }

    /// The fork. Two ways to get a month, said in full sentences, because the
    /// import path used to be a small row at the top of a form and almost
    /// nobody found it.
    private var start: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            OnboardingArt(name: "plan-hero", fallback: "hero-plan")
                .frame(maxWidth: .infinity, maxHeight: 200)
                .padding(.horizontal, 30)

            Text("A month of posts, on a calendar")
                .font(.system(size: 27, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)
                .padding(.top, 24)

            Text("Nothing is scheduled and nothing is posted until you have read it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 8)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                PlanChoiceRow(
                    symbol: "wand.and.stars",
                    title: "Write it for me",
                    detail: "A few questions, then it writes every post."
                ) { step = .about }

                PlanChoiceRow(
                    symbol: "doc.badge.plus",
                    title: "I already have one",
                    detail: "Import a file, or paste one from anywhere."
                ) { step = .bring }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    /// The brief. One big field and nothing else on the screen, because this is
    /// the only thing on this path the planner cannot get from the account.
    private var about: some View {
        PlanStep(
            title: "What are these weeks about?",
            subtitle: "Anything specific — a launch, a price change, a season. Your account description and themes are used either way.",
            button: typedBrief.isEmpty ? "Nothing special" : "Continue",
            tint: typedBrief.isEmpty ? Color.secondary : Theme.accent,
            action: { step = .focus }
        ) {
            TextField("We’re launching the redesign on the 14th…", text: $brief, axis: .vertical)
                .font(.body)
                .lineLimit(5...12)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 20)
        }
    }

    /// What the month is for. It goes into the brief as a sentence -- it is not
    /// a setting and does not pretend to be one.
    private var focusStep: some View {
        PlanChoiceStep(
            title: "What should this month do?",
            subtitle: "It steers the hooks and the calls to action.",
            options: PlanFocus.allCases.map(\.option),
            chosen: focus?.rawValue
        ) { id in
            focus = PlanFocus(rawValue: id)
            step = .length
        }
    }

    private var length: some View {
        PlanChoiceStep(
            title: "How long?",
            subtitle: "You can plan again whenever you like.",
            options: lengthOptions,
            chosen: String(days),
            locked: { Int($0).map { $0 > maxDays } ?? false },
            onLocked: { showingPaywall = true }
        ) { id in
            days = Int(id) ?? 30
            step = .cadence
        }
    }

    private var cadence: some View {
        PlanChoiceStep(
            title: "How often?",
            subtitle: "Spread across the hours you have not marked quiet.",
            options: cadenceOptions,
            chosen: String(postsPerDay)
        ) { id in
            postsPerDay = Int(id) ?? 1
            // Starts from what is connected; anything can be added.
            if destinations.isEmpty {
                destinations = Set(session.connections.map { $0.platform.rawValue })
                if destinations.isEmpty { destinations = [Platform.tiktok.rawValue] }
            }
            step = .destinations
        }
    }

    /// Which accounts the month posts to. Every platform is offered; the ones
    /// not connected yet say so, and can still be chosen -- connecting is a
    /// tap in You → Accounts, and a plan should not have to wait for it.
    private var whereTo: some View {
        PlanStep(
            title: "Where should these go?",
            subtitle: "Pick every account the month posts to. Each post is prepared for each one.",
            button: destinations.isEmpty ? "Pick at least one" : "Continue",
            tint: destinations.isEmpty ? Color.secondary : Theme.accent,
            action: { if !destinations.isEmpty { step = .knows } }
        ) {
            VStack(spacing: 10) {
                ForEach(Platform.allCases) { platform in
                    let connected = session.connection(for: platform) != nil
                    DetailedOption(
                        option: OnboardingQuestion.Option(
                            id: platform.rawValue,
                            label: "\(platform.networkName) · \(platform.displayName)",
                            symbol: platform.symbolName,
                            detail: connected
                                ? "Connected"
                                : "Not connected yet — connect it in You → Accounts before the first post"
                        ),
                        isChosen: destinations.contains(platform.rawValue)
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            if destinations.contains(platform.rawValue) {
                                destinations.remove(platform.rawValue)
                            } else {
                                destinations.insert(platform.rawValue)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// The single biggest lever on whether the month is worth posting, and the
    /// one nobody would guess. The planner is forbidden from inventing
    /// specifics, so with nothing to draw on it writes "here is what went into
    /// it this week" -- true, and worth nothing. With five facts it writes "no
    /// badges, no streaks: here is the reason".
    private var knows: some View {
        PlanStep(
            title: knowsTitle,
            subtitle: knowsSubtitle,
            button: "Continue",
            action: { step = .review }
        ) {
            VStack(spacing: 10) {
                PlanFactRow(
                    label: "What you’re promoting",
                    value: session.brand?.niche ?? "",
                    fallback: "Not set"
                )
                PlanFactRow(
                    label: "Who it’s for",
                    value: session.brand?.audience ?? "",
                    fallback: "Not set"
                )
                PlanFactRow(
                    label: "Things it remembers",
                    value: session.facts.isEmpty ? "" : "\(session.facts.count)",
                    fallback: "None yet"
                )

                NavigationLink {
                    BrandView().pushedPage()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(Theme.accent)
                        Text(knownFacts < 4 ? "Tell it more about you" : "Edit what it knows")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
    }

    /// The month before it exists: every number that is about to be sent, and
    /// the one warning that matters.
    private var review: some View {
        PlanStep(
            title: "\(total) posts, \(days) days",
            subtitle: "Starting today. You read all of it before anything is scheduled.",
            button: "Write the plan",
            isBusy: session.isPlanning,
            action: { Task { await propose() } }
        ) {
            VStack(spacing: 10) {
                PlanSummaryRow(symbol: "calendar", label: "How long", value: PlanLength.label(for: days))
                PlanSummaryRow(symbol: "square.stack", label: "How often", value: postsPerDay == 1 ? "One a day" : "\(postsPerDay) a day")
                if let focus {
                    PlanSummaryRow(symbol: focus.option.symbol, label: "Goal", value: focus.option.label)
                }
                if !typedBrief.isEmpty {
                    PlanSummaryRow(symbol: "text.alignleft", label: "About", value: typedBrief)
                }

                if let existing = session.plan, existing.isProposal {
                    Label(
                        "You already have a plan waiting. Writing this one replaces it.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                Text("It writes ten at a time so the later ones are not worse than the early ones. This takes a few seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
        }
    }

    /// The import path's own screen, rather than a row at the top of a form.
    private var bring: some View {
        PlanStep(
            title: "Bring a plan you already have",
            subtitle: "Days, dates, times, hooks, captions and scripts are all picked up. Anything that isn’t a post — goals, tips — is left out.",
            button: nil
        ) {
            VStack(spacing: 10) {
                PlanChoiceRow(
                    symbol: "doc.badge.plus",
                    title: "Import a file",
                    detail: "DOCX, PDF, ZIP or text."
                ) { showingFilePicker = true }

                PlanChoiceRow(
                    symbol: "doc.on.clipboard",
                    title: "Paste a plan",
                    detail: "From ChatGPT, Notes, an email — anywhere."
                ) { step = .paste }

                Text("Your posts are kept exactly as written and laid onto days for you to check.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Moving

    private func back() {
        withAnimation(.snappy(duration: 0.25)) {
            switch step {
            case .about:   step = .start
            case .focus:   step = .about
            case .length:  step = .focus
            case .cadence:      step = .length
            case .destinations: step = .cadence
            case .knows:        step = .destinations
            case .review:       step = .knows
            case .bring:   step = .start
            case .paste:   step = .bring
            case .start:   break
            }
        }
    }

    // MARK: - Sending

    static let importTypes: [UTType] = [
        .pdf, .zip, .plainText, .text, .html, .commaSeparatedText, .rtf,
        UTType(filenameExtension: "docx"),
        UTType(filenameExtension: "md"),
    ].compactMap { $0 }

    private func importPlan(file: URL? = nil, text: String? = nil) async {
        importing = true
        defer { importing = false }
        session.lastError = nil
        guard let proposal = await session.importPlan(file: file, text: text) else {
            // Shown here, over the sheet; the app-wide alert sits behind it.
            importError = session.lastError ?? "Something went wrong. Try again."
            session.lastError = nil
            showingImportError = true
            return
        }
        onProposed(proposal)
        dismiss()
    }

    /// The typed brief and the chosen goal, joined. The goal is a sentence in
    /// the brief and nothing more -- there is no goal field on the server, and
    /// pretending otherwise would be inventing a feature.
    private var composedBrief: String {
        var parts: [String] = []
        let typed = typedBrief
        if !typed.isEmpty { parts.append(typed) }
        if let focus { parts.append(focus.sentence) }
        return parts.joined(separator: "\n")
    }

    private func propose() async {
        guard let proposal = await session.proposePlan(
            brief: composedBrief,
            days: days,
            postsPerDay: postsPerDay,
            platforms: Array(destinations).sorted()
        ) else { return }

        // Reported before dismissing, so the caller can act on it once the
        // sheet has finished going away. Pushing a screen in the same tick as a
        // dismiss loses the push often enough to look like a dead button.
        onProposed(proposal)
        dismiss()
    }
}

// MARK: - What the month is for

/// Four goals, each one a sentence added to the brief. Deliberately not a
/// setting: the planner reads prose, so this is prose.
private enum PlanFocus: String, CaseIterable {
    case reach, trial, consistency, launch

    var option: OnboardingQuestion.Option {
        switch self {
        case .reach:
            .init(id: rawValue, label: "Reach new people", symbol: "globe",
                  detail: "Hooks written for people who have never heard of you.")
        case .trial:
            .init(id: rawValue, label: "Get people to try it", symbol: "arrow.down.app",
                  detail: "Every post ends by asking for the download or the sign-up.")
        case .consistency:
            .init(id: rawValue, label: "Just stay consistent", symbol: "repeat",
                  detail: "A steady mix across your themes, nothing pushed hard.")
        case .launch:
            .init(id: rawValue, label: "Build up to a launch", symbol: "flag.checkered",
                  detail: "The weeks lead somewhere, ending on the thing you’re shipping.")
        }
    }

    /// What is actually sent. Plain, and claiming nothing that is not true.
    var sentence: String {
        switch self {
        case .reach:       "The goal for these weeks is reaching people who have not heard of us before."
        case .trial:       "The goal for these weeks is getting people to try it — end posts by asking for that."
        case .consistency: "The goal for these weeks is staying consistent across our usual themes."
        case .launch:      "These weeks build up to a launch; the last posts should land on it."
        }
    }
}

private enum PlanLength: CaseIterable {
    case week, fortnight, month

    var days: Int {
        switch self {
        case .week:      7
        case .fortnight: 14
        case .month:     30
        }
    }

    var label: String {
        switch self {
        case .week:      "A week"
        case .fortnight: "Two weeks"
        case .month:     "A month"
        }
    }

    var symbol: String {
        switch self {
        case .week:      "calendar.day.timeline.left"
        case .fortnight: "calendar.badge.clock"
        case .month:     "calendar"
        }
    }

    var detail: String {
        switch self {
        case .week:      "7 days. Good for trying it out."
        case .fortnight: "14 days."
        case .month:     "30 days, the whole run."
        }
    }

    static func label(for days: Int) -> String {
        allCases.first { $0.days == days }?.label ?? "\(days) days"
    }
}

// MARK: - The screen shapes

/// A screen in the flow: title, subtitle, whatever it asks, and at most one
/// button pinned to the bottom.
private struct PlanStep<Content: View>: View {
    let title: String
    let subtitle: String
    var button: String?
    var tint: Color = Theme.accent
    var isBusy = false
    var action: () -> Void = {}
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            ScrollView {
                content()
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            if let button {
                OnboardingButton(title: button, tint: tint, isBusy: isBusy, action: action)
                    .padding(.top, 10)
            }
        }
    }
}

/// A screen that is only a question. Single choice, so tapping an answer is the
/// answer and the flow moves on by itself -- the rule onboarding already
/// follows (Abel, 21 Sep 2026: "after choosing why do they have to choose a
/// button?").
private struct PlanChoiceStep: View {
    let title: String
    let subtitle: String
    let options: [OnboardingQuestion.Option]
    var chosen: String?
    var locked: (String) -> Bool = { _ in false }
    var onLocked: () -> Void = {}
    let choose: (String) -> Void

    /// Long enough for the pick to be seen: the selection animation is 0.18s
    /// and the page change 0.25s.
    private let settle: Duration = .milliseconds(400)

    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(options) { option in
                        DetailedOption(option: option, isChosen: (picked ?? chosen) == option.id) {
                            tap(option)
                        }
                        // Over the tick, not beside it: a locked row has no
                        // tick to show, and a lock in its place says why.
                        .overlay(alignment: .bottomTrailing) {
                            if locked(option.id) {
                                Image(systemName: "lock.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(14)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { picked = chosen }
    }

    private func tap(_ option: OnboardingQuestion.Option) {
        guard !locked(option.id) else {
            onLocked()
            return
        }
        withAnimation(.snappy(duration: 0.18)) { picked = option.id }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let id = option.id
        Task {
            try? await Task.sleep(for: settle)
            choose(id)
        }
    }
}

/// A big tappable row: a symbol, a title and a line under it.
private struct PlanChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
    }
}

/// One thing the planner has, or a plain note that it does not.
private struct PlanFactRow: View {
    let label: String
    let value: String
    let fallback: String

    private var isMissing: Bool { value.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isMissing ? "circle.dashed" : "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(isMissing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(isMissing ? fallback : value)
                    .font(.subheadline)
                    .foregroundStyle(isMissing ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PlanSummaryRow: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Paste a plan from anywhere -- ChatGPT, Notes, an email -- in one box, with
/// the paste button and the import button inside it.
private struct PastePlanView: View {
    @Binding var text: String
    let onImport: () -> Void

    @Environment(AppSession.self) private var session
    @FocusState private var focused: Bool

    private var ready: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 30
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Day 1 — Hook: …\nDay 2 — Hook: …", text: $text, axis: .vertical)
                        .lineLimit(12...30)
                        .focused($focused)

                    HStack(spacing: 8) {
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { text = first }
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.titleAndIcon)
                        .tint(Color.secondary)

                        if !text.isEmpty {
                            Button("Clear") { text = "" }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Button(action: onImport) {
                            Label("Import", systemImage: "arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ready ? Theme.onAccent : Color.secondary)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(Capsule().fill(ready ? Color.accentColor : Color.raised))
                        }
                        .buttonStyle(PressButtonStyle())
                        .disabled(!ready || session.isPlanning)
                    }
                }
                .padding(14)
                .background(Color.track, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Days, dates, times, hooks, captions and scripts are all picked up. Anything that isn’t a post — goals, tips — is left out.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Style.gutter)
        }
        .background(Color.canvas.ignoresSafeArea())
        .onAppear { focused = text.isEmpty }
    }
}
