import SwiftUI

/// The small card a scheduled request leaves in the chat (Abel, 3 Nov 2026:
/// "keep this thing small"). One line for when, one for what. Tap to change or
/// cancel. A draft opens its sheet by itself the moment it arrives.
struct ScheduleCard: View {
    @Environment(AppSession.self) private var session
    let scheduleId: UUID
    /// Just made in this reply, so the sheet opens without a tap.
    var opensAtOnce = false

    @State private var schedule: DropSchedule?
    @State private var editing: DropSchedule?
    /// The other drops made by the same request ("3 pictures a day").
    @State private var siblings: [DropSchedule] = []
    @State private var listing = false

    var body: some View {
        Button {
            if siblings.count > 1 { listing = true } else { editing = schedule }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 60)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(schedule == nil)
        .task {
            schedule = await session.dropSchedule(scheduleId)
            if let schedule { siblings = await session.dropSiblings(of: schedule) }
            if opensAtOnce, schedule?.status == "draft" { editing = schedule }
        }
        .sheet(isPresented: $listing) {
            SiblingDropsSheet(drops: siblings) {
                if let schedule {
                    Task { siblings = await session.dropSiblings(of: schedule) }
                }
            }
        }
        .sheet(item: $editing) { draft in
            ScheduleSheet(schedule: draft) { saved in
                withAnimation(.snappy(duration: 0.25)) { schedule = saved }
            }
        }
    }

    private var icon: String {
        switch schedule?.status {
        case "cancelled": return "xmark"
        case "done": return "checkmark"
        case "paused": return "pause.fill"
        default: return "clock"
        }
    }

    private var tint: Color {
        schedule?.status == "active" ? .green : .secondary
    }

    private var title: String {
        guard let schedule else { return "Scheduled drop" }
        if siblings.count > 1, schedule.status != "cancelled" {
            return "\(siblings.count) drops scheduled"
        }
        switch schedule.status {
        case "draft": return "Tap to schedule"
        case "cancelled": return "Cancelled"
        case "done": return "Delivered"
        default: return schedule.whenText
        }
    }

    private var detail: String {
        guard let schedule else { return " " }
        if siblings.count > 1, schedule.status != "cancelled" {
            let times = siblings.map {
                $0.startsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: $0.zone))
            }
            return "\(schedule.summary) · \(times.joined(separator: ", "))"
        }
        if schedule.status == "active", let next = schedule.nextAt {
            let when = next.formatted(Date.FormatStyle(timeZone: schedule.zone).weekday(.abbreviated).hour().minute())
            // Close by, it says how close (mockup screen 6: "arrives 9:51 AM, in 12 min").
            let left = next.timeIntervalSinceNow
            if left > 0, left < 3 * 3600 {
                return "\(schedule.summary) · \(when), \(next.formatted(.relative(presentation: .named)))"
            }
            return "\(schedule.summary) · next \(when)"
        }
        if schedule.status == "draft" { return "\(schedule.summary) · \(schedule.whenText)" }
        return schedule.summary
    }
}

/// Settings › Notifications › Scheduled drops: everything still coming, and
/// "Pause all".
struct ScheduledDropsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.colorScheme) private var scheme

    @State private var drops: [DropSchedule] = []
    @State private var loaded = false
    @State private var editing: DropSchedule?

    private var paused: Bool { !drops.isEmpty && drops.allSatisfy { $0.status == "paused" } }

    var body: some View {
        List {
            Section {
                if drops.isEmpty {
                    Text(loaded ? "Nothing scheduled. Ask in a chat: \"send me 3 hooks every morning at 8\"." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(drops) { drop in
                    Button { editing = drop } label: { row(drop) }
                }
            } header: {
                Text("Coming up")
            }
            if !drops.isEmpty {
                Section {
                    Toggle(isOn: Binding(get: { paused }, set: { pause($0) })) {
                        Label("Pause all", systemImage: "pause")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GrokLook.sheet(scheme).ignoresSafeArea())
        .navigationTitle("Scheduled")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editing) { drop in
            ScheduleSheet(schedule: drop) { _ in Task { await reload() } }
        }
    }

    private func row(_ drop: DropSchedule) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(drop.summary).foregroundStyle(Color.primary).lineLimit(1)
                Text(drop.status == "paused" ? "Paused · \(drop.whenText)" : drop.whenText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func reload() async {
        drops = await session.dropSchedules()
        loaded = true
    }

    private func pause(_ on: Bool) {
        Task {
            await session.pauseSchedules(on)
            await reload()
        }
    }
}

/// Every drop a single request made, each one tappable to change or cancel
/// (Abel, 8 Nov 2026: "I scheduled three pictures a day and it showed only one").
private struct SiblingDropsSheet: View {
    let drops: [DropSchedule]
    let changed: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DropSchedule?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(drops) { drop in
                        Button { editing = drop } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(drop.whenText).foregroundStyle(Color.primary)
                                    Text(drop.status == "draft" ? "Not confirmed yet" : drop.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("\(drops.count) times")
                }
            }
            .scrollContentBackground(.hidden)
            .background(GrokLook.sheet(scheme).ignoresSafeArea())
            .navigationTitle("Scheduled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { drop in
                ScheduleSheet(schedule: drop) { _ in changed() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
