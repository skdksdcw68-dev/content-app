import SwiftUI

/// Chat settings: how it should talk to you, what it knows, and clearing
/// the history. Abel, 23 Sep 2026: "the chat is really perfect, but make
/// sure we can have some chat settings."
///
/// The instructions are the owner's words, read into every reply after the
/// rules -- they set tone and length, and cannot switch the honesty rules
/// off. What it knows is the Brand page, linked rather than copied.
struct ChatSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var instructions = ""
    @State private var saving = false
    @State private var confirmingClear = false
    @State private var cleared = false

    private var saved: String { session.settings?.chatInstructions ?? "" }
    private var dirty: Bool { instructions.trimmingCharacters(in: .whitespacesAndNewlines) != saved }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Keep replies short. Call me Abel. Skip the hashtags unless I ask.", text: $instructions, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("How it talks to you")
                } footer: {
                    Text("Your words, read before every reply. Tone, length, what to call you, what to leave out.")
                }

                Section {
                    NavigationLink { BrandView() } label: {
                        SettingsLabel("What it knows", symbol: "lightbulb")
                    }
                } footer: {
                    Text("The account, the facts you wrote down and your answers on the Brand page are what it reasons from.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(cleared ? "Chats cleared" : "Clear all chats")
                            Spacer()
                        }
                    }
                    .disabled(cleared)
                } footer: {
                    Text("Deletes every conversation. What it knows about your brand stays.")
                }
            }
            .navigationTitle("Chat settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(!dirty || saving)
                }
            }
            .onAppear { instructions = saved }
            .alert("Clear all chats?", isPresented: $confirmingClear) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    Task { cleared = await session.clearThreads() }
                }
            } message: {
                Text("Every conversation is deleted. This can’t be undone.")
            }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await session.setChatInstructions(instructions.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dismiss()
        }
    }
}
