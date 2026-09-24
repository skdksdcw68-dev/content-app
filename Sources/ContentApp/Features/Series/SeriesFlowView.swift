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
        case style, destinations, length, include, avoid, goal, review

        var progress: Double { Double(rawValue + 1) / Double(Step.allCases.count + 1) }

        var title: String {
            switch self {
            case .style:        "Pick a style"
            case .destinations: "Where it posts"
            case .length:       "How long"
            case .include:      "Every video has"
            case .avoid:        "Never do this"
            case .goal:         "What it's for"
            case .review:       "Ready"
            }
        }
    }

    /// What every video in the series must carry. Even, like every other set
    /// of choices in the app.
    private static let includes = OnboardingQuestion(
        id: "series_include",
        title: "Every video has",
        subtitle: "Pick what each one must carry. It goes into every brief.",
        selection: .multiple,
        options: [
            .init(id: "hook", label: "A hook in the first second", symbol: "bolt"),
            .init(id: "captions", label: "Captions burned in", symbol: "captions.bubble"),
            .init(id: "voiceover", label: "A voiceover", symbol: "waveform"),
            .init(id: "music", label: "Music under it", symbol: "music.note"),
            .init(id: "cta", label: "A call to action at the end", symbol: "hand.point.up.left"),
            .init(id: "proof", label: "A number or proof", symbol: "checkmark.seal"),
            .init(id: "question", label: "A question to the viewer", symbol: "questionmark.bubble"),
            .init(id: "logo", label: "Your name or logo", symbol: "tag"),
        ]
    )

    /// What it must never do. Separate from the brand-wide answer because a
    /// series can be stricter than the account.
    private static let avoids = OnboardingQuestion(
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
    /// Which network is opening its sign-in, so only that tile spins.
    @State private var opening: Platform?
    /// What every video must carry, and what it must never do.
    @State private var includes: Set<String> = ["hook", "captions"]
    @State private var avoids: Set<String> = []

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
            .interactiveDismissDisabled(starting)
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
        case .include:      mustInclude
        case .avoid:        mustAvoid
        case .goal:         whatFor
        case .review:       review
        }
    }

    private var mustInclude: some View {
        picker(Self.includes, chosen: $includes, next: .avoid, skippable: true)
    }

    private var mustAvoid: some View {
        picker(Self.avoids, chosen: $avoids, next: .goal, skippable: true)
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
                            if destinations.isEmpty {
                                destinations = Set(session.connections.map { $0.platform.rawValue })
                                if destinations.isEmpty { destinations = [Platform.tiktok.rawValue] }
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

    private var whereTo: some View {
        FlowStep(
            title: "Where should it post?",
            subtitle: "Tap one to connect it. Tap a connected one to pick it.",
            button: destinations.isEmpty ? "Pick at least one" : "Continue",
            tint: destinations.isEmpty ? Color.secondary : Theme.accent,
            action: { if !destinations.isEmpty { step = .include } }
        ) {
            // The same tiles as the connect sheet, rather than a row with a
            // Connect pill bolted to its side (Abel, 24 Sep 2026: "on the
            // connect page, bro i hate that"). One tile, one tap: it signs
            // you in when it is not yours, and picks it when it is.
            VStack(spacing: 10) {
                ForEach(Self.platformRows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row) { platform in
                            let connected = session.connection(for: platform) != nil
                            PlatformTile(
                                platform: platform,
                                connection: session.connection(for: platform),
                                isOpening: opening == platform,
                                isChosen: connected && destinations.contains(platform.rawValue)
                            ) {
                                tap(platform, connected: connected)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func tap(_ platform: Platform, connected: Bool) {
        guard opening == nil else { return }
        guard connected else {
            opening = platform
            Task {
                await session.connect(platform)
                opening = nil
                // Signing in is agreeing to post there, so it arrives picked.
                if session.connection(for: platform) != nil {
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

    private var howLong: some View {
        FlowStep(
            title: "How long should each video be?",
            subtitle: "Or let Autocast pick per post.",
            button: "Continue",
            action: { step = .include }
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

                if !session.hasWorkingGenerator {
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
        chips.append(contentsOf: destinations.sorted().compactMap { Platform(rawValue: $0)?.networkName })
        chips.append(decideLength
                     ? "\(chosen?.workflow?.durationSeconds ?? 30)s"
                     : "\(length ?? 30)s")
        chips.append("Daily")
        if let label = Self.goals.first(where: { $0.id == goal })?.label { chips.append(label) }
        chips.append(contentsOf: includes.compactMap { id in
            Self.includes.options.first { $0.id == id }?.label
        }.sorted())
        chips.append(contentsOf: avoids.compactMap { id in
            Self.avoids.options.first { $0.id == id }.map { "No \($0.label.lowercased())" }
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
            case .include:      step = .length
            case .avoid:        step = .include
            case .goal:         step = .avoid
            case .review:       step = .goal
            }
        }
    }

    private func start() async {
        guard let chosen else { return }
        starting = true
        defer { starting = false }

        var brief = Self.goals.first { $0.id == goal }?.sentence ?? ""
        let musts = includes.compactMap { id in Self.includes.options.first { $0.id == id }?.label }.sorted()
        let nevers = avoids.compactMap { id in Self.avoids.options.first { $0.id == id }?.label }.sorted()
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
        guard let proposal = await session.proposePlan(
            brief: brief,
            days: 1,
            postsPerDay: 1,
            platforms: Array(destinations).sorted(),
            template: chosen.slug,
            durationSeconds: decideLength ? nil : length
        ) else { return }

        // Remembered so the next one is written the same way, and so this
        // screen opens on the same style next time.
        await session.saveStyleSlug(chosen.slug)

        // A series is on from the start: the plan is switched on and the
        // maker with it, so the first video is made without another visit.
        await session.refreshPlan()
        _ = await session.activatePlan()
        if session.hasWorkingGenerator {
            _ = await session.setAutopilot(true)
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
                .disabled(isBusy)
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

    @State private var height: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
                .background(
                    GeometryReader { inner in
                        Color.clear
                            .onAppear { height = inner.size.height }
                            .onChange(of: inner.size.height) { _, new in height = new }
                    }
                )
        }
        .frame(height: height)
    }

    private func content(width: CGFloat) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0

        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                chip(item)
                    .alignmentGuide(.leading) { size in
                        if x - size.width < -width {
                            x = 0
                            y -= size.height + 8
                        }
                        let result = x
                        x -= size.width + 8
                        return result
                    }
                    .alignmentGuide(.top) { _ in y }
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.10), in: Capsule())
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
