import SwiftUI

/// The workspace: you say what you want, it goes into the queue.
///
/// A tab rather than a floating button, because this is a place you come to
/// and think in, not a control you poke. The brief is the whole screen -- the
/// format and the goal are two taps under it, and everything else the planner
/// already knows from Profile.
struct CreateView: View {
    /// Called after something is actually queued, so the app can show the
    /// person where it went instead of leaving them on an empty form.
    var onCreated: () -> Void

    @Environment(ContentStore.self) private var store
    @FocusState private var briefIsFocused: Bool

    @State private var brief = ""
    @State private var kind: CreateKind = .video
    @State private var goal: CreateGoal = .reach

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Describe it, or paste a link",
                        text: $brief,
                        axis: .vertical
                    )
                    .lineLimit(4...10)
                    .focused($briefIsFocused)
                } header: {
                    Text("What do you want to make")
                } footer: {
                    Text("Your words go to the writer exactly as you type them. A half-formed thought works better here than a keyword.")
                }

                Section {
                    Picker("Format", selection: $kind) {
                        ForEach(CreateKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Format")
                } footer: {
                    Text(kind.detail)
                }

                Section {
                    Picker("Goal", selection: $goal) {
                        ForEach(CreateGoal.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Goal")
                } footer: {
                    // The goal changes the writing more than the subject does,
                    // so the consequence of the choice is spelled out rather
                    // than left to the label.
                    Text(goal.detail)
                }

                Section {
                    Button(action: create) {
                        Text(actionTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Section {
                    Label {
                        Text("Photos and video attach here once rendering is built. Until then a link or a description in the brief is what it works from.")
                    } icon: {
                        Image(systemName: "paperclip")
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                }
            }
            .navigationTitle("Create")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Spacer()
                }
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { briefIsFocused = false }
                }
            }
        }
    }

    private var actionTitle: String {
        kind == .campaign ? "Plan \(kind.postCount) posts" : "Add to the queue"
    }

    private func create() {
        briefIsFocused = false
        guard store.requestDraft(kind, brief: brief, goal: goal) else { return }

        // Clear the desk. Leaving the brief sitting there reads as though
        // nothing happened, and re-tapping would quietly queue it twice.
        brief = ""
        onCreated()
    }
}

#Preview {
    let store = ContentStore()
    return CreateView(onCreated: {})
        .environment(store)
        .task { await store.connect() }
}
