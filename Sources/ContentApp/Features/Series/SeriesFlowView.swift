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
        //
        // 31 Oct 2026: captions follow the voice. "He will need to choose the
        // caption style, the voiceover, and things like this" -- first, so
        // autopilot never has to guess.
        //
        // 🔴 5 Nov 2026: four, not twelve (Abel approved the mockup, canvas row
        // 3). The look comes with the format; voice, captions, length and
        // language sit on one screen already set to the format's best; what
        // every video has, never does and is for moved under More options on
        // the last screen. Nothing is lost -- it is just not a screen each.
        case style, yours, destinations, review

        /// What is left after this one, for the step bar.
        var left: String {
            let after = Step.allCases.count - rawValue - 1
            return after == 0 ? "Last step" : "\(after) left"
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
            // The voiceover and the captions are steps of their own now, each
            // with a real answer; the list keeps eight so the grid stays even.
            .init(id: "loop", label: "An ending that loops", symbol: "repeat"),
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
    @State private var includes: Set<String> = ["hook"]
    @State private var avoids: Set<String> = []
    /// How it looks and who speaks. Both start EMPTY on purpose: they are
    /// required, and a preselected answer is a question that was never asked.
    @State private var look: SeriesLook?
    /// The twelve general looks, below the style's own, once asked for.
    @State private var showAllLooks = false
    @State private var voice: SeriesVoice?
    /// Required too, and empty for the same reason.
    @State private var caption: SeriesCaption?
    /// Plays a voice's sample on the voiceover step.
    @State private var sampler = VoiceSampler()
    /// English until told otherwise -- the one question with a natural default.
    @State private var language = "english"
    /// What this month still has, for the credits line on the accounts step.
    @State private var standing: [QuotaStanding] = []
    /// The X was tapped with picks made: ask before throwing the sheet away.
    @State private var confirmingLeave = false
    /// A format being watched full screen before it is picked.
    @State private var watching: ContentTemplate?
    /// More options on the last screen, closed until asked for.
    @State private var showingMore = false

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
                // The step bar: a check inside each finished step, and how many
                // are left (Abel, 5 Nov 2026).
                HStack(spacing: 12) {
                    if step != .style {
                        Button { back() } label: {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                        .disabled(starting)
                    }
                    SeriesStepBar(current: step.rawValue, count: Step.allCases.count)
                    Text(step.left)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .animation(.snappy(duration: 0.35), value: step)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The only way out. Swiping down does nothing (below), and once
                // anything is picked it asks first.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if chosen == nil { dismiss() } else { confirmingLeave = true }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .disabled(starting)
                }
            }
            .animation(.snappy(duration: 0.25), value: step)
            .alert("Leave without starting?", isPresented: $confirmingLeave) {
                Button("Keep going", role: .cancel) {}
                Button("Leave") { dismiss() }
            } message: {
                Text("Your picks are kept. Start a series opens right here next time.")
            }
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
                // Where they left off, if they left with picks made.
                restoreDraft()
                // Already answered in onboarding, so it opens on that style
                // rather than asking the same question twice.
                if chosen == nil, let slug = session.settings?.styleSlug {
                    chosen = templates?.first { $0.slug == slug }
                    if let seconds = chosen?.workflow?.durationSeconds, !decideLength { length = seconds }
                }
            }
            .task { standing = await session.quotaStanding() }
            // Abel, 5 Nov 2026: "pushing it down shouldn't close the sheet unless
            // they closed it themselves." Only the X closes it.
            .interactiveDismissDisabled(true)
            .onChange(of: chosen) { _, _ in saveDraft() }
            .onChange(of: voice) { _, _ in saveDraft() }
            .onChange(of: caption) { _, _ in saveDraft() }
            .onChange(of: language) { _, _ in saveDraft() }
            .onChange(of: length) { _, _ in saveDraft() }
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
                Text("Your series is on. To make the videos it needs a generator: sign in to one under Home → Let Postpilot make the videos.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .style:        styles
        case .yours:        makeItYours
        case .destinations: whereTo
        case .review:       review
        }
    }

    // MARK: - Steps

    /// The proven formats as video cards, each with Watch (Abel, 5 Nov 2026:
    /// "make sure the user can directly open the video and see the preview").
    /// Only what the server has switched on is shown (0098).
    private var styles: some View {
        FlowStep(
            title: "What should we make?",
            subtitle: "Formats we have tested. Every video is a new idea in the same style."
        ) {
            if let templates {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(templates) { template in
                        FormatCard(
                            template: template,
                            isChosen: chosen?.slug == template.slug,
                            cost: costLine(for: template),
                            choose: { pick(template) },
                            watch: { watching = template }
                        )
                    }
                }
                .padding(.horizontal, 20)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.track)
                            .frame(height: 236)
                    }
                }
                .padding(.horizontal, 20)
                .breathing()
            }
        }
        .fullScreenCover(item: $watching) { template in
            FormatPreview(template: template) {
                watching = nil
                pick(template)
            }
        }
    }

    /// What a video of this format costs, as a share of the month.
    private func costLine(for template: ContentTemplate) -> String? {
        let seconds = template.workflow?.durationSeconds
        guard let share = session.usageShare(usd: SeriesCost.perVideoUSD(seconds: seconds)) else { return nil }
        return "About \(UsageFormat.percent(share)) of your month"
    }

    /// Picking a format fills in everything after it with that format's best,
    /// so the next screen is a check, not a questionnaire.
    private func pick(_ template: ContentTemplate) {
        let fresh = chosen?.slug != template.slug
        chosen = template
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if fresh {
            look = CategoryLooks.looks(for: template.slug).first ?? SeriesLook.all.first
            if voice == nil { voice = SeriesVoice.all.first { $0.id == "decide" } }
            if caption == nil { caption = SeriesCaption.all.first }
            if let seconds = template.workflow?.durationSeconds, !decideLength {
                length = min(seconds, longestVideo)
            }
        }
        if destinations.isEmpty {
            destinations = Set(session.connections.filter(\.isHealthy).map { $0.platform.rawValue })
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if chosen?.slug == template.slug, step == .style { step = .yours }
        }
    }

    /// The longest video this plan makes (app_limits `video_seconds`: Pro 30,
    /// Max 60, Ultra 120).
    private var longestVideo: Int {
        switch session.planRank {
        case 3: 120
        case 2: 60
        default: 30
        }
    }

    /// Everything about how the videos come out, on one screen, already set to
    /// the format's best answer.
    private var makeItYours: some View {
        FlowStep(
            title: "Make it yours",
            subtitle: "Already set to what works best for this format. Change anything, or keep it.",
            button: "Continue",
            action: {
                sampler.stop()
                step = .destinations
            }
        ) {
            VStack(alignment: .leading, spacing: 22) {
                if let chosen {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chosen.name).font(.headline)
                            Text("The look comes with the format")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Change") { step = .style }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                section("Voice") {
                    VStack(spacing: 10) {
                        ForEach(SeriesVoice.all) { item in
                            VoiceRow(
                                voice: item,
                                isChosen: voice?.id == item.id,
                                isPlaying: sampler.playing == item.id,
                                choose: {
                                    withAnimation(.snappy(duration: 0.18)) { voice = item }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                },
                                play: { sampler.toggle(item) }
                            )
                        }
                    }
                }

                section("How long") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach([15, 20, 30, 45, 60, 0], id: \.self) { seconds in
                            lengthChip(seconds)
                        }
                    }
                }

                section("Captions") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(SeriesCaption.all) { item in
                            CaptionTile(caption: item, isChosen: caption?.id == item.id) {
                                withAnimation(.snappy(duration: 0.18)) { caption = item }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                    }
                }

                section("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(SeriesLanguage.all) { item in
                            Text(item.native).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 20)
        }
        .onDisappear { sampler.stop() }
    }

    /// A grey label over a group of choices.
    private func section<Inner: View>(_ title: String, @ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            inner()
        }
    }

    /// One length. Longer than the plan makes: shown, locked, with the plan it
    /// needs, so the person knows it exists (0 is "Auto").
    private func lengthChip(_ seconds: Int) -> some View {
        let isAuto = seconds == 0
        let locked = !isAuto && seconds > longestVideo
        let picked = isAuto ? decideLength : (!decideLength && length == seconds)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if isAuto {
                    decideLength = true
                    length = nil
                } else {
                    decideLength = false
                    length = seconds
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(isAuto ? "Auto" : "\(seconds) s")
                    .font(.subheadline.weight(picked ? .bold : .medium))
                if locked {
                    Text(seconds > 60 ? "Ultra" : "Max")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(picked ? AnyShapeStyle(Theme.accent.opacity(0.12)) : AnyShapeStyle(Theme.surface))
                    .overlay(shape.strokeBorder(picked ? Theme.accent : .clear, lineWidth: 1.5))
            }
            .foregroundStyle(locked ? Color.secondary : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    /// What every video has, never does, and is for -- the old screens of
    /// their own, now one tap away on the last screen.
    private var moreOptions: some View {
        DisclosureGroup(isExpanded: $showingMore) {
            VStack(alignment: .leading, spacing: 18) {
                optionGrid(Self.includeQuestion, chosen: $includes)
                optionGrid(Self.avoidQuestion, chosen: $avoids)
                VStack(alignment: .leading, spacing: 10) {
                    Text("What it's for").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
                }
            }
            .padding(.top, 14)
        } label: {
            HStack {
                Text("More options").font(.body)
                Spacer(minLength: 0)
                Text("Optional").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func optionGrid(_ question: OnboardingQuestion, chosen: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
        }
    }

    // MARK: - Picks kept

    /// What they picked, kept on the phone, so leaving and coming back opens
    /// where they were (Abel, 5 Nov 2026: save what the user did locally).
    private static let draftKey = "series.draft"

    private func saveDraft() {
        let draft: [String: Any] = [
            "slug": chosen?.slug ?? "",
            "voice": voice?.id ?? "",
            "caption": caption?.id ?? "",
            "language": language,
            "length": decideLength ? 0 : (length ?? 30),
        ]
        UserDefaults.standard.set(draft, forKey: Self.draftKey)
    }

    private func restoreDraft() {
        guard let draft = UserDefaults.standard.dictionary(forKey: Self.draftKey) else { return }
        if chosen == nil, let slug = draft["slug"] as? String, let found = templates?.first(where: { $0.slug == slug }) {
            chosen = found
            look = CategoryLooks.looks(for: slug).first ?? SeriesLook.all.first
        }
        if voice == nil, let id = draft["voice"] as? String { voice = SeriesVoice.all.first { $0.id == id } }
        if caption == nil, let id = draft["caption"] as? String { caption = SeriesCaption.all.first { $0.id == id } }
        if let saved = draft["language"] as? String, SeriesLanguage.all.contains(where: { $0.id == saved }) { language = saved }
        if let seconds = draft["length"] as? Int {
            decideLength = seconds == 0
            length = seconds == 0 ? nil : min(seconds, longestVideo)
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
        // 🔴 5 Nov 2026: no longer a gate. Abel: "without hard pushing on the
        // user ... if they say I'll connect later, just generate the video and
        // send them directly via notification." The video is still made; it
        // waits in the Library and a push says it is ready (generate.ts).
        return FlowStep(
            title: "Where should it post?",
            subtitle: signedIn.isEmpty
                ? "Connect now or later. Nothing is posted until you approve it."
                : "Tap an account to pick it or drop it. Tap another network to connect it too.",
            button: ready.isEmpty ? "I'll connect later" : "Continue",
            tint: ready.isEmpty ? Color.secondary : Theme.accent,
            action: { step = .review }
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
        let left = standing.first { $0.kind == "credit" }?.percentLeft
        let each = session.usageShare(usd: SeriesCost.perVideoUSD(seconds: length)) ?? 0
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
                Text("About \(UsageFormat.percent(each)) of your month a video.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let left {
                    Text("\(UsageFormat.percent(left)) of this month left.")
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
                // about a video a day. 🔴 Read from the usage meter (0079). It
                // read the old "video_gen" counter, which stopped moving on 29
                // Sep when generation began to be paid for by what it costs --
                // so it said the same number all month.
                if chosen?.needsFilming != true, let meter = standing.first(where: { $0.kind == "credit" }) {
                    let month = session.usageShare(usd: 30 * SeriesCost.perVideoUSD(seconds: nil)) ?? 0
                    Label(
                        meter.percentLeft <= 0
                            ? "This month's usage is used up, so the series waits until it fills up again, or you upgrade."
                            : "About a video a day, which is about \(UsageFormat.percent(month)) of a month. \(UsageFormat.percent(meter.percentLeft)) left.",
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
                        "This style is you on camera. Postpilot writes the script and books the slot; you film it and tap Post.",
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

                if readyDestinations.isEmpty {
                    Label(
                        "No account yet: each video is still made, waits in your Library, and a notification tells you it's ready.",
                        systemImage: "bell.badge"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }

                moreOptions

                Text("You see every video before it posts. Pause or stop any time on Home.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
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
        if let caption { chips.append(caption.isNone ? "No captions" : "\(caption.name) captions") }
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
            case .yours:        step = .style
            case .destinations: step = .yours
            case .review:       step = .destinations
            }
        }
    }

    private func start() async {
        // The four required answers. The buttons that lead here cannot be
        // pressed without them, so this is the second lock, not the first.
        guard let chosen, let look, let voice, let caption else {
            failure = "Pick a style, a look, a voice and captions first."
            return
        }
        // No account is fine (5 Nov 2026): the videos are made and wait in the
        // Library, and a notification says each is ready.
        starting = true
        defer { starting = false }

        var brief = Self.goals.first { $0.id == goal }?.sentence ?? ""
        let musts = includes.compactMap { id in Self.includeQuestion.options.first { $0.id == id }?.label }.sorted()
        let nevers = avoids.compactMap { id in Self.avoidQuestion.options.first { $0.id == id }?.label }.sorted()
        if !musts.isEmpty { brief += " Every video must have: \(musts.joined(separator: ", "))." }
        // The writer keeps on-screen lines short when the words are burned in.
        if !caption.isNone { brief += " The spoken words are burned in as captions (\(caption.name.lowercased()))." }
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
            language: SeriesLanguage.all.first { $0.id == language }?.english,
            voiceID: voice.elevenLabsID,
            captionStyle: caption.id
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
