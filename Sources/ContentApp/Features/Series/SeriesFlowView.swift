import SwiftUI

/// Start a series: pick a style, say where it posts, how long each video is
/// and what it is for -- then it writes the month, makes each video the day
/// before its slot, and asks for one tap before anything goes out.
///
/// Abel, 23 Sep 2026: "they choose the style... they will be asked to
/// connect TikTok, YouTube and IG... the duration, or they hit decide for
/// me... every day it will generate the content they chose and it posts."
/// Onboarding's shape: a bar at the top, one question per screen.
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
        case style, destinations, length, goal, review

        var progress: Double { Double(rawValue + 1) / Double(Step.allCases.count + 1) }

        var title: String {
            switch self {
            case .style:        "Pick a style"
            case .destinations: "Where it posts"
            case .length:       "How long"
            case .goal:         "What it's for"
            case .review:       "Ready"
            }
        }
    }

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
            .background(Theme.canvas)
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
                        Text("Writing your first month in \(chosen?.name ?? "this style")…")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .task { if templates == nil { templates = await session.templates() } }
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
        case .goal:         whatFor
        case .review:       review
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

    private var whereTo: some View {
        FlowStep(
            title: "Where should it post?",
            subtitle: "Pick every account. The ones not connected yet can be connected right here.",
            button: destinations.isEmpty ? "Pick at least one" : "Continue",
            tint: destinations.isEmpty ? Color.secondary : Theme.accent,
            action: { if !destinations.isEmpty { step = .length } }
        ) {
            VStack(spacing: 10) {
                ForEach(Platform.allCases) { platform in
                    let connected = session.connection(for: platform) != nil
                    HStack(spacing: 12) {
                        DetailedOption(
                            option: OnboardingQuestion.Option(
                                id: platform.rawValue,
                                label: "\(platform.networkName) · \(platform.displayName)",
                                symbol: platform.symbolName,
                                detail: connected ? "Connected" : "Not connected yet"
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
                        if !connected {
                            Button {
                                Task { await session.connect(platform) }
                            } label: {
                                Text(session.isConnecting ? "…" : "Connect")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.onAccent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(Theme.accent, in: Capsule())
                            }
                            .buttonStyle(SoftPressStyle())
                            .disabled(session.isConnecting)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var howLong: some View {
        FlowStep(
            title: "How long should each video be?",
            subtitle: "Or let Autocast pick per post.",
            button: "Continue",
            action: { step = .goal }
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

    private var review: some View {
        FlowStep(
            title: "\(chosen?.name ?? "Your series"), every day",
            subtitle: "It writes 30 days now, makes each video the day before its slot, and asks you to tap Post. Nothing goes out on its own.",
            button: "Start the series",
            isBusy: starting,
            action: { Task { await start() } }
        ) {
            VStack(spacing: 10) {
                ReviewRow(label: "Style", value: chosen?.name ?? "—")
                ReviewRow(label: "Posts to", value: destinations.sorted().compactMap { Platform(rawValue: $0)?.networkName }.joined(separator: ", "))
                ReviewRow(label: "Length", value: decideLength
                          ? "\(chosen?.workflow?.durationSeconds ?? 30) seconds, the style's own"
                          : "\(length ?? 30) seconds")
                ReviewRow(label: "Goal", value: Self.goals.first { $0.id == goal }?.label ?? "—")
                ReviewRow(label: "Videos", value: session.hasWorkingGenerator ? "Made with your generator" : "Needs a generator")

                // The style's workflow, as the plan every video follows.
                if let steps = chosen?.workflow?.steps, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How every video gets made")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, stepText in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, alignment: .trailing)
                                Text(stepText)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Moving

    private func back() {
        withAnimation(.snappy(duration: 0.25)) {
            switch step {
            case .style:        break
            case .destinations: step = .style
            case .length:       step = .destinations
            case .goal:         step = .length
            case .review:       step = .goal
            }
        }
    }

    private func start() async {
        guard let chosen else { return }
        starting = true
        defer { starting = false }

        let sentence = Self.goals.first { $0.id == goal }?.sentence ?? ""
        guard let proposal = await session.proposePlan(
            brief: sentence,
            days: min(30, session.subscription?.limits.planDays ?? 30),
            postsPerDay: 1,
            platforms: Array(destinations).sorted(),
            template: chosen.slug,
            durationSeconds: decideLength ? nil : length
        ) else { return }

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

/// A style on the grid: its picture (or its symbol until there is one),
/// its name, and one line.
/// The cover a style wears until its photograph exists.
///
/// Not a placeholder: a deliberate two-tone wash with the style's own symbol
/// cut out of it, coloured from the slug so the same style is always the same
/// colour and no two neighbours collide. Black and white surfaces everywhere
/// else in the app, so this stays low and desaturated rather than becoming the
/// coloured tiles Abel called childish on 22 Sep.
private struct StyleCover: View {
    let slug: String
    let symbol: String

    /// Stable across launches: `hashValue` is seeded per process and would
    /// repaint every style a different colour each time the app opened.
    private var hue: Double {
        var total = 0
        for byte in slug.utf8 { total = (total &* 31 &+ Int(byte)) % 3600 }
        return Double(total) / 3600
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.30, brightness: 0.34),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: 0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }
}

private struct StyleTile: View {
    let template: ContentTemplate
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let image = UIImage(named: template.artName) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        // A cover of its own rather than a grey hole. The
                        // photograph is better and is coming, but a style
                        // without one still has to look like somebody meant
                        // it (Abel, 23 Sep 2026: "why does some of them
                        // doesn't have images").
                        StyleCover(slug: template.slug, symbol: template.symbol)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // What it is for, on the tile, now that the shelf label
                    // above it is gone.
                    Text(template.category.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(template.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            }
            .background(Color.raised)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isChosen ? Theme.accent : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel("\(template.name). \(template.tagline)")
        .accessibilityAddTraits(isChosen ? .isSelected : [])
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
