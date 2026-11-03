import SwiftUI

/// Customize Autocast: Grok's "Customize Grok" (Abel, 3 Nov 2026). Preset cards
/// for how long a reply is, the owner's own instructions in a box, and the small
/// habits as switches -- including whether the chat searches the web on its own.
/// The words end up in the instructions the model reads after the rules; they set
/// tone and length and cannot switch the honesty rules off. Pushed inside the
/// Settings sheet, or shown in a sheet of its own from the chat list.
struct ChatSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var preferences = ChatPreferences()
    @State private var own = ""
    @State private var searchesWeb = true
    @State private var savedSearchesWeb = true
    @State private var saving = false
    @State private var confirmingClear = false
    @State private var cleared = false

    private var saved: String {
        (session.settings?.chatInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var composed: String { ChatPreferences.compose(preferences, own: own) }
    private var dirty: Bool { composed != saved || searchesWeb != savedSearchesWeb }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                presets
                instructions
                switches
                clearChats
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(GrokLook.sheet(scheme).ignoresSafeArea())
        .navigationTitle("Customize Postpilot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                }
                .disabled(!dirty || saving)
            }
        }
        .onAppear { load() }
        .alert("Clear all chats?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { cleared = await session.clearThreads() }
            }
        } message: {
            Text("Every conversation is deleted. This can’t be undone.")
        }
    }

    // MARK: - Pieces

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            GrokCaption("Presets")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ReplyLength.allCases) { option in
                    PresetCard(option: option, picked: preferences.length == option) {
                        withAnimation(.snappy(duration: 0.25)) { preferences.length = option }
                    }
                }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            GrokCaption("Instructions")
            TextField("How should Postpilot talk to you? What should it call you?", text: $own, axis: .vertical)
                .lineLimit(4...10)
                .padding(16)
                .background(GrokLook.card(scheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text("Read before every reply. Tone, what to call you, what to leave out.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
        }
    }

    private var switches: some View {
        VStack(spacing: 0) {
            SwitchRow(title: "Search the web by itself", detail: "When the answer depends on today: trends, news, games, prices.", symbol: "globe", isOn: $searchesWeb)
            Divider().padding(.leading, 48)
            SwitchRow(title: "Plain words", detail: "Short sentences, no jargon", symbol: "text.alignleft", isOn: $preferences.plainWords)
            Divider().padding(.leading, 48)
            SwitchRow(title: "No hashtags", detail: "Leave them out unless I ask", symbol: "number", isOn: $preferences.noHashtags)
        }
        .background(GrokLook.card(scheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var clearChats: some View {
        Button(role: .destructive) {
            confirmingClear = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .frame(width: 22)
                Text(cleared ? "Chats cleared" : "Clear all chats")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.red)
        .background(GrokLook.card(scheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(cleared)
    }

    // MARK: - Saving

    private func load() {
        let parts = ChatPreferences.parse(saved)
        preferences = parts.preferences
        own = parts.own
        searchesWeb = !session.isOn(.webOff)
        savedSearchesWeb = searchesWeb
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if searchesWeb != savedSearchesWeb {
            await session.set(.webOff, !searchesWeb)
            savedSearchesWeb = searchesWeb
        }
        if composed != saved {
            guard await session.setChatInstructions(composed) else { return }
        }
        dismiss()
    }
}

/// One of Grok's preset cards: filled and ringed when picked, outlined when not.
private struct PresetCard: View {
    let option: ReplyLength
    let picked: Bool
    let pick: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.rawValue)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(option.blurb)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(picked ? GrokLook.card(scheme) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(picked ? Theme.accent : Color.primary.opacity(0.14), lineWidth: picked ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: picked)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

private struct SwitchRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn.animation(.snappy(duration: 0.25))) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Claude's memory, inside the Settings sheet: whether the chat remembers, what
/// it remembers -- one line at a time, swipe one away -- and clearing all of it.
struct MemoryView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.colorScheme) private var scheme

    @State private var notes: [MemoryNote] = []
    @State private var loaded = false
    @State private var remembers = true
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                Toggle("Remember from my chats", isOn: Binding(
                    get: { remembers },
                    set: { on in
                        remembers = on
                        Task { await session.set(.memoryOff, !on) }
                    }
                ))
                .tint(Theme.accent)
            } footer: {
                Text("Postpilot learns from your conversations and uses it in every new chat.")
            }

            Section {
                if notes.isEmpty {
                    Text(loaded ? "Nothing yet. It fills in as you chat." : "Loading…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notes) { note in
                        Text(note.note)
                            .font(.system(.body, design: .serif))
                            .padding(.vertical, 2)
                    }
                    .onDelete(perform: forget)
                }
            } header: {
                Text("What Postpilot remembers")
            } footer: {
                if !notes.isEmpty { Text("Swipe a line to make it forget that.") }
            }

            if !notes.isEmpty {
                Section {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear memory", systemImage: "trash")
                            .foregroundStyle(Color.red)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GrokLook.sheet(scheme).ignoresSafeArea())
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            remembers = !session.isOn(.memoryOff)
            notes = await session.memoryNotes()
            loaded = true
        }
        .refreshable { notes = await session.memoryNotes() }
        .alert("Clear memory?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task {
                    if await session.clearMemory() {
                        withAnimation { notes = [] }
                    }
                }
            }
        } message: {
            Text("Postpilot forgets everything it learned about you. Your chats stay.")
        }
    }

    private func forget(_ offsets: IndexSet) {
        let gone = offsets.map { notes[$0] }
        withAnimation { notes.remove(atOffsets: offsets) }
        Task {
            for note in gone { _ = await session.forget(note) }
        }
    }
}
