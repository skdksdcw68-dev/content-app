import SwiftUI

/// Connecting the generator you already pay for.
///
/// Bring-your-own-key rather than a pooled one, and the reason is arithmetic: a
/// shared key at a thousand people times thirty videos a month is thousands of
/// dollars of generation. It also makes the app provider-agnostic for free --
/// nothing in the schema knows what Higgsfield is.
///
/// The key is checked against Higgsfield before it is stored, and it never
/// comes back out. What the app can read afterwards is that a generator exists
/// and whether it last worked.
struct GeneratorSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var keyID = ""
    @State private var keySecret = ""

    private var canSave: Bool {
        !keyID.trimmingCharacters(in: .whitespaces).isEmpty
            && !keySecret.trimmingCharacters(in: .whitespaces).isEmpty
            && !session.isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EmptyArt(name: "generator-hero", size: 110)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Key ID", text: $keyID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    SecureField("Key secret", text: $keySecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Higgsfield")
                } footer: {
                    // cloud.higgsfield.ai, NOT higgsfield.ai. They are separate
                    // surfaces: the one people know is the consumer app, and
                    // API keys only exist in Higgsfield Cloud. Sending someone
                    // to the wrong one means hunting for a page that is not
                    // there and concluding this feature is broken.
                    Text("Made at cloud.higgsfield.ai — the Cloud dashboard, not the main higgsfield.ai app. Both halves are needed.")
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            if session.isWorking {
                                ProgressView().controlSize(.small)
                                Text("Checking the key…")
                            } else {
                                Image(systemName: "checkmark.shield")
                                Text("Check and save")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSave)
                } footer: {
                    // Said plainly, because "we store your key" is the sentence
                    // people actually want answered before they paste one.
                    Text("The key is tried against Higgsfield before it is kept, and refused if it does not work. It is encrypted with a key the database does not hold, and it is never sent back to this app.")
                }

                Section {
                    Label("You are billed by Higgsfield for what it makes, not by us.", systemImage: "creditcard")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add a generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(session.isWorking)
                }
            }
            .interactiveDismissDisabled(session.isWorking)
        }
    }

    private func save() async {
        let ok = await session.connectGenerator(
            keyID: keyID.trimmingCharacters(in: .whitespaces),
            keySecret: keySecret.trimmingCharacters(in: .whitespaces)
        )
        if ok { dismiss() }
    }
}
