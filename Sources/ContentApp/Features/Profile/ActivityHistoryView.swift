import SwiftUI

/// Everything that happened for this brand, by day: what Autocast did, what
/// you did, what TikTok answered. The rows are written by the database when
/// the real rows change, so nothing here can say more than happened.
struct ActivityHistoryView: View {
    @Environment(AppSession.self) private var session
    @State private var events: [ActivityEvent]?

    private var zone: TimeZone {
        session.brand.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
    }

    private var days: [(day: Date, events: [ActivityEvent])] {
        var calendar = Calendar.current
        calendar.timeZone = zone
        let grouped = Dictionary(grouping: events ?? []) { event in
            calendar.startOfDay(for: event.date ?? .distantPast)
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            if let events, events.isEmpty {
                Text("Nothing has happened for this brand yet.")
                    .foregroundStyle(.secondary)
            } else if events == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(days, id: \.day) { day in
                Section(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(day.events) { event in
                        if let postID = event.postId {
                            NavigationLink { PostDetailView(postID: postID) } label: {
                                ActivityRow(event: event, timezone: zone)
                            }
                        } else {
                            ActivityRow(event: event, timezone: zone)
                        }
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.brand?.id) { events = await session.activityHistory() }
        .refreshable { events = await session.activityHistory() }
    }
}
