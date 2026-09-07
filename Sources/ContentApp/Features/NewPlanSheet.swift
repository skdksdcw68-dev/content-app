import SwiftUI

/// Three decisions before a month gets written: what it is about, how long, and
/// how often.
///
/// Deliberately three and not ten. Quiet hours, themes and the timezone already
/// exist as settings, and asking again here would be asking a person to
/// re-specify their account every time they want a plan.
struct NewPlanSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Prefilled from whatever was typed in Chat, so pressing "Plan a month"
    /// after writing a sentence does not throw the sentence away.
    @State private var brief: String

    @State private var days = 30
    @State private var postsPerDay = 1

    /// Called with the proposal once it exists, so the caller can push the
    /// preview. The sheet does not navigate; it reports.
    let onProposed: (PlanProposal) -> Void

    /// Written out rather than left to the memberwise initialiser, which is
    /// private the moment a stored property is -- and every @State here is.
    init(brief: String, onProposed: @escaping (PlanProposal) -> Void) {
        _brief = State(initialValue: brief)
        self.onProposed = onProposed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "What this month is about",
                        text: $brief,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .disabled(session.isPlanning)
                } header: {
                    Text("The brief")
                } footer: {
                    Text("Optional. Your account description and themes are used either way — this is for anything specific to these weeks, like a launch.")
                }

                Section {
                    Picker("How long", selection: $days) {
                        Text("A week").tag(7)
                        Text("Two weeks").tag(14)
                        Text("A month").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isPlanning)

                    Stepper(
                        "\(postsPerDay) post\(postsPerDay == 1 ? "" : "s") a day",
                        value: $postsPerDay,
                        in: 1...3
                    )
                    .disabled(session.isPlanning)
                } footer: {
                    Text("\(days * postsPerDay) posts, spread across the hours you have not marked quiet. Today's slot is skipped if it has already passed.")
                }

                if let existing = session.plan, existing.isProposal {
                    Section {
                        Label(
                            "You already have a plan waiting. Making a new one replaces it.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await propose() }
                    } label: {
                        HStack {
                            if session.isPlanning {
                                ProgressView().controlSize(.small)
                                Text("Writing \(days * postsPerDay) posts…")
                            } else {
                                Image(systemName: "calendar.badge.plus")
                                Text("Write the plan")
                            }
                            Spacer()
                        }
                    }
                    .disabled(session.isPlanning)
                } footer: {
                    if session.isPlanning {
                        // Twenty-odd seconds with no explanation reads as a
                        // hang. Saying why it is slow is cheaper than making it
                        // fast, and more honest than a fake progress bar.
                        Text("It writes ten at a time so the later ones are not worse than the early ones. This takes a few seconds.")
                    } else {
                        Text("Nothing is scheduled and nothing is posted. You see all of it first.")
                    }
                }
            }
            .navigationTitle("Plan a month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(session.isPlanning)
                }
            }
            .interactiveDismissDisabled(session.isPlanning)
        }
    }

    private func propose() async {
        guard let proposal = await session.proposePlan(
            brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
            days: days,
            postsPerDay: postsPerDay
        ) else { return }

        // Reported before dismissing, so the caller can act on it once the
        // sheet has finished going away. Pushing a screen in the same tick as a
        // dismiss loses the push often enough to look like a dead button.
        onProposed(proposal)
        dismiss()
    }
}
