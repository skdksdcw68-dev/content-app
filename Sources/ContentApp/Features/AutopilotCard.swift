import SwiftUI

/// Where Autopilot actually stands, as one of a closed set of states.
///
/// It used to be a switch and some greeting copy, which meant "on" covered
/// everything from "running a month unattended" to "on, and refusing every
/// request because the credits ran out" -- the exact ambiguity that let three
/// days of nothing go unnoticed in September. Each state here is a different
/// fact with a different next step, and the card says which one is true.
///
/// Ordered by what matters most. A blocked Autopilot is reported before one
/// that is merely waiting, because waiting resolves itself and blocked does not.
enum AutopilotState: Equatable {
    /// Switched off. Nothing is made or posted unless somebody does it.
    case off(hasPlan: Bool)
    /// On, and stopped by something only the person can fix.
    case blocked(HealthFinding)
    /// On, with nothing connected that can make video.
    case needsGenerator
    /// On, with no plan to run.
    case needsPlan
    /// Posts are ready and held for approval. Nothing goes out without it.
    case waiting(Int)
    /// Videos are being made right now.
    case preparing(Int)
    /// Running, with the next post due at this time.
    case running(next: Date)
    /// The plan has nothing left ahead.
    case finished

    static func resolve(
        isOn: Bool,
        hasAccount: Bool,
        hasGenerator: Bool,
        hasPlan: Bool,
        blocked: HealthFinding?,
        needsApproval: Int,
        preparing: Int,
        nextUp: Date?
    ) -> AutopilotState? {
        // Without an account there is nothing to run and "Start here" already
        // says what to do. Two cards saying it would be one too many.
        guard hasAccount else { return nil }
        guard isOn else { return .off(hasPlan: hasPlan) }
        if let blocked { return .blocked(blocked) }
        if !hasGenerator { return .needsGenerator }
        if !hasPlan { return .needsPlan }
        if needsApproval > 0 { return .waiting(needsApproval) }
        if preparing > 0 { return .preparing(preparing) }
        if let nextUp { return .running(next: nextUp) }
        return .finished
    }

    var title: String {
        switch self {
        case .off:                 "Autopilot is off"
        case .blocked(let found):  found.title
        case .needsGenerator:      "Autopilot needs a video generator"
        case .needsPlan:           "Autopilot has nothing to run"
        case .waiting(let n):      n == 1 ? "Waiting on you for 1 post" : "Waiting on you for \(n) posts"
        case .preparing(let n):    n == 1 ? "Preparing 1 post" : "Preparing \(n) posts"
        case .running:             "Autopilot is running"
        case .finished:            "The plan has run out"
        }
    }

    func detail(in timezone: TimeZone) -> String {
        switch self {
        case .off(let hasPlan):
            return hasPlan
                ? "Turn it on and Autocast makes each day's video ahead of time. Nothing is posted until you approve it."
                : "Plan a month first, then turn it on and Autocast makes each day's video for you."
        case .blocked(let found):
            return found.detail
        case .needsGenerator:
            return "Sign in to the generator you already pay for and Autocast can make the videos."
        case .needsPlan:
            return "Plan a month and Autopilot takes it from there."
        case .waiting:
            return "They're ready. Approve them below and they go out on time."
        case .preparing:
            return "Videos are being made now. Nothing to do."
        case .running(let next):
            return "Next post \(Self.when(next, in: timezone)). Nothing to do."
        case .finished:
            return "Everything scheduled has gone out. Plan the next stretch to keep going."
        }
    }

    var symbol: String {
        switch self {
        case .off:            "pause.circle"
        case .blocked:        "exclamationmark.triangle.fill"
        case .needsGenerator: "wand.and.stars"
        case .needsPlan:      "calendar.badge.plus"
        case .waiting:        "hand.raised.fill"
        case .preparing:      "gearshape.2"
        case .running:        "checkmark.circle.fill"
        case .finished:       "flag.checkered"
        }
    }

    var tint: Color {
        switch self {
        case .blocked:                       .red
        case .needsGenerator, .needsPlan:    .orange
        case .waiting:                       .orange
        case .preparing, .running:           .green
        case .off, .finished:                .secondary
        }
    }

    /// "today at 18:00", "tomorrow at 09:30", "on Friday at 12:00".
    private static func when(_ date: Date, in timezone: TimeZone) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timezone
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timezone))
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let day = date.formatted(Date.FormatStyle(timeZone: timezone).weekday(.wide))
        return "on \(day) at \(time)"
    }
}

/// The card. One state, one sentence, and at most one thing to press.
///
/// The button is only there when pressing it changes the state. "Running" and
/// "preparing" offer nothing, on purpose: an arrow is an instruction, and the
/// whole point of those states is that there is nothing to do.
struct AutopilotCard: View {
    let state: AutopilotState
    let timezone: TimeZone

    @Environment(AppSession.self) private var session
    @State private var turningOn = false

    var body: some View {
        Card("Autopilot", systemImage: "airplane") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.tint)
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(state.detail(in: timezone))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            action
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .off(let hasPlan):
            if hasPlan {
                Button {
                    turningOn = true
                    Task {
                        await session.setAutopilot(true)
                        turningOn = false
                    }
                } label: {
                    Text(turningOn ? "Turning on…" : "Turn on Autopilot")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(turningOn)
            } else {
                link("Plan a month") { PlanView() }
            }

        case .blocked(let found):
            switch found.route.flatMap(HealthRoute.init(rawValue:)) {
            case .generator, .connections:
                link(found.action ?? "Fix it") { ProfileView() }
            case .plan:
                link(found.action ?? "Open the plan") { PlanView() }
            case nil:
                EmptyView()
            }

        case .needsGenerator:
            link("Connect a generator") { ProfileView() }

        case .needsPlan, .finished:
            link("Plan a month") { PlanView() }

        case .running:
            link("See the plan") { PlanView() }

        case .waiting, .preparing:
            EmptyView()
        }
    }

    private func link<Destination: View>(
        _ title: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }
}
