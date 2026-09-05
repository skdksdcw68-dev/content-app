import SwiftUI

/// The rules the autopilot works under.
///
/// Pushed from Profile rather than owning a tab: these are the bounds it
/// decides inside, and they are read far less often than they are relied on.
/// The account itself, and everything to do with the person rather than the
/// autopilot, lives in Profile.
struct SettingsView: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                Toggle("Autopilot", isOn: $store.settings.isOn)
                if store.settings.isOn {
                    Stepper(
                        "\(store.settings.postsPerDay) a day",
                        value: $store.settings.postsPerDay,
                        in: 1...6
                    )
                }
            } header: {
                Text("Autopilot")
            } footer: {
                Text(store.settings.isOn
                     ? store.settings.summary
                     : "Nothing is planned, written or published while this is off.")
            }

            Section {
                Toggle("Ask before posting", isOn: $store.settings.requiresApproval)
            } footer: {
                // The one genuinely consequential switch in the app, so it
                // says plainly what turning it off means.
                Text(store.settings.requiresApproval
                     ? "Posts wait in the queue until you approve them."
                     : "Autocast publishes on its own, without showing you first.")
            }

            Section("Voice") {
                TextField(
                    "How it should sound",
                    text: $store.settings.tone,
                    axis: .vertical
                )
                .lineLimit(2...4)
            }

            Section {
                ForEach(store.pillars) { pillar in
                    Toggle(isOn: Binding(
                        get: { pillar.isEnabled },
                        set: { store.setPillar(pillar, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pillar.name)
                            Text(pillar.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("What it may post about")
            } footer: {
                Text("The autopilot only plans inside these, and spreads the schedule across whichever are on.")
            }

            Section {
                Picker("From", selection: $store.settings.quietHoursStart) {
                    ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                Picker("Until", selection: $store.settings.quietHoursEnd) {
                    ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("Nothing goes out inside this window, and Plan will not put a slot there.")
            }
        }
        .navigationTitle("Autopilot")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

#Preview {
    let store = ContentStore()
    return NavigationStack {
        SettingsView()
            .environment(store)
    }
    .task { await store.connect() }
}
