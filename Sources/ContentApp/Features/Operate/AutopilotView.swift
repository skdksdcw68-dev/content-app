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
                // Netro, 19 Oct 2026: "This page is looking bad... the recent
                // activity shouldn't be there. It should be somewhere like logs."
                // A 3D hero that moves once and stops, the counts flipping in,
                // and the activity behind its own row.
                if let overview {
                    status(overview)
                    nextMove(overview)
                    if let next = overview.nextPost { nextPost(next) }
                    counts(overview)
                    if let plan = overview.plan { campaign(plan, overview.counts) }
                    if let last = overview.lastPublished { lastPublished(last) }
                    controls(overview)
                    activityLink(overview)
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
        VStack(alignment: .center, spacing: 14) {
            AutopilotHero(active: o.publishingOn)
                .frame(height: 190)
                .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(o.publishingOn ? "Active" : "Paused")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(o.publishingOn ? "Posting for \(o.brand.name)" : "\(o.brand.name) is on hold")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack {
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
                Spacer()
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
                .flipIn(order: 0)
            countTile("Queued", o.counts.queued + o.counts.inFlight, "clock.badge.checkmark", .blue)
                .flipIn(order: 1)
            countTile("Waiting for you", o.counts.waitingForYou, "eye", o.counts.waitingForYou > 0 ? .orange : .secondary)
                .flipIn(order: 2)
            countTile("Needs attention", o.counts.needsAttention, "exclamationmark.triangle.fill", o.counts.needsAttention > 0 ? .red : .secondary)
                .flipIn(order: 3)
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
                    : "Making videos is paused on our side for a moment. Your own videos work without it.",
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

    /// The log, one tap away instead of filling the page.
    private func activityLink(_ o: AutopilotOverview) -> some View {
        NavigationLink {
            AutopilotLogView(events: o.activity, brandName: o.brand.name, timezone: timezone)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity log")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(o.activity.first.map { "Latest: \($0.title)" } ?? "Everything Autopilot does shows up here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
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

/// Everything Autopilot has done, newest first, as its own page.
struct AutopilotLogView: View {
    let events: [ActivityEvent]
    let brandName: String
    let timezone: TimeZone

    var body: some View {
        List {
            if events.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "list.bullet.rectangle.portrait",
                                       description: Text("Everything Autocast does for \(brandName) shows up here."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(events) { event in
                    ActivityRow(event: event, timezone: timezone)
                        .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Activity log")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
    }
}

// MARK: - The 3D pieces

/// Autopilot's engine: a glowing orb inside three tilted rings. It swings in
/// from an angle, the rings spin into place and the plane turns once -- about
/// two seconds -- and then everything stops. Nothing loops. Paused, it is
/// grey and the rings settle without spinning.
private struct AutopilotHero: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    private var tint: Color { active ? .accentColor : .gray }

    var body: some View {
        ZStack {
            // A soft floor shadow, so the whole thing sits in space.
            Ellipse()
                .fill(tint.opacity(0.18))
                .frame(width: 150, height: 26)
                .blur(radius: 10)
                .offset(y: 78)

            ForEach(0..<3, id: \.self) { ring in
                let size = CGFloat(176 - ring * 34)
                Ellipse()
                    .strokeBorder(
                        AngularGradient(colors: [tint, tint.opacity(0.1), tint.opacity(0.6), tint], center: .center),
                        lineWidth: ring == 0 ? 2.5 : 2
                    )
                    .frame(width: size, height: size)
                    // Spin in the ring's own plane first, then tilt the plane:
                    // that is what makes it read as a ring in space.
                    .rotationEffect(.degrees(settled || reduceMotion ? Double(ring) * 40 : Double(ring) * 40 - (active ? 300 : 40)))
                    .rotation3DEffect(.degrees(68 - Double(ring) * 10), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                    .rotation3DEffect(.degrees(Double(ring - 1) * 18), axis: (x: 0, y: 0, z: 1))
            }

            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.55), tint.opacity(0.25)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 4,
                    endRadius: 52
                ))
                .frame(width: 84, height: 84)
                .overlay {
                    // A highlight, so the orb reads as a sphere.
                    Circle()
                        .fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .topLeading, endPoint: .center))
                        .frame(width: 84, height: 84)
                        .mask(Circle().frame(width: 60, height: 60).offset(x: -10, y: -12))
                }
                .shadow(color: tint.opacity(0.45), radius: 18, y: 8)
                .overlay {
                    Image(systemName: active ? "paperplane.fill" : "pause.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .rotation3DEffect(.degrees(settled || reduceMotion ? 0 : (active ? -360 : 0)), axis: (x: 0, y: 1, z: 0))
                }
                .scaleEffect(settled || reduceMotion ? 1 : 0.6)
        }
        // The whole engine swings in from an angle and settles face on.
        .rotation3DEffect(.degrees(settled || reduceMotion ? 0 : 38), axis: (x: 1, y: -0.6, z: 0), perspective: 0.6)
        .opacity(settled || reduceMotion ? 1 : 0)
        .onAppear {
            guard !settled, !reduceMotion else { return }
            withAnimation(.spring(duration: 1.9, bounce: 0.22)) { settled = true }
        }
        .accessibilityHidden(true)
    }
}

private struct FlipIn: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(shown || reduceMotion ? 0 : -75), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.5)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                guard !shown, !reduceMotion else { return }
                withAnimation(.spring(duration: 0.7, bounce: 0.3).delay(0.35 + Double(order) * 0.09)) { shown = true }
            }
    }
}

private extension View {
    /// Flips down into place once, after the ones before it.
    func flipIn(order: Int) -> some View { modifier(FlipIn(order: order)) }
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
