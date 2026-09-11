import AVKit
import QuickLook
import SwiftUI

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
    /// Told once, when the run reaches an end, so the conversation can pull in
    /// the result the worker wrote.
    var onFinished: () -> Void = {}

    @Environment(AppSession.self) private var session
    @State private var steps: [TaskStep] = []
    @State private var lastSeq = 0
    @State private var progress: (done: Int, of: Int)?
    @State private var outcome: Outcome?

    private enum Outcome { case succeeded, failed }

    private var title: String {
        switch kind {
        case "research": "Researching"
        case "export":   "Making the file"
        case "generate": "Making it"
        default:         "Working"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let outcome {
                Label(
                    outcome == .succeeded ? finishedLine : "Stopped",
                    systemImage: outcome == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(outcome == .succeeded ? Theme.accent : .secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("Keeps going if you leave")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let progress, progress.of > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.of))
                        .tint(Theme.accent)
                }

                if !steps.isEmpty {
                    TaskTrail(steps: steps)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surface)
        }
        .animation(.easeOut(duration: 0.2), value: steps.count)
        .task(id: runId) { await follow() }
    }

    private var finishedLine: String {
        switch kind {
        case "research": "Research finished"
        case "export":   "File ready"
        case "generate": "Made"
        default:         "Finished"
        }
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
            if outcome != nil {
                if sawRunning { onFinished() }
                return
            }
            sawRunning = true
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func absorb(_ event: RunEvent) {
        let payload = event.payload

        if let done = payload.done, let of = payload.of {
            progress = (done, of)
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
            guard let detail = payload.detail, payload.step != "queued" || steps.isEmpty else { return }
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
    var onExport: (Artifact, String) -> Void = { _, _ in }
    var onAnimate: (Artifact) -> Void = { _ in }
    var onApprove: (Artifact) -> Void = { _ in }

    @Environment(AppSession.self) private var session
    @State private var artifact: Artifact?
    @State private var missing = false

    var body: some View {
        Group {
            if let artifact {
                switch artifact.kind {
                case "research":
                    ReportCard(artifact: artifact, onExport: onExport)
                case "campaign", "plan":
                    CampaignCard(artifact: artifact, onExport: onExport, onApprove: onApprove)
                case "image":
                    ImageCard(artifact: artifact, onAnimate: onAnimate)
                case "video":
                    VideoCard(artifact: artifact)
                default:
                    FileCard(artifact: artifact)
                }
            } else if missing {
                Label("This is no longer available.", systemImage: "questionmark.folder")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
                    .frame(height: 72)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: artifactId) {
            guard artifact == nil else { return }
            artifact = await session.artifact(artifactId)
            missing = artifact == nil
        }
    }
}

// MARK: Report

private struct ReportCard: View {
    let artifact: Artifact
    let onExport: (Artifact, String) -> Void

    @State private var reading = false

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
                    .buttonStyle(.borderedProminent)
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

                    if let summary = artifact.body.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    ForEach(Array((artifact.body.findings ?? []).enumerated()), id: \.offset) { _, finding in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(finding.question)
                                .font(.subheadline.weight(.semibold))
                            Text(finding.answer)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
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
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                    NavigationLink { PlanView() } label: {
                        Label("Plan", systemImage: "calendar")
                    }
                    .buttonStyle(.bordered)
                case .draft, nil:
                    Button { onApprove(artifact) } label: {
                        Text("Approve and write the posts")
                    }
                    .buttonStyle(.borderedProminent)
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

// MARK: Image

private struct ImageCard: View {
    let artifact: Artifact
    let onAnimate: (Artifact) -> Void

    @Environment(AppSession.self) private var session
    @State private var remote: URL?
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { preview = await session.localCopy(of: artifact) }
            } label: {
                AsyncImage(url: remote) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Rectangle().fill(Theme.surface)
                            .aspectRatio(9.0 / 16.0, contentMode: .fit)
                            .overlay { ProgressView().controlSize(.small) }
                    }
                }
                .frame(maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button { onAnimate(artifact) } label: {
                    Label("Animate", systemImage: "play.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                if let label = artifact.body.modelLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.footnote.weight(.semibold))
            .controlSize(.small)
        }
        .task(id: artifact.id) {
            if let path = artifact.storagePath { remote = await session.signedURL(for: path) }
        }
        .quickLookPreview($preview)
    }
}

// MARK: Video

private struct VideoCard: View {
    let artifact: Artifact

    @Environment(AppSession.self) private var session
    @State private var player: AVPlayer?
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Rectangle().fill(Theme.surface)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    Task { preview = await session.localCopy(of: artifact) }
                } label: {
                    Label("Save or share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Text(facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .controlSize(.small)
        }
        .task(id: artifact.id) {
            guard player == nil, let path = artifact.storagePath,
                  let url = await session.signedURL(for: path) else { return }
            player = AVPlayer(url: url)
        }
        .quickLookPreview($preview)
    }

    /// The real shape, read off the file on the server, rather than assumed.
    private var aspect: CGFloat {
        if let w = artifact.body.width, let h = artifact.body.height, w > 0, h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        return 9.0 / 16.0
    }

    private var facts: String {
        var parts: [String] = []
        if let seconds = artifact.body.seconds { parts.append("\(Int(seconds.rounded()))s") }
        if let label = artifact.body.modelLabel { parts.append(label) }
        if let cost = artifact.actualCost, let amount = cost.amount, let unit = cost.unit {
            parts.append("\(amount.formatted()) \(unit)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Attachments on a turn

/// The pictures somebody attached, small, above what they said.
struct AttachmentStrip: View {
    let paths: [String]
    var onRemove: ((String) -> Void)? = nil

    var body: some View {
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

    @Environment(AppSession.self) private var session
    @State private var url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Theme.surface
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: path) { url = await session.signedURL(for: path, expiresIn: 600) }
    }
}
