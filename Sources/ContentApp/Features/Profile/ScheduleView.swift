import SwiftUI

/// When this brand posts: the quiet window, how many a day, and the time zone
/// every hour is read in. The next plan is made from these.
struct ScheduleView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var quietStart = 22
    @State private var quietEnd = 7
    @State private var perDay = 1
    @State private var timezone = TimeZone.current.identifier
    @State private var loaded = false
    @State private var saving = false

    private var changed: Bool {
        guard let settings = session.settings else { return false }
        return quietStart != settings.quietHoursStart || quietEnd != settings.quietHoursEnd
            || perDay != settings.postsPerDay || timezone != session.brand?.timezone
    }

    var body: some View {
        Form {
            // The system's own controls, not values written out as text
            // (Abel, 23 Sep 2026: "listed as text and looks so bad"). A
            // segmented picker for the count, time wheels for the hours.
            Section {
                Picker("Posts a day", selection: $perDay) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Posts a day")
            } footer: {
                Text("TikTok limits how often an account can post, so three is the most Autocast will plan.")
            }

            Section {
                DatePicker("Quiet from", selection: hourBinding($quietStart), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: hourBinding($quietEnd), displayedComponents: .hourAndMinute)
            } header: {
                Text("Quiet hours")
            } footer: {
                Text(quietStart == quietEnd
                     ? "No quiet hours: posts can go out at any time."
                     : "Nothing is posted between \(Self.hour(quietStart)) and \(Self.hour(quietEnd)).")
            }

            Section {
                Picker("Time zone", selection: $timezone) {
                    ForEach(Self.zones(including: timezone), id: \.self) { zone in
                        Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                    }
                }
                .pickerStyle(.navigationLink)
                if timezone != TimeZone.current.identifier {
                    Button("Use this iPhone’s time zone") { timezone = TimeZone.current.identifier }
                }
            } footer: {
                Text("Every time you see in Autocast is in this zone.")
            }
        }
        .navigationTitle("Posting hours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        saving = true
                        let done = await session.updateSchedule(
                            quietStart: quietStart, quietEnd: quietEnd, postsPerDay: perDay, timezone: timezone)
                        saving = false
                        if done { dismiss() }
                    }
                } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .disabled(!changed || saving)
            }
        }
        .task {
            if session.settings == nil { await session.refreshSettings() }
            guard !loaded, let settings = session.settings else { return }
            quietStart = settings.quietHoursStart
            quietEnd = settings.quietHoursEnd
            perDay = min(max(settings.postsPerDay, 1), 3)
            timezone = session.brand?.timezone ?? TimeZone.current.identifier
            loaded = true
        }
    }

    /// An hour of the day as a date the time wheel can show, and back. The
    /// minutes are dropped on the way back: the scheduler thinks in hours.
    private func hourBinding(_ hour: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                var parts = DateComponents()
                parts.hour = hour.wrappedValue
                parts.minute = 0
                return Calendar.current.date(from: parts) ?? .now
            },
            set: { date in
                hour.wrappedValue = Calendar.current.component(.hour, from: date)
            }
        )
    }

    static func hour(_ value: Int) -> String {
        var parts = DateComponents()
        parts.hour = value
        let date = Calendar.current.date(from: parts) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func zones(including current: String) -> [String] {
        var all = TimeZone.knownTimeZoneIdentifiers
        if !all.contains(current) { all.append(current) }
        return all.sorted()
    }
}
