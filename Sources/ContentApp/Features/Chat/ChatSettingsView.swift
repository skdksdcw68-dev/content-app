import SwiftUI

/// How long a reply should be: the first thing Chat settings asks.
enum ReplyLength: String, CaseIterable, Identifiable, Sendable {
    case short = "Short"
    case balanced = "Balanced"
    case detailed = "Detailed"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .short: return "Quick answers, straight to the point"
        case .balanced: return "Enough detail to act on"
        case .detailed: return "Reasons, evidence and next steps. Takes longer."
        }
    }
}

/// What the taps on Chat settings say, and how they sit in the one text the
/// model already reads before every reply.
///
/// The taps are written as a first line in plain words ("Reply length: Short.
/// No hashtags."), and the owner's own words follow on the lines below. Nothing
/// new is stored and the server does not change: the line is read like any
/// other instruction, and this type reads it back so the screen can show the
/// taps again.
struct ChatPreferences: Equatable, Sendable {
    var length: ReplyLength = .balanced
    var noHashtags = false
    var plainWords = false

    private static let lead = "Reply length: "
    private static let hashtags = "No hashtags"
    private static let plain = "Plain words"

    /// The first line, or nil when every tap is at its default.
    var line: String? {
        guard self != ChatPreferences() else { return nil }
        var parts: [String] = [length.rawValue]
        if noHashtags { parts.append(Self.hashtags) }
        if plainWords { parts.append(Self.plain) }
        return Self.lead + parts.joined(separator: ". ") + "."
    }

    /// The taps and the owner's words as the one text that is saved.
    static func compose(_ preferences: ChatPreferences, own: String) -> String {
        let words = own.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = preferences.line else { return words }
        return words.isEmpty ? line : line + "\n" + words
    }

    /// The saved text, taken apart again.
    static func parse(_ saved: String) -> (preferences: ChatPreferences, own: String) {
        let text = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix(lead) else {
            return (ChatPreferences(), text)
        }
        let body = String(first.dropFirst(lead.count))
        let parts = body
            .components(separatedBy: ".")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var preferences = ChatPreferences()
        if let word = parts.first, let length = ReplyLength(rawValue: word) {
            preferences.length = length
        }
        preferences.noHashtags = parts.contains(hashtags)
        preferences.plainWords = parts.contains(plain)
        let own = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (preferences, own)
    }
}

/// Chat settings: how it should talk to you, what it knows, and clearing
/// the history. Abel, 23 Sep 2026: "the chat is really perfect, but make
/// sure we can have some chat settings."
///
/// Drawn like Claude's Effort and Privacy pages (Abel, 2 Nov 2026): a tick
/// list for how long a reply is, switches for small habits, and the owner's
/// own words in a box. All of it ends up in the instructions the model reads
/// after the rules -- they set tone and length, and cannot switch the honesty
/// rules off. What it knows is the Brand page, linked rather than copied.
struct ChatSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var preferences = ChatPreferences()
    @State private var own = ""
    @State private var saving = false
    @State private var confirmingClear = false
    @State private var cleared = false

    private var saved: String {
        (session.settings?.chatInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var composed: String { ChatPreferences.compose(preferences, own: own) }
    private var dirty: Bool { composed != saved }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ClaudeCaption("Reply length")
                    lengthGroup
                    habitsGroup
                    ClaudeCaption("In your own words")
                    ownWordsGroup
                    Text("Read before every reply. Tone, what to call you, what to leave out.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    linksGroup
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.claudePaper.ignoresSafeArea())
            .navigationTitle("Chat settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
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
        .presentationDetents([.large])
    }

    // MARK: - Pieces

    private var lengthGroup: some View {
        ClaudeGroup {
            ForEach(ReplyLength.allCases) { option in
                if option != ReplyLength.allCases.first {
                    ClaudeDivider()
                }
                lengthRow(option)
            }
        }
    }

    private func lengthRow(_ option: ReplyLength) -> some View {
        Button {
            preferences.length = option
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(option.rawValue)
                            .font(.body.weight(.medium))
                        if option == .balanced {
                            Text("Default")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    Text(option.blurb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if preferences.length == option {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(preferences.length == option ? .isSelected : [])
    }

    private var habitsGroup: some View {
        ClaudeGroup {
            habitRow("No hashtags", "Leave them out unless you ask", isOn: $preferences.noHashtags)
            ClaudeDivider()
            habitRow("Plain words", "Short sentences, no jargon", isOn: $preferences.plainWords)
        }
    }

    private func habitRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Theme.accent)
        .padding(14)
    }

    private var ownWordsGroup: some View {
        ClaudeGroup {
            TextField("Call me Abel. I post scary stories on TikTok.", text: $own, axis: .vertical)
                .lineLimit(3...8)
                .padding(14)
        }
    }

    private var linksGroup: some View {
        ClaudeGroup {
            NavigationLink {
                BrandView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text("What it knows")
                        .font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ClaudeDivider()
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .frame(width: 22)
                    Text(cleared ? "Chats cleared" : "Clear all chats")
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red)
            .disabled(cleared)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
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

    // MARK: - Saving

    private func load() {
        let parts = ChatPreferences.parse(saved)
        preferences = parts.preferences
        own = parts.own
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await session.setChatInstructions(composed) {
            dismiss()
        }
    }
}
