import SwiftUI
import PhotosUI

/// A video from the phone, all the way into the plan, on one screen.
///
/// Each step is ticked when its request returns, not on a timer: Uploading is
/// the file reaching storage, Understanding is Autocast having written the
/// post and placed it, Preparing is the video attached for TikTok, Validating
/// is the account check. Then the post itself takes over this screen, with
/// Review and approve as the one thing left to do.
struct UploadFlowView: View {
    @Environment(AppSession.self) private var session

    enum Step: Int, CaseIterable {
        case upload, understand, prepare, validate

        var title: String {
            switch self {
            case .upload:     "Uploading"
            case .understand: "Understanding"
            case .prepare:    "Preparing content"
            case .validate:   "Validating"
            }
        }

        var working: String {
            switch self {
            case .upload:     "Sending the video to your library"
            case .understand: "Watching it and writing the post"
            case .prepare:    "Attaching it for TikTok"
            case .validate:   "Checking it against your account"
            }
        }
    }

    @State private var pickerItem: PhotosPickerItem?
    @State private var note = ""
    @State private var poster: UIImage?
    @State private var facts: VideoFacts?
    @State private var current: Step?
    @State private var finished: Set<Step> = []
    @State private var details: [Step: String] = [:]
    @State private var failure: (step: Step, message: String)?
    @State private var report: ValidationReport?
    @State private var done: UUID?

    private var running: Bool { current != nil }

    var body: some View {
        Group {
            if let done {
                PostDetailView(postID: done)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        picker
                        if poster != nil || running || failure != nil { progress }
                        if let report { checks(report) }
                    }
                    .screenGutter()
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .background(Color.canvas.ignoresSafeArea())
                .navigationTitle("Upload a video")
                .navigationBarTitleDisplayMode(.inline)
                .pushedPage()
            }
        }
        .task(id: pickerItem) { await start() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your video, posted for \(session.brand?.name ?? "your brand")")
                .font(.title2.bold())
            Text("Autocast watches it, writes the caption from what you've told it, puts it in your plan at the next open time, and checks it with TikTok. You approve it once; Autopilot does the rest.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.track)
                    if let poster {
                        Image(uiImage: poster).resizable().scaledToFill()
                    } else {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Anything Autocast should know about it? (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...5)
                        .font(.subheadline)
                        .disabled(running)

                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label(poster == nil ? "Choose a video" : "Choose another", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(Theme.onAccent)
                    }
                    .disabled(running)

                    if let facts {
                        Text("\(Int(facts.duration.rounded()))s · \(facts.width)×\(facts.height)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(Color.raised, in: RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Step.allCases, id: \.self) { step in
                HStack(alignment: .top, spacing: 12) {
                    marker(step).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.subheadline.weight(current == step ? .semibold : .regular))
                            .foregroundStyle(isPending(step) ? Color.secondary : Color.primary)
                        if let failure, failure.step == step {
                            Text(failure.message).font(.caption).foregroundStyle(.red)
                        } else if current == step {
                            Text(step.working).font(.caption).foregroundStyle(.secondary)
                        } else if let detail = details[step] {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if failure != nil {
                Button("Try again") { Task { await start(retry: true) } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }

    private func checks(_ report: ValidationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(report.ok ? "Ready for your review" : "Needs a fix first")
                .font(.headline)
            ForEach(report.checks) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.ok ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title).font(.subheadline)
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }

    @ViewBuilder
    private func marker(_ step: Step) -> some View {
        if failure?.step == step {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 18)).foregroundStyle(.red)
        } else if finished.contains(step) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
        } else if current == step {
            BreathingDot(size: 8)
        } else {
            Circle().strokeBorder(Color(uiColor: .tertiaryLabel), lineWidth: 1.5).frame(width: 16, height: 16)
        }
    }

    private func isPending(_ step: Step) -> Bool {
        current != step && !finished.contains(step) && failure?.step != step
    }

    // MARK: - The run

    @State private var movieURL: URL?
    @State private var storagePath: String?
    @State private var postID: UUID?

    private func start(retry: Bool = false) async {
        if !retry {
            guard let pickerItem else { return }
            reset()
            do {
                guard let movie = try await pickerItem.loadTransferable(type: Movie.self) else { return }
                movieURL = movie.url
                let read = try await VideoFacts.read(movie.url)
                facts = read
                poster = read.poster
            } catch {
                failure = (.upload, "That video couldn't be read.")
                return
            }
        }
        failure = nil
        guard let url = movieURL, let facts else { return }

        do {
            if storagePath == nil {
                current = .upload
                storagePath = try await session.uploadVideo(at: url)
                details[.upload] = String(format: "%.1f MB sent", Double((try? Data(contentsOf: url).count) ?? 0) / 1_048_576)
                finished.insert(.upload)
            }
            guard let path = storagePath else { return }

            if postID == nil {
                current = .understand
                let understood = try await session.understand(video: facts, path: path, note: note.isEmpty ? nil : note)
                postID = understood.postId
                let when = understood.scheduledFor.flatMap(PostgresTimestamp.parse)
                details[.understand] = "“\(understood.hook)” · in \(understood.planTitle)"
                    + (when.map { " for " + LoopTimeline.format($0, timezone) } ?? "")
                finished.insert(.understand)
            }
            guard let post = postID else { return }

            if !finished.contains(.prepare) {
                current = .prepare
                let prepared = try await session.prepare(post: post, path: path, video: facts)
                guard prepared.ok else {
                    current = nil
                    failure = (.prepare, "Connect TikTok to \(session.brand?.name ?? "this brand") first, then try again.")
                    return
                }
                details[.prepare] = "Ready for @\(prepared.username ?? "your account")"
                finished.insert(.prepare)
            }

            current = .validate
            let result = try await session.validate(post: post)
            report = result
            details[.validate] = result.ok ? "\(result.checks.count) checks passed" : "Something needs fixing"
            finished.insert(.validate)
            current = nil

            if result.ok {
                try? await Task.sleep(for: .milliseconds(700))
                try? FileManager.default.removeItem(at: url)
                await session.refreshPlan()
                withAnimation(.snappy(duration: 0.3)) { done = post }
            }
        } catch {
            let step = current ?? .upload
            current = nil
            failure = (step, session.readableMessage(error))
        }
    }

    private func reset() {
        if let movieURL { try? FileManager.default.removeItem(at: movieURL) }
        movieURL = nil
        storagePath = nil
        postID = nil
        facts = nil
        poster = nil
        current = nil
        finished = []
        details = [:]
        failure = nil
        report = nil
    }

    private var timezone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }
}
