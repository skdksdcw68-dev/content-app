import SwiftUI

/// Start a series: pick a style, say where it posts, how long each video is,
/// what every video must carry and must never do, and what it is all for --
/// then it writes the next post, makes its video, and asks for one tap.
///
/// Abel, 23 Sep 2026: "they choose the style... they will be asked to
/// connect TikTok, YouTube and IG... the duration, or they hit decide for
/// me... every day it will generate the content they chose and it posts."
/// Onboarding's shape: a bar at the top, one question per screen -- and he
/// asked for MORE of them on 24 Sep, because every answer here is something
/// the writer uses on every post.
///
/// ONE post at a time, not a month. Writing thirty up front spends on
/// twenty-nine nobody has seen, and nothing written before the first post
/// went out can learn from how it did. The next one is written once this one
/// is posted -- `AppSession.extendSeriesIfNeeded()`.
///
/// The one tap stays. TikTok's posting rules require the person to see and
/// confirm each post before it goes out through the API, so a series makes
/// the video and puts it in front of them ready; it does not post behind
/// their back.
struct SeriesFlowView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Where the series goes when it exists.
    let onStarted: (PlanProposal) -> Void

    private enum Step: Int, CaseIterable {
        // Abel, 24 Sep 2026: "on the start a serious page we need more
        // onboarding that requires users attention... even the video type
        // what it should include and what not, there is a lots." Every extra
        // screen here is something the writer actually uses, not a screen for
        // its own sake.
        //
        // And on 29 Sep 2026, the order he walked it in: pick the style, then
        // "it will ask me to connect at least one platform... I cannot
        // continue", then the seconds, then "the video style it wants with
        // pictures. I must put that", then "a voiceover. It must be a
        // requirement", then the rest ("I didn't say it all").
        case style, destinations, length, look, voice, language, include, logo, avoid, goal, review

        var progress: Double { Double(rawValue + 1) / Double(Step.allCases.count + 1) }

        var title: String {
            switch self {
            case .style:        "Pick a style"
            case .destinations: "Where it posts"
            case .length:       "How long"
            case .look:         "How it looks"
            case .voice:        "Voiceover"
            case .language:     "Language"
            case .include:      "Every video has"
            case .logo:         "Your logo"
            case .avoid:        "Never do this"
            case .goal:         "What it's for"
            case .review:       "Ready"
            }
        }
    }

    /// What every video in the series must carry. Even, like every other set
    /// of choices in the app.
    private static let includeQuestion = OnboardingQuestion(
        id: "series_include",
        title: "Every video has",
        subtitle: "Pick what each one must carry. It goes into every brief.",
        selection: .multiple,
        options: [
            .init(id: "hook", label: "A hook in the first second", symbol: "bolt"),
            .init(id: "captions", label: "Captions burned in", symbol: "captions.bubble"),
            // The voiceover is its own required step now, with the voice to
            // go with it; the list keeps eight so the grid stays even.
            .init(id: "text", label: "Big words on screen", symbol: "textformat.size"),
            .init(id: "music", label: "Music under it", symbol: "music.note"),
            .init(id: "cta", label: "A call to action at the end", symbol: "hand.point.up.left"),
            .init(id: "proof", label: "A number or proof", symbol: "checkmark.seal"),
            .init(id: "question", label: "A question to the viewer", symbol: "questionmark.bubble"),
            .init(id: "logo", label: "Your name or logo", symbol: "tag"),
        ]
    )

    /// What it must never do. Separate from the brand-wide answer because a
    /// series can be stricter than the account.
    private static let avoidQuestion = OnboardingQuestion(
        id: "series_avoid",
        title: "Never do this",
        subtitle: "Anything picked here is forbidden in every video of the series.",
        selection: .multiple,
        options: [
            .init(id: "faces", label: "Show my face", symbol: "person.crop.circle.badge.xmark"),
            .init(id: "claims", label: "Claims I can't back up", symbol: "exclamationmark.triangle"),
            .init(id: "prices", label: "Mention prices", symbol: "dollarsign.circle"),
            .init(id: "competitors", label: "Name competitors", symbol: "building.2"),
            .init(id: "slang", label: "Memes and slang", symbol: "face.smiling"),
            .init(id: "politics", label: "Politics and religion", symbol: "hand.raised"),
            .init(id: "clickbait", label: "Clickbait or fake urgency", symbol: "flame"),
            .init(id: "ai", label: "Say it was made by AI", symbol: "cpu"),
        ]
    )

    @State private var step: Step = .style
    @State private var templates: [ContentTemplate]?
    @State private var chosen: ContentTemplate?
    @State private var destinations: Set<String> = []
    /// Seconds, or nil for "decide for me".
    @State private var length: Int? = 30
    @State private var decideLength = false
    @State private var goal = "followers"
    @State private var starting = false
    @State private var needsGenerator = false
    /// Why starting the series did not work, said on this screen rather than
    /// thrown at the one underneath it.
    @State private var failure: String?
    /// Which network is opening its sign-in, so only that tile spins.
    @State private var opening: Platform?
    /// What every video must carry, and what it must never do.
    @State private var includes: Set<String> = ["hook", "captions"]
    @State private var avoids: Set<String> = []
    /// How it looks and who speaks. Both start EMPTY on purpose: they are
    /// required, and a preselected answer is a question that was never asked.
    @State private var look: SeriesLook?
    @State private var voice: SeriesVoice?
    /// English until told otherwise -- the one question with a natural default.
    @State private var language = "english"
    /// What this month still has, for the credits line on the accounts step.
    @State private var standing: [QuotaStanding] = []

    private static let goals: [(id: String, label: String, symbol: String, sentence: String)] = [
        ("followers", "Grow followers", "person.3", "The goal is followers: hooks that make people want the next one."),
        ("earning", "Earn from it", "dollarsign.circle", "The goal is income: posts that lead to what the account sells, without hard selling."),
        ("awareness", "Get known", "megaphone", "The goal is awareness: the account's name and point of view, repeated."),
        ("sales", "Sell a product", "cart", "The goal is sales: show the product doing its job."),
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: step.progress)
                    .tint(Theme.accent)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .animation(.snappy(duration: 0.4), value: step)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .style {
                        Button { back() } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                        .disabled(starting)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if step == .style {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: step)
            .overlay {
                if starting {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Writing your first post in \(chosen?.name ?? "this style")…")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .task {
                if templates == nil { templates = await session.templates() }
                // Already answered in onboarding, so it opens on that style
                // rather than asking the same question twice.
                if chosen == nil, let slug = session.settings?.styleSlug {
                    chosen = templates?.first { $0.slug == slug }
                    if let seconds = chosen?.workflow?.durationSeconds, !decideLength { length = seconds }
                }
            }
            .task { standing = await session.quotaStanding() }
            .interactiveDismissDisabled(starting)
            .alert(
                "That didn't start",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .alert("One more thing", isPresented: $needsGenerator) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your series is on. To make the videos it needs a generator: sign in to one under Home → Let Autocast make the videos.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .style:        styles
        case .destinations: whereTo
        case .length:       howLong
        case .look:         howItLooks
        case .voice:        whoSpeaks
        case .language:     inWhichLanguage
        case .include:      mustInclude
        case .logo:         logoStep
        case .avoid:        mustAvoid
        case .goal:         whatFor
        case .review:       review
        }
    }

    private var mustInclude: some View {
        picker(Self.includeQuestion, chosen: $includes, next: afterInclude, skippable: true)
    }

    /// 🔴 The answer decides the next screen.
    ///
    /// Abel, 25 Sep 2026: "every answered question might affect the next
    /// question, so think twice" -- said about exactly this option. Choosing
    /// "Your name or logo" used to append a sentence to a brief and move on,
    /// and the logo was never asked for. Now picking it leads straight to the
    /// screen that asks.
    private var afterInclude: Step {
        includes.contains("logo") && session.brand?.logoPath == nil ? .logo : .avoid
    }

    private var logoStep: some View {
        FlowStep(
            title: "Put your logo on them?",
            subtitle: "You asked for your name or logo on every video. Choose the file and it goes on each one.",
            button: session.brand?.logoPath == nil ? "Use my name instead" : "Continue",
            tint: session.brand?.logoPath == nil ? Color.secondary : Theme.accent,
            action: { step = .avoid }
        ) {
            BrandLogoPicker {
                // Stored: move on by itself, the way picking a style does.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if step == .logo { step = .avoid }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var mustAvoid: some View {
        picker(Self.avoidQuestion, chosen: $avoids, next: .goal, skippable: true)
    }

    /// A multi-select screen in the questions' own shape, so the series asks
    /// the way onboarding asks.
    private func picker(
        _ question: OnboardingQuestion,
        chosen: Binding<Set<String>>,
        next: Step,
        skippable: Bool
    ) -> some View {
        FlowStep(
            title: question.title,
            subtitle: question.subtitle,
            button: chosen.wrappedValue.isEmpty && skippable ? "Skip" : "Continue",
            tint: chosen.wrappedValue.isEmpty && skippable ? Color.secondary : Theme.accent,
            action: { step = next }
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(question.options) { option in
                    OptionTile(option: option, isChosen: chosen.wrappedValue.contains(option.id)) {
                        withAnimation(.snappy(duration: 0.18)) {
                            if chosen.wrappedValue.contains(option.id) {
                                chosen.wrappedValue.remove(option.id)
                            } else {
                                chosen.wrappedValue.insert(option.id)
                            }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Steps

    private var styles: some View {
        FlowStep(
            title: "What kind of videos?",
            subtitle: "A style is the brief, the themes and the look. Your account is still yours."
        ) {
            if let templates {
                // One field of styles, not a stack of labelled shelves. The
                // headings broke it into little grids that each ended on a
                // ragged row, and the eye never got a run at it (Abel, 23 Sep
                // 2026: "the way you did it is honestly bad, like you
                // separated it"). What a style is FOR is on the tile itself.
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(templates) { template in
                        StyleTile(template: template, isChosen: chosen?.slug == template.slug) {
                            chosen = template
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            // Only accounts that work. TikTok used to be put
                            // in for somebody with no account at all, which
                            // let the next screen say "Continue" over an
                            // empty row. Nothing is picked for them: the
                            // next screen asks them to connect one.
                            if destinations.isEmpty {
                                destinations = Set(session.connections.filter(\.isHealthy).map { $0.platform.rawValue })
                            }
                            if let seconds = template.workflow?.durationSeconds, !decideLength {
                                length = seconds
                            }
                            Task {
                                try? await Task.sleep(for: .milliseconds(400))
                                if chosen?.slug == template.slug, step == .style { step = .destinations }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.track)
                            .frame(height: 150)
                    }
                }
                .padding(.horizontal, 20)
                .breathing()
            }
        }
    }

    /// Two to a row, and an odd last one fills the row.
    private static let platformRows: [[Platform]] =
        stride(from: 0, to: Platform.allCases.count, by: 2).map {
            Array(Platform.allCases[$0..<min($0 + 2, Platform.allCases.count)])
        }

    /// The networks that are signed in and working. An account whose login has
    /// lapsed is still on the list, but it is not connected: it needs signing
    /// in again, and it does not count.
    private var connectedPlatforms: [Platform] {
        Platform.allCases.filter { session.connection(for: $0)?.isHealthy == true }
    }

    /// What will really be posted to: picked AND still signed in. A pick is
    /// kept when a login lapses, so it comes back with it, but it is not used.
    private var readyDestinations: Set<String> {
        destinations.filter { raw in
            Platform(rawValue: raw).map { session.connection(for: $0)?.isHealthy == true } ?? false
        }
    }

    /// 🔴 A gate, not a suggestion.
    ///
    /// Abel, 29 Sep 2026: "right after that it will ask me to connect at least
    /// one platform. There is no platform I connected, so I cannot continue. I
    /// must connect at least one of those, and after that, I can choose which
    /// platform I want."
    ///
    /// It used to open with TikTok picked for somebody who had connected
    /// nothing, so "Continue" was live over a row that showed no account and a
    /// series could be started for nowhere. Now nothing is picked until an
    /// account is signed in, the button says why it is dead, and the moment one
    /// connects it is picked and the button wakes up.
    private var whereTo: some View {
        let signedIn = connectedPlatforms
        let ready = readyDestinations
        return FlowStep(
            title: signedIn.isEmpty ? "Connect an account" : "Where should it post?",
            subtitle: signedIn.isEmpty
                ? "A series posts for you, so it needs at least one account. Connect one and carry straight on."
                : "Tap an account to pick it or drop it. Tap another network to connect it too.",
            button: signedIn.isEmpty ? "Connect an account to continue" : (ready.isEmpty ? "Pick at least one" : "Continue"),
            tint: ready.isEmpty ? Color.secondary : Theme.accent,
            isDisabled: ready.isEmpty,
            // 🔴 `.length`, not `.include`. This skipped "How long" entirely
            // going forward, while `back()` from "Every video has" returned TO
            // it -- so the only way to reach that screen was to press Back into
            // a page the flow had never shown (Abel, 25 Sep 2026: "when I hit
            // continue it jumps two pages at one... this really looks funny").
            action: { if !readyDestinations.isEmpty { step = .length } }
        ) {
            // The same tiles as the connect sheet, rather than a row with a
            // Connect pill bolted to its side (Abel, 24 Sep 2026: "on the
            // connect page, bro i hate that"). One tile, one tap: it signs
            // you in when it is not yours, and picks it when it is.
            VStack(spacing: 10) {
                ForEach(Self.platformRows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row) { platform in
                            let live = session.connection(for: platform)?.isHealthy == true
                            PlatformTile(
                                platform: platform,
                                connection: session.connection(for: platform),
                                isOpening: opening == platform,
                                isChosen: live && destinations.contains(platform.rawValue)
                            ) {
                                tap(platform)
                            }
                        }
                    }
                }

                creditsNote(accounts: ready.count)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
        }
    }

    /// What this costs, said before it is spent -- and only what is true. A
    /// series makes ONE video per post and hands the same file to every
    /// account picked (`addTarget` in attach.ts), so the credits are the
    /// videos, not the accounts.
    private func creditsNote(accounts: Int) -> some View {
        let left = standing.first { $0.kind == "video_gen" }?.left
        let sentence: String
        if accounts > 1 {
            sentence = "One video is made for each post and posted to all \(accounts) accounts."
        } else {
            sentence = "One video is made for each post."
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(sentence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let left {
                    Text("\(left) videos left this month.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tap(_ platform: Platform) {
        guard opening == nil else { return }
        guard session.connection(for: platform)?.isHealthy == true else {
            // Not signed in, or signed in once and lapsed: the network's own
            // sign-in opens either way.
            opening = platform
            Task {
                await session.connect(platform)
                opening = nil
                // Signing in is agreeing to post there, so it arrives picked.
                if session.connection(for: platform)?.isHealthy == true {
                    withAnimation(.snappy(duration: 0.18)) {
                        destinations.insert(platform.rawValue)
                    }
                }
            }
            return
        }
        withAnimation(.snappy(duration: 0.18)) {
            if destinations.contains(platform.rawValue) {
                destinations.remove(platform.rawValue)
            } else {
                destinations.insert(platform.rawValue)
            }
        }
    }

    // MARK: - How it comes out

    /// 🔴 Pictures, and no default.
    ///
    /// Abel, 29 Sep 2026: "it should ask me for the video style it wants with
    /// pictures. I must put that." Twelve looks, the same barista poured in
    /// each, so they can be compared instead of imagined. Nothing is picked
    /// when the screen opens -- a preselected answer is a question nobody was
    /// asked -- and Continue stays dead until one is.
    private var howItLooks: some View {
        FlowStep(
            title: "How should it look?",
            subtitle: "Every video in the series is drawn this way. Pick one.",
            button: look == nil ? "Pick a look" : "Continue",
            tint: look == nil ? Color.secondary : Theme.accent,
            isDisabled: look == nil,
            action: { if look != nil { step = .voice } }
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(SeriesLook.all) { item in
                    LookTile(look: item, isChosen: look?.id == item.id) {
                        withAnimation(.snappy(duration: 0.18)) { look = item }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        // On to the next screen by itself, the way picking a
                        // style does -- unless they changed their mind.
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            if look?.id == item.id, step == .look { step = .voice }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// 🔴 Required. "No voiceover" is an answer; not answering is not.
    ///
    /// Abel, 29 Sep 2026: "something that should ask me for a voiceover. It
    /// must be a requirement." It was a checkbox in a list that could be left
    /// alone, and left alone it meant nothing was decided. The voice changes
    /// what is WRITTEN -- a voiced video needs a script, a silent one needs its
    /// words on the screen -- so it is asked before the writer runs.
    private var whoSpeaks: some View {
        FlowStep(
            title: "Who speaks over it?",
            subtitle: "Pick a voice, or none. Every script is written for it.",
            button: voice == nil ? "Pick a voice" : "Continue",
            tint: voice == nil ? Color.secondary : Theme.accent,
            isDisabled: voice == nil,
            action: { if voice != nil { step = .language } }
        ) {
            VStack(spacing: 10) {
                ForEach(SeriesVoice.all) { item in
                    DetailedOption(
                        option: OnboardingQuestion.Option(
                            id: item.id, label: item.name, symbol: item.symbol, detail: item.detail
                        ),
                        isChosen: voice?.id == item.id
                    ) {
                        withAnimation(.snappy(duration: 0.18)) { voice = item }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }

                // Said before anybody counts on it. The script is always
                // written; whether it is SPOKEN depends on the model that
                // makes the video, and not all of them make sound.
                Text("Autocast writes the script either way. It is spoken by video models that make sound; on the others the words stay in the caption.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
        }
    }

    private var inWhichLanguage: some View {
        FlowStep(
            title: "What language?",
            subtitle: "The hook, the caption and every spoken word are written in it.",
            button: "Continue",
            action: { step = .include }
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(SeriesLanguage.all) { item in
                    OptionTile(
                        option: OnboardingQuestion.Option(id: item.id, label: item.native, symbol: "globe"),
                        isChosen: language == item.id
                    ) {
                        withAnimation(.snappy(duration: 0.18)) { language = item.id }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var howLong: some View {
        FlowStep(
            title: "How long should each video be?",
            subtitle: "In seconds. Or let Autocast pick per post.",
            button: "Continue",
            action: { step = .look }
        ) {
            VStack(spacing: 10) {
                if let suggested = chosen?.workflow?.durationSeconds, ![15, 30, 60].contains(suggested) {
                    DetailedOption(
                        option: OnboardingQuestion.Option(
                            id: "\(suggested)",
                            label: "\(suggested) seconds",
                            symbol: "timer",
                            detail: "What this style is written for"
                        ),
                        isChosen: !decideLength && length == suggested
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            decideLength = false
                            length = suggested
                        }
                    }
                }
                ForEach([15, 30, 60], id: \.self) { seconds in
                    DetailedOption(
                        option: OnboardingQuestion.Option(
                            id: "\(seconds)",
                            label: "\(seconds) seconds",
                            symbol: "timer",
                            detail: seconds == 15 ? "Quick, one idea" : (seconds == 30 ? "The usual" : "Room for a story")
                        ),
                        isChosen: !decideLength && length == seconds
                    ) {
                        withAnimation(.snappy(duration: 0.18)) {
                            decideLength = false
                            length = seconds
                        }
                    }
                }
                DetailedOption(
                    option: OnboardingQuestion.Option(
                        id: "decide",
                        label: "Decide for me",
                        symbol: "sparkles",
                        detail: "Each post gets the length its idea needs"
                    ),
                    isChosen: decideLength
                ) {
                    withAnimation(.snappy(duration: 0.18)) {
                        decideLength = true
                        length = nil
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var whatFor: some View {
        FlowStep(
            title: "What is it for?",
            subtitle: "It steers the hooks and the calls to action.",
            button: "Continue",
            action: { step = .review }
        ) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Self.goals, id: \.id) { item in
                    OptionTile(
                        option: OnboardingQuestion.Option(id: item.id, label: item.label, symbol: item.symbol),
                        isChosen: goal == item.id
                    ) {
                        withAnimation(.snappy(duration: 0.18)) { goal = item.id }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// The summary, as one card with the style's own picture on it rather
    /// than a column of label-and-value rows that read like a receipt
    /// (Abel, 24 Sep 2026: "the behind a photo everyday thing is also 😭 bro
    /// change the ui").
    private var review: some View {
        FlowStep(
            title: "Ready",
            subtitle: "It writes the next post only, makes its video, and waits for your tap. The one after is written once this one is out.",
            button: "Start the series",
            isBusy: starting,
            action: { Task { await start() } }
        ) {
            VStack(spacing: 14) {
                // The style, wearing its photograph.
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let chosen, let image = UIImage(named: chosen.artName) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else if let chosen {
                                StyleCover(slug: chosen.slug, symbol: chosen.symbol)
                            } else {
                                Color.track
                            }
                        }
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipped()

                        LinearGradient(
                            colors: [.black.opacity(0), .black.opacity(0.72)],
                            startPoint: .center, endPoint: .bottom
                        )
                        .frame(height: 150)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(chosen?.name ?? "Your series")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                            Text(chosen?.tagline ?? "")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(14)
                    }

                    // The facts, as a wrapping row of chips instead of rows.
                    FlowChips(items: reviewChips)
                        .padding(14)
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // The style's workflow, as the plan every video follows.
                if let steps = chosen?.workflow?.steps, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("How every video gets made")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, stepText in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 20, height: 20)
                                    .background(Theme.accent.opacity(0.12), in: Circle())
                                Text(stepText)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                // What it will spend, before it is started: a series makes
                // about a video a day, and the month only holds so many. The
                // number is the server's own counter, not an estimate.
                if chosen?.needsFilming != true, let left = standing.first(where: { $0.kind == "video_gen" })?.left {
                    Label(
                        left == 0
                            ? "No videos left this month, so the series waits until they renew -- or you upgrade."
                            : (left >= 30
                                ? "About a video a day, so about 30 a month. \(left) left this month."
                                : "About a video a day, and only \(left) left this month."),
                        systemImage: "bolt.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if chosen?.needsFilming == true {
                    // Said here, not discovered later: this style is a person
                    // talking, and no generator can be that person.
                    Label(
                        "This style is you on camera. Autocast writes the script and books the slot; you film it and tap Post.",
                        systemImage: "video.badge.checkmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !session.hasWorkingGenerator {
                    Label("Needs a generator to make the videos", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// The choices, shortest first, as chips.
    private var reviewChips: [String] {
        var chips: [String] = []
        chips.append(contentsOf: readyDestinations.sorted().compactMap { Platform(rawValue: $0)?.networkName })
        chips.append(decideLength
                     ? "\(chosen?.workflow?.durationSeconds ?? 30)s"
                     : "\(length ?? 30)s")
        chips.append("Daily")
        if let label = Self.goals.first(where: { $0.id == goal })?.label { chips.append(label) }
        // How it comes out, said in the words the person picked.
        if let look { chips.append(look.name) }
        if let voice { chips.append(voice.isNone ? "No voiceover" : voice.name) }
        if language != "english", let spoken = SeriesLanguage.all.first(where: { $0.id == language }) {
            chips.append(spoken.native)
        }
        chips.append(contentsOf: includes.compactMap { id in
            Self.includeQuestion.options.first { $0.id == id }?.label
        }.sorted())
        chips.append(contentsOf: avoids.compactMap { id in
            Self.avoidQuestion.options.first { $0.id == id }.map { "No \($0.label.lowercased())" }
        }.sorted())
        return chips
    }

    // MARK: - Moving

    private func back() {
        withAnimation(.snappy(duration: 0.25)) {
            switch step {
            case .style:        break
            case .destinations: step = .style
            case .length:       step = .destinations
            case .look:         step = .length
            case .voice:        step = .look
            case .language:     step = .voice
            case .include:      step = .language
            case .logo:         step = .include
            case .avoid:        step = includes.contains("logo") && session.brand?.logoPath == nil ? .logo : .include
            case .goal:         step = .avoid
            case .review:       step = .goal
            }
        }
    }

    private func start() async {
        // The three required answers. The buttons that lead here cannot be
        // pressed without them, so this is the second lock, not the first.
        guard let chosen, let look, let voice else {
            failure = "Pick a style, a look and a voice first."
            return
        }
        // An account that signed out while the flow was open is not one to
        // post to.
        guard !readyDestinations.isEmpty else {
            failure = "Connect an account first. A series needs somewhere to post."
            return
        }
        starting = true
        defer { starting = false }

        var brief = Self.goals.first { $0.id == goal }?.sentence ?? ""
        let musts = includes.compactMap { id in Self.includeQuestion.options.first { $0.id == id }?.label }.sorted()
        let nevers = avoids.compactMap { id in Self.avoidQuestion.options.first { $0.id == id }?.label }.sorted()
        if !musts.isEmpty { brief += " Every video must have: \(musts.joined(separator: ", "))." }
        if !nevers.isEmpty { brief += " Never: \(nevers.joined(separator: ", "))." }

        // ONE post, not thirty.
        //
        // Abel, 24 Sep 2026: "why it anyways generates a 30day plan? That must
        // be a joke i swear. You know the cost for 1user whenever they did
        // this? So please always let it plan only 1 befor it posts and it will
        // post it once done." Writing a month up front spends on twenty-nine
        // posts nobody has seen yet, and a series that learns from what worked
        // cannot use anything it wrote before the first post went out. The
        // next one is written once this one is posted -- see `extend-series`.
        // 🔴 Every failure below is caught HERE and shown on this screen.
        //
        // It used to throw the results away and dismiss regardless, so the
        // sheet closed saying it had worked and the root alert -- "That did
        // not work" -- landed on the screen underneath a moment later, with no
        // clue which step failed (Abel, 25 Sep 2026: "it says writing your
        // first post and right after that it's gonna say that did not work,
        // why is that needed").
        //
        // It is also why a `proposePlan` failure looked like the spinner
        // simply stopping: the root alert cannot present from underneath a
        // sheet that is still up, so nothing appeared at all.
        session.lastError = nil

        guard let proposal = await session.proposePlan(
            brief: brief,
            days: 1,
            postsPerDay: 1,
            platforms: Array(readyDestinations).sorted(),
            template: chosen.slug,
            durationSeconds: decideLength ? nil : length,
            look: look.sentence,
            voice: voice.sentence,
            language: SeriesLanguage.all.first { $0.id == language }?.english
        ) else {
            failure = session.lastError.flatMap { $0.isEmpty ? nil : $0 }
                ?? "The writer could not be reached just now. Try again."
            session.lastError = nil
            return
        }

        // Remembered so the next one is written the same way, and so this
        // screen opens on the same style next time.
        await session.saveStyleSlug(chosen.slug)

        // A series is on from the start: the plan is switched on and the
        // maker with it, so the first video is made without another visit.
        await session.refreshPlan()
        guard await session.activatePlan() else {
            // The usual cause is a series already running: the RPC refuses
            // with "that plan is already active". Said plainly, with the way
            // out, rather than as a bare database sentence.
            let reason = session.lastError.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            failure = reason.localizedCaseInsensitiveContains("already")
                ? "You already have a series running. Open it from Home and delete it first, then start this one."
                : (reason.isEmpty ? "Your first post was written, but the series could not be switched on." : reason)
            session.lastError = nil
            return
        }

        // A filmed style needs no generator, so not having one is not a
        // problem worth stopping for.
        if session.hasWorkingGenerator || chosen.needsFilming {
            // Autopilot failing is worth saying, but the series exists and the
            // post is written, so it is not worth refusing to leave over.
            _ = await session.setAutopilot(true)
            session.lastError = nil
            onStarted(proposal)
            dismiss()
        } else {
            onStarted(proposal)
            needsGenerator = true
        }
    }
}

// MARK: - Pieces

/// One screen: a title, a line, the content, and the one button.
private struct FlowStep<Content: View>: View {
    let title: String
    let subtitle: String
    var button: String?
    var tint: Color = Theme.accent
    var isBusy = false
    /// A button that cannot be pressed yet -- a required answer is missing.
    /// Dimmed and dead, not merely grey: "Continue" over an unanswered
    /// question is how the accounts step used to let people through.
    var isDisabled = false
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
            .padding(.bottom, 14)

            ScrollView {
                content()
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            if let button {
                Button(action: action) {
                    Group {
                        if isBusy { ProgressView().tint(Theme.onAccent) } else { Text(button) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .controlSize(.large)
                .tint(tint)
                // The button style already draws itself faint when disabled.
                .disabled(isBusy || isDisabled)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
        }
    }
}

/// The choices as chips that wrap, instead of a column of label-and-value
/// rows. Laid out by hand because SwiftUI has no wrapping stack: the width is
/// measured, and a chip that will not fit starts the next line.
struct FlowChips: View {
    let items: [String]

    /// The system's own wrapping. An adaptive grid sizes and wraps its cells
    /// on its own and reports its height honestly, where a hand-rolled flow
    /// layout has to measure itself inside a GeometryReader that fills the
    /// space it is trying to measure.
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Theme.accent.opacity(0.10), in: Capsule())
            }
        }
    }
}

private struct ReviewRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
