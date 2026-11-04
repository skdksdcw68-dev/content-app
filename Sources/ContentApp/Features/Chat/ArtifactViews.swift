import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

// MARK: - A run, while it runs

/// Long work, followed live.
///
/// Research takes minutes and a video can take several; the reply that started
/// either has long since finished streaming. So the turn carries the run's id,
/// and this card asks the server what has happened since it last looked --
/// every few seconds while it is on screen, and from the beginning when the
/// conversation is reopened. Every line is an event the worker wrote after
/// doing the thing, so nothing here can claim progress that did not happen.
///
/// When the run ends the result arrives as its own turn in the conversation
/// (the worker writes it there), so this card folds to a single line rather
/// than drawing the result a second time.
struct RunCard: View {
    let runId: UUID
    let kind: String?
    /// What a generation will be -- "image", "video", "audio" -- when the chat
    /// knows, so the count paces itself to it.
    var expectedKind: String? = nil
    /// One frame of a set of pictures, filling its cell of a two-column grid.
    var tile = false
    /// Told once, when the run reaches an end, so the conversation can pull in
    /// the result the worker wrote.
    var onFinished: () -> Void = {}
    /// True once it is seen working, false when that work ends -- for a set's
    /// "2 of 4 ready". A run that ended before the card opened says nothing.
    var onLive: (Bool) -> Void = { _ in }

    @Environment(AppSession.self) private var session
    @State private var steps: [TaskStep] = []
    @State private var lastSeq = 0
    @State private var progress: (done: Int, of: Int)?
    @State private var outcome: Outcome?
    /// The sites research has read so far, for their logos.
    @State private var sites: [String] = []

    private enum Outcome { case succeeded, failed }

    private var title: String {
        switch kind {
        case "research": "Researching"
        case "export":   "Making the file"
        case "generate": "Making it"
        default:         "Working"
        }
    }

    /// Whether the first read has come back. Until it has, nothing is drawn --
    /// a reopened conversation would otherwise flash "working" over every job
    /// that finished days ago, before learning it had.
    @State private var loaded = false

    var body: some View {
        // Only while the work is happening. When it ends the result arrives as
        // its own turn, so the card simply goes -- a "Made" tick left behind
        // above every result was the agent narrating itself.
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 0)
            if loaded && outcome == nil {
                working
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: outcome == nil)
        .task(id: runId) { await follow() }
    }

    @ViewBuilder
    private var working: some View {
        if kind == "generate" && tile {
            // One of a set: the frame fills its grid cell, the shape of a
            // portrait picture.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { MakingSheen() }
                .overlay { MakingProgress(expected: MakingProgress.expected(for: "image")) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if kind == "generate" && expectedKind == "audio" {
            // A voice or a track: the bubble it will arrive in, its bars
            // moving -- not a picture's frame (Abel, 4 Nov 2026).
            VStack(alignment: .leading, spacing: 8) {
                ShimmerText(text: "Making the voice")
                MakingVoice()
                TimeLeft(expected: MakingProgress.expected(for: "audio"))
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if kind == "generate" {
            // Making a picture or a video: the same card the video page shows
            // -- light down an empty frame and a count -- not a line of text
            // (Netro, 19 Oct 2026: "it says Queued instead of that beautiful
            // animation... match Sage, exactly"). Labelled the way ChatGPT
            // labels it while it works.
            VStack(alignment: .leading, spacing: 8) {
                ShimmerText(text: expectedKind == "image" ? "Creating image" : expectedKind == "video" ? "Creating video" : expectedKind == "audio" ? "Making the track" : "Creating…")
                MakingCard(kind: expectedKind)
                TimeLeft(expected: MakingProgress.expected(for: expectedKind), pings: expectedKind == "video")
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            thinkingTrail
        }
    }

    private var thinkingTrail: some View {
        // The word first and at once -- never "Queued" -- then what it is
        // doing, line by line, as the server reports it. No box around it:
        // it is the agent working, not a card to read.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                ShimmerText(text: title + "…")
                Spacer(minLength: 0)
            }

            ForEach(steps.suffix(4)) { step in
                HStack(spacing: 8) {
                    if step.isDone {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 14)
                    } else {
                        BreathingDot(size: 6)
                            .frame(width: 14)
                    }
                    Text(step.detail)
                        .font(.footnote)
                        .foregroundStyle(step.isDone ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // The sites it has read, the way ChatGPT shows them while it works
            // (Abel, 2 Nov 2026: "it shows the logos when it's thinking").
            if !sites.isEmpty {
                SourceLogos(domains: sites)
                    .transition(.opacity)
            }

            if let progress, progress.of > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.of))
                    .tint(Theme.accent)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: steps.count)
        .animation(.easeOut(duration: 0.2), value: sites.count)
    }

    /// Reads events after the last one drawn, until the run ends or the card
    /// leaves the screen -- `.task` cancels this loop on disappear, so a card
    /// scrolled away stops asking.
    private func follow() async {
        // Only a finish this card watched happen is reported. A reopened
        // conversation replays runs that ended days ago, and each of those
        // announcing itself would reload the conversation once per old run.
        var sawRunning = false
        while !Task.isCancelled, outcome == nil {
            let events = await session.runEvents(runId, after: lastSeq)
            for event in events {
                lastSeq = max(lastSeq, event.seq)
                absorb(event)
            }
            loaded = true
            if outcome != nil {
                if sawRunning {
                    onLive(false)
                    onFinished()
                }
                return
            }
            if !sawRunning { onLive(true) }
            sawRunning = true
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func absorb(_ event: RunEvent) {
        let payload = event.payload

        if let done = payload.done, let of = payload.of {
            progress = (done, of)
        }
        for domain in payload.domains ?? [] where !sites.contains(domain) {
            sites.append(domain)
        }

        switch event.type {
        case "done":
            finishSteps()
            outcome = .succeeded

        case "error":
            if payload.status == "failed" {
                finishSteps()
                outcome = .failed
            } else {
                // A step that failed and is being retried. Said in our words:
                // the provider's own text is for diagnosis, never for the chat.
                add("Hit a snag, trying again in a minute")
            }

        case "status":
            // "Queued" is true and worthless once anything else has happened.
            guard let detail = payload.detail, payload.step != "queued" else { return }
            add(detail)

        default:
            break
        }
    }

    private func add(_ detail: String) {
        guard steps.last?.detail != detail else { return }
        finishSteps()
        steps.append(TaskStep(kind: kind == "research" ? .reading : .writing, detail: detail))
    }

    private func finishSteps() {
        for index in steps.indices { steps[index].isDone = true }
    }
}

// MARK: - Something made

/// The result, drawn from the object rather than from prose.
///
/// One card per kind, because they are genuinely different things to look at:
/// a report is read, a file is opened, an image is looked at and maybe
/// animated, a video is played. What they share is that every one of them is
/// the actual thing -- not a sentence saying it is done.
struct ArtifactCard: View {
    let artifactId: UUID
    /// What the turn already knows it is: kind, and the picture's own shape.
    /// Used only to hold the right space while it loads.
    var expect: (kind: String?, width: Int?, height: Int?) = (nil, nil, nil)
    var onExport: (Artifact, String) -> Void = { _, _ in }
    var onAnimate: (Artifact) -> Void = { _ in }
    var onApprove: (Artifact) -> Void = { _ in }
    /// A picture as the reference for the next request. Nil hides the action.
    var onReference: ((Artifact) -> Void)? = nil
    /// One picture of a set, filling its cell of a two-column grid.
    var tile = false

    @Environment(AppSession.self) private var session
    @State private var artifact: Artifact?
    @State private var missing = false

    /// The frame the result will take, when the turn already knows what it is.
    private var placeholderSize: CGSize? {
        guard let kind = expect.kind, kind == "image" || kind == "video" else { return nil }
        return mediaSize(width: expect.width, height: expect.height)
    }

    var body: some View {
        // Read from memory first: the list recycles rows that leave the
        // screen, and one coming back should draw what it drew, not a spinner
        // and a second fetch.
        let known = artifact ?? MediaCache.shared.artifact(artifactId)

        Group {
            if let artifact = known {
                switch artifact.kind {
                case "research":
                    ReportCard(artifact: artifact, onExport: onExport)
                case "campaign", "plan":
                    CampaignCard(artifact: artifact, onExport: onExport, onApprove: onApprove)
                case "image":
                    ImageCard(artifact: artifact, onAnimate: onAnimate, onReference: onReference, tile: tile)
                case "video":
                    VideoCard(artifact: artifact)
                case "audio":
                    AudioCard(artifact: artifact)
                default:
                    FileCard(artifact: artifact)
                }
            } else if missing {
                Label("This is no longer available.", systemImage: "questionmark.folder")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if tile {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay { MakingSheen() }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                // The space the result will take, held from what the turn
                // already said it is.
                let waiting = placeholderSize
                let shape = RoundedRectangle(cornerRadius: waiting == nil ? Theme.cornerRadius : 14, style: .continuous)
                shape
                    .fill(Theme.surface)
                    .frame(width: waiting?.width, height: waiting?.height ?? 72)
                    .overlay { MakingSheen() }
                    // The number, the way ElevenLabs shows one: centred in the
                    // empty frame and nothing else. Only where there is a
                    // frame to centre it in -- on the 72pt strip that stands
                    // in for a file, the sheen alone says enough.
                    .overlay {
                        if waiting != nil {
                            MakingProgress(expected: MakingProgress.expected(for: expect.kind))
                        }
                    }
                    .clipShape(shape)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: artifactId) {
            guard known == nil else { return }
            artifact = await session.artifact(artifactId)
            missing = artifact == nil
        }
    }
}

// MARK: Report

private struct ReportCard: View {
    let artifact: Artifact
    let onExport: (Artifact, String) -> Void

    @State private var reading = ReportCard.openedForShots

    /// Debug only: a screenshot run opens the report itself (-openReport YES).
    private static var openedForShots: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "openReport")
        #else
        return false
        #endif
    }

    private var findings: [Artifact.Finding] { artifact.body.findings ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Research", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(artifact.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if !findings.isEmpty {
                Text("\(findings.count) question\(findings.count == 1 ? "" : "s") answered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Read") { reading = true }
                    .buttonStyle(RemiFilledButtonStyle())
                    .tint(Theme.accent)

                // The three formats as one menu, because three equal buttons
                // beside "Read" made the export look like the main thing.
                Menu {
                    Button { onExport(artifact, "docx") } label: {
                        Label("Word document", systemImage: "doc.richtext")
                    }
                    Button { onExport(artifact, "pdf") } label: {
                        Label("PDF", systemImage: "doc")
                    }
                    Button { onExport(artifact, "zip") } label: {
                        Label("ZIP with everything", systemImage: "doc.zipper")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote.weight(.semibold))
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surface)
        }
        .sheet(isPresented: $reading) {
            ReportSheet(artifact: artifact)
        }
    }
}

/// The whole report: the summary, then every question with its answer.
private struct ReportSheet: View {
    let artifact: Artifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(artifact.title)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    // Drawn as the report is written -- headings, bullets, a table.
                    if let summary = artifact.body.summary, !summary.isEmpty {
                        MarkdownText(text: summary)
                    }

                    ForEach(Array((artifact.body.findings ?? []).enumerated()), id: \.offset) { _, finding in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(finding.question)
                                .font(.subheadline.weight(.semibold))
                            MarkdownText(text: finding.answer)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Research")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: Campaign

/// A campaign's strategy, before a single post exists.
///
/// This is the confirm step made visible: what it is for, the angle, the mix
/// of themes and why. Nothing is written until the person approves it here,
/// and even then what gets written is a proposal they switch on themselves.
private struct CampaignCard: View {
    let artifact: Artifact
    let onExport: (Artifact, String) -> Void
    let onApprove: (Artifact) -> Void

    @Environment(AppSession.self) private var session
    @State private var standing: AppSession.StrategyStanding?

    private var facts: [String] {
        var out: [String] = []
        if let days = artifact.body.days { out.append("\(days) days") }
        if let cadence = artifact.body.cadence { out.append(cadence == 1 ? "1 a day" : "\(cadence) a day") }
        if let goal = artifact.body.goal { out.append(readable(goal)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Campaign", systemImage: "flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = artifact.body.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let angle = artifact.body.angle, !angle.isEmpty {
                Text(angle)
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let pillars = artifact.body.pillars, !pillars.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pillars, id: \.name) { pillar in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(pillar.name)
                                    .font(.footnote.weight(.semibold))
                                Spacer()
                                Text("\(pillar.share)%")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(pillar.share), total: 100)
                                .tint(Theme.accent)
                        }
                    }
                }
            }

            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surface)
        }
        .task(id: artifact.id) {
            if let id = artifact.body.strategyId { standing = await session.strategyStanding(id) }
        }
        .onChange(of: session.isPlanning) { _, planning in
            // Approving flips the strategy; read it again once the posts are
            // written so the card settles into what is now true.
            guard !planning, let id = artifact.body.strategyId else { return }
            Task { standing = await session.strategyStanding(id) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if session.isPlanning {
                ProgressView().controlSize(.small)
                Text("Writing the posts…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                switch standing {
                case .replaced:
                    Text("Replaced by a newer strategy")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .approved:
                    // Approved is not the same as written: the strategy can be
                    // agreed in one conversation and the posts written in the
                    // next. Both are offered, and writing again is a new
                    // proposal rather than an overwrite.
                    Button { onApprove(artifact) } label: {
                        Text("Write the posts")
                    }
                    .buttonStyle(RemiFilledButtonStyle())
                    .tint(Theme.accent)

                    NavigationLink { PlanView() } label: {
                        Label("Plan", systemImage: "calendar")
                    }
                    .buttonStyle(.bordered)
                case .draft, nil:
                    Button { onApprove(artifact) } label: {
                        Text("Approve and write the posts")
                    }
                    .buttonStyle(RemiFilledButtonStyle())
                    .tint(Theme.accent)
                    .disabled(standing == nil)
                }

                Menu {
                    Button { onExport(artifact, "docx") } label: {
                        Label("Word document", systemImage: "doc.richtext")
                    }
                    Button { onExport(artifact, "pdf") } label: {
                        Label("PDF", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Export")
            }
        }
        .font(.footnote.weight(.semibold))
        .controlSize(.small)
    }

    private func readable(_ goal: String) -> String {
        switch goal {
        case "followers": "Grow followers"
        case "customers": "Get customers"
        case "awareness": "Build awareness"
        case "launch":    "Promote a launch"
        default:          goal
        }
    }
}

// MARK: File

/// A document or a package, opened in Quick Look -- which also carries the
/// share button, so there is one control rather than two.
private struct FileCard: View {
    let artifact: Artifact

    @Environment(AppSession.self) private var session
    @State private var preview: URL?
    @State private var loading = false

    private var symbol: String {
        switch artifact.body.format {
        case "zip":  "doc.zipper"
        case "docx": "doc.richtext"
        default:     "doc.fill"
        }
    }

    private var detail: String {
        var parts: [String] = [(artifact.body.format ?? "file").uppercased()]
        if let files = artifact.body.manifest?.count { parts.append("\(files) files") }
        if let size = artifact.sizeLabel { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.body.filename ?? artifact.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.forward.square")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
            }
        }
        .buttonStyle(PressButtonStyle())
        .disabled(artifact.storagePath == nil || loading)
        .quickLookPreview($preview)
    }

    private func open() {
        loading = true
        Task {
            preview = await session.localCopy(of: artifact)
            loading = false
        }
    }
}

// MARK: - Under pictures

/// Grok's row under a picture or a set of them: save, share, like, dislike,
/// make more -- and what it used of the month, said once it is known (Abel,
/// 1 Nov 2026, approving the mockup).
struct PictureActions: View {
    let ids: [UUID]
    let rating: String?
    let onRate: (String, String?) -> Void
    let onAgain: () -> Void

    @Environment(AppSession.self) private var session
    @State private var artifacts: [Artifact] = []
    @State private var files: [URL] = []
    @State private var saves = 0
    @State private var saving = false

    var body: some View {
        HStack(spacing: 0) {
            button(saves > 0 ? "checkmark" : "arrow.down.to.line", label: ids.count > 1 ? "Save all" : "Save") { save() }
                .disabled(saving || artifacts.isEmpty)
            if !files.isEmpty, files.count == artifacts.count {
                ShareLink(items: files) { glyph("square.and.arrow.up") }
                    .accessibilityLabel("Share")
            } else {
                glyph("square.and.arrow.up").opacity(0.35)
            }
            button(rating == "up" ? "hand.thumbsup.fill" : "hand.thumbsup", label: "Good") { onRate("up", nil) }
            button(rating == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Not good") { onRate("down", nil) }
            button("arrow.clockwise", label: ids.count > 1 ? "Make \(ids.count) more" : "Make another") { onAgain() }
            Spacer(minLength: 8)
            if let used {
                Text("Used \(used) of your month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, -8)
        .sensoryFeedback(.success, trigger: saves)
        .task(id: ids) { await load() }
    }

    /// What the set cost, as a share of the month -- the provider's charge
    /// when it said, the quote otherwise.
    private var used: String? {
        let spent = artifacts.compactMap { artifact -> Double? in
            guard let cost = artifact.actualCost ?? artifact.estimatedCost, cost.unit == "usd" else { return nil }
            return cost.amount
        }
        guard !spent.isEmpty, let share = session.usageShare(usd: spent.reduce(0, +)) else { return nil }
        return UsageFormat.percent(share)
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 36)
            .contentShape(Rectangle())
    }

    private func load() async {
        var loaded: [Artifact] = []
        for id in ids {
            if let artifact = await session.artifact(id) { loaded.append(artifact) }
        }
        artifacts = loaded
        var copies: [URL] = []
        for artifact in loaded {
            if let url = session.cachedCopy(of: artifact) {
                copies.append(url)
            } else if let url = await session.localCopy(of: artifact) {
                copies.append(url)
            }
        }
        files = copies
    }

    private func save() {
        saving = true
        Task {
            var all = true
            for artifact in artifacts {
                if case .saved = await session.saveToPhotos(artifact) { continue }
                all = false
            }
            if all { saves += 1 }
            saving = false
        }
    }
}

// MARK: - Attachments on a turn

/// The pictures somebody attached, small, above what they said.
struct AttachmentStrip: View {
    let paths: [String]
    /// On the person's own turn, the pictures sit on their side of the page.
    /// A horizontal scroll view always starts its content at the leading edge,
    /// which is why they used to appear on the agent's side.
    var trailing = false
    var onRemove: ((String) -> Void)? = nil

    var body: some View {
        if trailing {
            // ChatGPT's sent picture: a rounded thumbnail on their side, big
            // enough to see what it is, that opens full screen. One on its own
            // is taller; several sit smaller side by side.
            HStack(spacing: 6) {
                Spacer(minLength: 44)
                ForEach(paths, id: \.self) { path in
                    AttachmentThumb(
                        path: path,
                        size: paths.count == 1 ? CGSize(width: 120, height: 150) : CGSize(width: 92, height: 115),
                        opens: true
                    )
                }
            }
        } else {
            scrolling
        }
    }

    private var scrolling: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(paths, id: \.self) { path in
                    AttachmentThumb(path: path)
                        .overlay(alignment: .topTrailing) {
                            if let onRemove {
                                Button { onRemove(path) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.system(size: 18))
                                }
                                .offset(x: 5, y: -5)
                                .accessibilityLabel("Remove picture")
                            }
                        }
                }
            }
            .padding(.top, onRemove == nil ? 0 : 6)
            .padding(.trailing, onRemove == nil ? 0 : 6)
        }
    }
}

private struct AttachmentThumb: View {
    let path: String
    var size = CGSize(width: 64, height: 64)
    /// Tapping opens it full screen -- on a sent turn, not in the composer.
    var opens = false

    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var picture: UIImage?
    @State private var viewing = false

    private var pixels: CGFloat { max(size.width, size.height) * displayScale }
    private var corner: CGFloat { size.width >= 90 ? 18 : 10 }

    var body: some View {
        let shown = picture ?? MediaCache.shared.image(MediaCache.key(path, "\(Int(pixels))"))

        ZStack {
            if let shown {
                Image(uiImage: shown).resizable().scaledToFill()
            } else {
                Theme.surface
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onTapGesture {
            if opens, shown != nil { viewing = true }
        }
        .accessibilityAddTraits(opens ? .isButton : [])
        .task(id: path) {
            guard picture == nil else { return }
            picture = await session.attachmentThumbnail(path, longest: pixels)
        }
        .fullScreenCover(isPresented: $viewing) {
            SentPictureViewer(path: path, preview: shown)
        }
    }
}

/// A picture they sent, full screen, the way ChatGPT opens one: black, the
/// picture edge to edge, close at the top left, Share at the bottom. Drag down
/// to put it away.
private struct SentPictureViewer: View {
    let path: String
    var preview: UIImage?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picture: UIImage?
    @State private var drag: CGFloat = 0

    var body: some View {
        let shown = picture ?? preview

        ZStack {
            Color.black
                .opacity(1 - min(0.7, abs(drag) / 500))
                .ignoresSafeArea()
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
                    .offset(y: drag)
            } else {
                ProgressView().tint(.white)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if abs(value.translation.height) > 120 {
                        dismiss()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { drag = 0 }
                    }
                }
        )
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .opacity(drag == 0 ? 1 : 0)
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) {
            if let shown {
                ShareLink(item: Image(uiImage: shown), preview: SharePreview("Picture", image: Image(uiImage: shown))) {
                    Text("Share")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
                .opacity(drag == 0 ? 1 : 0)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .presentationBackground(.clear)
        .task {
            guard picture == nil else { return }
            picture = await session.attachmentThumbnail(path, longest: 2400)
        }
    }
}
