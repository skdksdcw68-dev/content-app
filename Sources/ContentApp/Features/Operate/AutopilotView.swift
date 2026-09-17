import SwiftUI

/// The machine, for the brand on screen: whether it is running, what it will
/// do next, what it has done, and what it needs from you. Everything here is
/// read from `autopilot_overview()`.
struct AutopilotView: View {
    @Environment(AppSession.self) private var session
    @State private var overview: AutopilotOverview?
    @State private var failed = false
    @State private var toggling = false
    @State private var confirmingPause = false
    @State private var uploading = false

    private var timezone: TimeZone {
        overview.flatMap { TimeZone(identifier: $0.brand.timezone) } ?? .current
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let overview {
                    status(overview)
                    nextMove(overview)
                    if let next = overview.nextPost { nextPost(next) }
                    counts(overview)
                    if let plan = overview.plan { campaign(plan, overview.counts) }
                    if let last = overview.lastPublished { lastPublished(last) }
                    controls(overview)
                    activity(overview.activity)
                } else if failed {
                    ContentUnavailableView("Couldn't load Autopilot", systemImage: "exclamationmark.triangle",
                                           description: Text("Pull to try again."))
                        .padding(.top, 60)
                } else {
                    SkeletonCard(height: 150)
                    SkeletonCard(height: 90)
                    SkeletonCard(height: 200)
                }
            }
            .screenGutter()
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Autopilot")
        .navigationBarTitleDisplayMode(.large)
        .pushedPage()
        .refreshable { await load() }
        .task(id: session.brand?.id) { await load() }
        .task { await tick() }
        .navigationDestination(isPresented: $uploading) { UploadFlowView() }
        .confirmationDialog("Pause Autopilot?", isPresented: $confirmingPause, titleVisibility: .visible) {
            Button("Pause", role: .destructive) { Task { await setPublishing(false) } }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Approved posts won't be published while paused. A post whose time passes while paused is held for a new time, never posted late.")
        }
    }

    // MARK: - Status

    private func status(_ o: AutopilotOverview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill((o.publishingOn ? Color.green : Color.orange).opacity(0.15))
                        .frame(width: 54, height: 54)
                    if o.publishingOn {
                        BreathingDot(size: 14)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.publishingOn ? "Active" : "Paused")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(o.brand.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if o.publishingOn { confirmingPause = true } else { Task { await setPublishing(true) } }
                } label: {
                    Text(o.publishingOn ? "Pause" : "Resume")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(o.publishingOn ? Color.track : Color.accentColor, in: Capsule())
                        .foregroundStyle(o.publishingOn ? Color.primary : Theme.onAccent)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(toggling)
            }

            Divider()

            HStack(spacing: 8) {
                if let connection = o.connection {
                    Image(systemName: connection.status == "active" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(connection.status == "active" ? Color.green : Color.red)
                    Text("TikTok · @\(connection.username)")
                    if connection.status != "active" {
                        Text("needs reconnecting").foregroundStyle(.red)
                    }
                } else {
                    Image(systemName: "link.badge.plus").foregroundStyle(.secondary)
                    Text("No account connected")
                }
                Spacer()
            }
            .font(.footnote)
        }
        .padding(18)
        .raisedCard(radius: Style.bigCard)
    }

    @ViewBuilder
    private func nextMove(_ o: AutopilotOverview) -> some View {
        switch o.next {
        case .autocasts(let text):
            MoveBanner(yours: false, text: text)
        case .yours(let text):
            switch o.nextAction {
            case "connect", "reconnect":
                MoveBanner(yours: true, text: text)
            case "paused":
                MoveBanner(yours: true, text: text, action: ("Resume", { Task { await setPublishing(true) } }))
            case "plan", "add_content":
                MoveBanner(yours: true, text: text, action: ("Upload", { uploading = true }))
            default:
                MoveBanner(yours: true, text: text)
            }
        }
    }

    private func nextPost(_ next: AutopilotOverview.PostRef) -> some View {
        NavigationLink {
            PostDetailView(postID: next.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Next post", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let date = next.date {
                        Text(date, style: .relative)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(next.hook)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let date = next.date {
                    Text("Goes out " + LoopTimeline.format(date, timezone))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
    }

    private func counts(_ o: AutopilotOverview) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            countTile("Published", o.counts.published, "checkmark.circle.fill", .green)
            countTile("Queued", o.counts.queued + o.counts.inFlight, "clock.badge.checkmark", .blue)
            countTile("Waiting for you", o.counts.waitingForYou, "eye", o.counts.waitingForYou > 0 ? .orange : .secondary)
            countTile("Needs attention", o.counts.needsAttention, "exclamationmark.triangle.fill", o.counts.needsAttention > 0 ? .red : .secondary)
        }
    }

    private func countTile(_ title: String, _ value: Int, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }

    private func campaign(_ plan: AutopilotOverview.Plan, _ counts: AutopilotOverview.Counts) -> some View {
        NavigationLink {
            PlanView()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Label("Current campaign", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(plan.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let objective = plan.objective, !objective.isEmpty {
                    Text(objective)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                ProgressView(value: Double(counts.publishedInPlan), total: Double(max(1, counts.inPlan)))
                    .tint(Color.accentColor)
                Text("\(counts.publishedInPlan) of \(counts.inPlan) posts published · \(plan.days) days · \(plan.postsPerDay) a day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
    }

    private func lastPublished(_ last: AutopilotOverview.PostRef) -> some View {
        NavigationLink {
            PostDetailView(postID: last.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last published")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(last.hook)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let date = last.date {
                        Text(LoopTimeline.format(date, timezone) + (last.privacy == "SELF_ONLY" ? " · only you" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
    }

    private func controls(_ o: AutopilotOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Control")
                .font(.headline)
                .padding(.bottom, 10)

            controlRow(
                "Approve every post",
                detail: "On. TikTok requires your OK on each post before it's published, so Autopilot never posts anything you haven't seen.",
                trailing: AnyView(Image(systemName: "lock.fill").foregroundStyle(.secondary))
            )
            Divider().padding(.vertical, 10)
            controlRow(
                "Make videos with AI",
                detail: session.hasWorkingGenerator
                    ? "Autopilot makes each planned video about a day before it's due, then sends it to you for review."
                    : "Connect a video generator with credits to turn this on. Your own videos work without it.",
                trailing: AnyView(Toggle("", isOn: Binding(
                    get: { o.aiVideosOn },
                    set: { value in Task { _ = await session.setAutopilot(value); await load() } }
                ))
                .labelsHidden()
                .disabled(!session.hasWorkingGenerator && !o.aiVideosOn))
            )
            if let settings = session.settings {
                Divider().padding(.vertical, 10)
                controlRow(
                    "Posting hours",
                    detail: settings.quietWindow + ". Autocast never schedules posts in quiet hours.",
                    trailing: AnyView(EmptyView())
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }

    private func controlRow(_ title: String, detail: String, trailing: AnyView) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }

    private func activity(_ events: [ActivityEvent]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent activity")
                .font(.headline)
            if events.isEmpty {
                Text("Nothing yet. Everything Autocast does for \(overview?.brand.name ?? "this brand") shows up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    ActivityRow(event: event, timezone: timezone)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }

    // MARK: - Loading

    private func load() async {
        do {
            overview = try await session.autopilotOverview()
            failed = false
        } catch {
            if overview == nil { failed = true }
        }
    }

    /// Something in flight changes within minutes; nothing else needs a timer.
    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            if let o = overview, o.counts.inFlight > 0 || (o.nextPost?.date ?? .distantFuture).timeIntervalSinceNow < 600 {
                await load()
            }
        }
    }

    private func setPublishing(_ on: Bool) async {
        toggling = true
        defer { toggling = false }
        if await session.setPublishing(on) { await load() }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    let timezone: TimeZone

    private var detail: String {
        if let date = event.detailDate { return "For " + LoopTimeline.format(date, timezone) }
        return event.detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(event.tint == .secondary ? Color.accentColor : event.tint)
                .frame(width: 26, height: 26)
                .background(Color.track, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).font(.subheadline.weight(.medium))
                    if event.isYou {
                        Text("You").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    if let date = event.date {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let hook = event.hook, !hook.isEmpty {
                    Text(hook).font(.caption).foregroundStyle(.primary).lineLimit(1)
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }
}
