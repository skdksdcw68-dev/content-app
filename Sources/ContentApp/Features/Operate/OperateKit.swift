import SwiftUI
import AVKit

/// Pieces shared by the Plan, the post detail, the upload flow and Autopilot.

// MARK: - Stage chip

struct StageChip: View {
    let stage: PipelineStage
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if stage.isWorking {
                BreathingDot(size: 6)
            } else {
                Image(systemName: stage.symbol)
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
            }
            Text(stage.title)
                .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(stage.tint)
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3 : 4)
        .background(stage.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A small grey capsule for facts: platform, format, frequency.
struct FactChip: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.track, in: Capsule())
    }
}

// MARK: - Whose move

/// The line that separates what Autocast is doing from what you need to do.
struct MoveBanner: View {
    let yours: Bool
    let text: String
    var action: (title: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: yours ? "hand.point.right.fill" : "gearshape.2.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(yours ? Color.orange : Color.secondary)
                .frame(width: 34, height: 34)
                .background((yours ? Color.orange : Color.secondary).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(yours ? "Your move" : "Autocast is on it")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(RemiFilledButtonStyle())
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .raisedCard(radius: Style.rowCard)
    }
}

// MARK: - The loop, step by step

/// Understanding → Preparing → Validating → Your approval → Waiting for
/// schedule → Publishing → Verifying → Published, each one ticked only when
/// the row that proves it exists.
struct LoopTimeline: View {
    let post: BoardPost
    var timezone: TimeZone = .current

    enum StepState { case done(Date?), active, waiting, failed }

    struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let state: StepState
        let yours: Bool
    }

    private func event(_ kinds: String...) -> ActivityEvent? {
        (post.activity ?? []).last { kinds.contains($0.kind) }
    }

    private var rank: Int {
        switch post.stage {
        case .draft:          0
        case .scheduled:      1
        case .generating:     2
        case .readyForReview: 3
        case .approved:       4
        case .readyToPublish: 5
        case .publishing:     6
        case .verifying:      7
        case .published:      8
        case .inDrafts:       8
        case .needsAttention: -1
        }
    }

    var steps: [Step] {
        let uploaded = post.mediaStrategy == "user_upload"
        var result: [Step] = []

        let understood = event("understood")
        result.append(Step(
            id: "understand",
            title: uploaded ? "Understanding" : "Planning",
            detail: uploaded ? understood?.detail : "Written into the plan",
            state: .done(understood?.date),
            yours: false
        ))

        let prepared = event("prepared", "generated")
        let prepareDetail: String
        if post.media != nil {
            prepareDetail = prepared?.detail ?? "Video attached"
        } else {
            prepareDetail = post.stage == .generating ? "Making the video" : "Needs a video"
        }
        result.append(Step(
            id: "prepare",
            title: "Preparing content",
            detail: prepareDetail,
            state: progress(done: post.media != nil, at: prepared?.date, active: post.stage == .generating),
            yours: false
        ))

        let validated = event("validated", "validation_failed")
        let validateState: StepState
        if validated?.kind == "validation_failed" {
            validateState = .failed
        } else {
            validateState = progress(done: validated != nil || rank >= 4, at: validated?.date, active: false)
        }
        result.append(Step(
            id: "validate",
            title: "Validating",
            detail: validated?.detail,
            state: validateState,
            yours: false
        ))

        let approved = event("approved")
        let approveDetail: String? = post.approved
            ? approved?.detail
            : (post.stage == .readyForReview ? "Waiting for you" : nil)
        result.append(Step(
            id: "approve",
            title: "Your approval",
            detail: approveDetail,
            state: progress(done: post.approved, at: approved?.date, active: post.stage == .readyForReview),
            yours: true
        ))

        let scheduled = event("scheduled", "rescheduled")
        let scheduleDetail: String? = post.when.map { "Goes out " + Self.format($0, timezone) }
        result.append(Step(
            id: "schedule",
            title: "Waiting for schedule",
            detail: scheduleDetail,
            state: progress(done: rank >= 6, at: scheduled?.date, active: post.stage == .readyToPublish),
            yours: false
        ))

        let publishing = event("publishing")
        let publishDetail: String? = publishing == nil ? nil : "Uploaded to " + post.platformName
        result.append(Step(
            id: "publish",
            title: "Publishing",
            detail: publishDetail,
            state: progress(done: rank >= 7, at: publishing?.date, active: post.stage == .publishing),
            yours: false
        ))

        let verifying = event("verifying")
        result.append(Step(
            id: "verify",
            title: "Verifying",
            detail: rank >= 7 ? verifying?.detail : nil,
            state: progress(done: rank >= 8, at: verifying?.date, active: post.stage == .verifying),
            yours: false
        ))

        let published = event("published")
        var publishedParts: [String] = []
        if post.stage == .published {
            if let name = post.privacyName { publishedParts.append("Visible to: " + name) }
            if let detail = published?.detail, !detail.isEmpty { publishedParts.append(detail) }
        }
        result.append(Step(
            id: "published",
            title: post.stage == .inDrafts ? "Sent to your TikTok drafts" : "Published",
            detail: publishedParts.isEmpty ? nil : publishedParts.joined(separator: " · "),
            state: progress(done: post.stage == .published || post.stage == .inDrafts,
                            at: post.publishedDate ?? published?.date, active: false),
            yours: false
        ))

        // A problem marks the first step that did not happen.
        if post.stage == .needsAttention, let index = result.firstIndex(where: {
            if case .done = $0.state { return false }
            return true
        }) {
            let step = result[index]
            result[index] = Step(id: step.id, title: step.title, detail: post.problem ?? step.detail, state: .failed, yours: step.yours)
        }
        return result
    }

    private func progress(done: Bool, at date: Date?, active: Bool) -> StepState {
        if done { return .done(date) }
        return active ? .active : .waiting
    }

    var body: some View {
        let all = steps
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(all.enumerated()), id: \.element.id) { index, step in
                row(step, isLast: index == all.count - 1)
            }
        }
    }

    private func row(_ step: Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker(step.state)
                    .frame(width: 22, height: 22)
                if !isLast {
                    Rectangle()
                        .fill(lineColor(step.state))
                        .frame(width: 2)
                        .frame(minHeight: 18, maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.subheadline.weight(isActive(step.state) ? .semibold : .regular))
                        .foregroundStyle(isWaiting(step.state) ? Color.secondary : Color.primary)
                    if step.yours {
                        Text("You")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    if case .done(let date?) = step.state {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isFailed(step.state) ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
    }

    @ViewBuilder
    private func marker(_ state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.green)
        case .active:
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
                BreathingDot(size: 8)
            }
            .frame(width: 18, height: 18)
        case .waiting:
            Circle()
                .strokeBorder(Color(uiColor: .tertiaryLabel), lineWidth: 1.5)
                .frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.red)
        }
    }

    private func lineColor(_ state: StepState) -> Color {
        if case .done = state { return Color.green.opacity(0.5) }
        return Color.track
    }

    private func isActive(_ state: StepState) -> Bool {
        if case .active = state { return true }
        return false
    }

    private func isWaiting(_ state: StepState) -> Bool {
        if case .waiting = state { return true }
        return false
    }

    private func isFailed(_ state: StepState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    static func format(_ date: Date, _ timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - The video

/// The post's own video: a poster frame, and the player when tapped.
struct PostMediaView: View {
    let media: BoardPost.Media?
    var concept: String? = nil
    var height: CGFloat = 420

    @Environment(AppSession.self) private var session
    @State private var url: URL?
    @State private var poster: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
                playButton
            } else if media != nil {
                ProgressView().tint(.white)
            } else {
                noVideo
            }
        }
        .frame(width: height * 9 / 16, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .task(id: media?.path) { await load() }
        .onDisappear { player?.pause() }
    }

    private var playButton: some View {
        Button {
            guard let url else { return }
            let next = AVPlayer(url: url)
            player = next
            next.play()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel("Play video")
    }

    private var noVideo: some View {
        VStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 30, weight: .light))
            Text("No video yet")
                .font(.subheadline.weight(.semibold))
            if let concept, !concept.isEmpty {
                Text(concept)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .opacity(0.7)
                    .lineLimit(5)
                    .padding(.horizontal, 14)
            }
        }
        .foregroundStyle(.white)
    }

    private func load() async {
        guard let media else { return }
        guard let signed = await session.mediaURL(media) else { return }
        url = signed
        poster = await Self.posterFrame(signed)
    }

    static func posterFrame(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        guard let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

/// A small poster for list rows.
struct PostThumb: View {
    let media: BoardPost.Media?
    let stage: PipelineStage
    var width: CGFloat = 78

    @Environment(AppSession.self) private var session
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color.track, Color.track.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                Image(systemName: media == nil ? (stage == .generating ? "sparkles" : "film") : "play.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: width, height: width * 16 / 9)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: media?.path) {
            guard let media, let url = await session.mediaURL(media) else { return }
            poster = await PostMediaView.posterFrame(url)
        }
    }
}

// MARK: - Review and approve

/// Everything TikTok's audit asks for, around the exact post: whose account,
/// what it says, who can see it, and when it goes out.
struct ReviewSheet: View {
    let post: BoardPost
    var onApproved: () -> Void = {}

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    enum When: Hashable { case planned, soon, hour, custom }

    @State private var info: CreatorInfo?
    @State private var loadFailed = false
    @State private var privacy: String?
    @State private var isAIGC = false
    @State private var disableComment = false
    @State private var disableDuet = false
    @State private var disableStitch = false
    @State private var when: When = .planned
    @State private var custom = Date().addingTimeInterval(3600)
    @State private var approving = false

    private var plannedIsFuture: Bool {
        (post.when ?? .distantPast) > Date().addingTimeInterval(120)
    }

    private var timezone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    private var runAt: Date? {
        switch when {
        case .planned: plannedIsFuture ? nil : Date().addingTimeInterval(15 * 60)
        case .soon:    Date().addingTimeInterval(15 * 60)
        case .hour:    Date().addingTimeInterval(60 * 60)
        case .custom:  custom
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let info {
                    form(info)
                } else if loadFailed {
                    ContentUnavailableView("Couldn't reach TikTok", systemImage: "wifi.exclamationmark",
                                           description: Text("Check the connection in You → Accounts and try again."))
                } else {
                    VStack(spacing: 12) {
                        BreathingDot(size: 10)
                        Text("Checking what your account allows")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Review and approve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await load() }
        .toggleStyle(SwitchToggleStyle(tint: Color(uiColor: .systemGreen)))
    }

    private func form(_ info: CreatorInfo) -> some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    PostThumb(media: post.media, stage: post.stage, width: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(post.hook)
                            .font(.subheadline.weight(.semibold))
                        Text(post.publishText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("What will be published")
            }

            Section {
                CreatorHeader(info: info)
            } footer: {
                Text("This is the \(post.platformName) account it will be posted from.")
            }

            Section {
                ForEach(info.privacyOptions, id: \.self) { option in
                    Button {
                        privacy = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CreatorInfo.label(for: option)).foregroundStyle(Color.primary)
                                Text(CreatorInfo.detail(for: option)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if privacy == option {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Who can see this")
            } footer: {
                if !info.privacyOptions.contains("PUBLIC_TO_EVERYONE") {
                    Text("Public posting opens once TikTok has reviewed Autocast. These are the options your account offers today.")
                }
            }

            Section {
                Picker("When", selection: $when) {
                    Text(plannedIsFuture ? "As planned · \(LoopTimeline.format(post.when ?? .now, timezone))" : "In 15 minutes").tag(When.planned)
                    if plannedIsFuture { Text("In 15 minutes").tag(When.soon) }
                    Text("In 1 hour").tag(When.hour)
                    Text("Pick a time").tag(When.custom)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if when == .custom {
                    DatePicker("Time", selection: $custom, in: Date().addingTimeInterval(120)..., displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, timezone)
                }
            } header: {
                Text("When")
            } footer: {
                Text("Autopilot publishes it at this time, then checks with \(post.platformName) that it went live. You don't need the app open.")
            }

            Section("Settings") {
                Toggle("AI-generated content", isOn: $isAIGC)
                Toggle("Turn off comments", isOn: $disableComment).disabled(info.commentDisabled)
                Toggle("Turn off Duet", isOn: $disableDuet).disabled(info.duetDisabled)
                Toggle("Turn off Stitch", isOn: $disableStitch).disabled(info.stitchDisabled)
            }

            Section {
                Button {
                    Task { await approve() }
                } label: {
                    HStack {
                        if approving { ProgressView().tint(Theme.onAccent) }
                        Text(approving ? "Approving…" : "Approve and schedule")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .controlSize(.large)
                .disabled(privacy == nil || approving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("You're approving this exact video and caption. If either changes, Autocast holds it and asks again.")
            }
        }
    }

    private func load() async {
        guard let connection = session.tiktok else {
            loadFailed = true
            return
        }
        guard let fetched = await session.creatorInfo(for: connection.id) else {
            loadFailed = true
            return
        }
        info = fetched
        privacy = fetched.privacyOptions.contains(post.privacy ?? "SELF_ONLY")
            ? (post.privacy ?? "SELF_ONLY")
            : fetched.privacyOptions.first
        isAIGC = post.media?.source == "generated"
        disableComment = fetched.commentDisabled
        disableDuet = fetched.duetDisabled
        disableStitch = fetched.stitchDisabled
        if !plannedIsFuture { when = .planned }
    }

    private func approve() async {
        guard let privacy, let target = post.targetId else { return }
        approving = true
        defer { approving = false }
        let outcome = await session.approve(
            postTargetID: target,
            privacy: privacy,
            disableComment: disableComment,
            disableDuet: disableDuet,
            disableStitch: disableStitch,
            isAIGC: isAIGC,
            runAt: runAt
        )
        guard outcome != nil else { return }
        onApproved()
        dismiss()
    }
}

// MARK: - Pick a new time

struct RescheduleSheet: View {
    let post: BoardPost
    var onDone: () -> Void = {}

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(15 * 60)
    @State private var saving = false

    private var timezone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Post at", selection: $date, in: Date().addingTimeInterval(120)..., displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, timezone)
                    HStack {
                        quick("15 min", 15 * 60)
                        quick("1 hour", 3600)
                        quick("Tomorrow", 86_400)
                    }
                } footer: {
                    Text(post.approved
                         ? "It's already approved, so Autopilot will publish it at the new time."
                         : "It still needs your approval before it can go out.")
                }
            }
            .navigationTitle("New time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            if await session.reschedule(post: post.id, to: date) {
                                onDone()
                                dismiss()
                            }
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func quick(_ title: String, _ seconds: TimeInterval) -> some View {
        Button(title) { date = Date().addingTimeInterval(seconds) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }
}
