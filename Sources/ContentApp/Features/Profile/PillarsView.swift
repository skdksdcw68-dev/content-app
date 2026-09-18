import SwiftUI

/// The themes a month is built from. The planner already shares slots out by
/// these weights (`allocate_slots`); until now nothing let you see or change
/// them.
struct PillarsView: View {
    @Environment(AppSession.self) private var session
    @State private var pillars: [ContentPillar]?
    @State private var editing: ContentPillar?

    var body: some View {
        Form {
            if let pillars {
                if pillars.isEmpty {
                    Section {
                        Text("No pillars yet. Add the three or four things your videos keep coming back to. The planner spreads the month across them.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(pillars) { pillar in
                            Button { editing = pillar } label: {
                                PillarRow(pillar: pillar, share: share(of: pillar, in: pillars))
                            }
                            .tint(.primary)
                        }
                        .onDelete { offsets in
                            let gone = offsets.map { pillars[$0] }
                            self.pillars?.remove(atOffsets: offsets)
                            Task { for pillar in gone { await session.deletePillar(pillar.id) } }
                        }
                    } footer: {
                        Text("Share is how much of a plan each one gets. Switched-off pillars are skipped.")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Content pillars")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = ContentPillar() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a pillar")
            }
        }
        .task(id: session.brand?.id) { pillars = await session.pillars() }
        .sheet(item: $editing) { pillar in
            PillarEditor(pillar: pillar) { saved in
                Task {
                    if await session.savePillar(saved) { pillars = await session.pillars() }
                }
            }
        }
    }

    private func share(of pillar: ContentPillar, in all: [ContentPillar]) -> Double? {
        guard pillar.isEnabled else { return nil }
        let total = all.filter(\.isEnabled).reduce(0) { $0 + $1.weight }
        return total > 0 ? Double(pillar.weight) / Double(total) : nil
    }
}

private struct PillarRow: View {
    let pillar: ContentPillar
    let share: Double?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pillar.name)
                    .foregroundStyle(pillar.isEnabled ? Color.primary : Color.secondary)
                if !pillar.detail.isEmpty {
                    Text(pillar.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let share {
                Text(share, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Off").foregroundStyle(.secondary)
            }
        }
    }
}

private struct PillarEditor: View {
    @State var pillar: ContentPillar
    let save: (ContentPillar) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Behind the scenes", text: $pillar.name)
                    TextField("What these videos are about", text: $pillar.detail, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Stepper(value: $pillar.weight, in: 1...10) {
                        LabeledContent("Weight", value: "\(pillar.weight)")
                    }
                    Toggle("Use in plans", isOn: $pillar.isEnabled)
                } footer: {
                    Text("A pillar with weight 2 gets twice the posts of one with weight 1.")
                }
            }
            .navigationTitle(pillar.name.isEmpty ? "New pillar" : pillar.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(pillar)
                        dismiss()
                    }
                    .disabled(pillar.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .toggleStyle(RemiSwitchStyle())
    }
}
