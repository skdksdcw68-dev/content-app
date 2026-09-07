import SwiftUI

/// What the agent knows about you.
///
/// This screen exists because of a specific failure. The planner was told to
/// prefer specifics, had none, and invented them -- plans came back announcing
/// features the product did not have. The fix was to forbid invention, and the
/// consequence of that fix is that whatever is written here is the entire
/// difference between a plan worth posting and a generic one.
///
/// Facts are removable line by line, and shown in full. An agent that
/// accumulates opinions about you in private is not one anybody should hand an
/// unattended publish key.
struct BrandView: View {
    @Environment(AppSession.self) private var session

    @State private var name = ""
    @State private var niche = ""
    @State private var audience = ""
    @State private var newFact = ""
    @State private var loaded = false

    private var dirty: Bool {
        guard let brand = session.brand else { return false }
        return name != brand.name || niche != brand.niche || audience != brand.audience
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } header: {
                Text("Account")
            }

            Section {
                TextField("What you post about", text: $niche, axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text("One or two sentences. \"A journalling app that asks you one question a day\" beats \"productivity\".")
            }

            Section {
                TextField("Who it is for", text: $audience, axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text("\"People who have tried journalling and quit\" gives it something to write to. \"Everyone\" does not.")
            }

            if dirty {
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .disabled(session.isWorking)
                }
            }

            Section {
                ForEach(session.facts) { fact in
                    Text(fact.fact)
                        .font(.subheadline)
                        .swipeActions(edge: .trailing) {
                            Button("Forget", role: .destructive) {
                                Task { await session.forget(fact.id) }
                            }
                        }
                }

                HStack {
                    TextField("Something true about you", text: $newFact, axis: .vertical)
                        .lineLimit(1...3)

                    Button {
                        Task { await remember() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty || session.isWorking)
                }
            } header: {
                Text("What it should know")
            } footer: {
                // The honest reason this section matters, said plainly.
                Text("It writes only from what is here. It will not claim you shipped something, changed a price or hit a number unless you have told it. Add what is true and it gets specific; leave it empty and it stays general.")
            }
        }
        .navigationTitle("Your brand")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            name = session.brand?.name ?? ""
            niche = session.brand?.niche ?? ""
            audience = session.brand?.audience ?? ""
            await session.refreshFacts()
        }
    }

    private func save() async {
        await session.updateBrand(name: name, niche: niche, audience: audience)
    }

    private func remember() async {
        let fact = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return }
        if await session.remember(fact) { newFact = "" }
    }
}
