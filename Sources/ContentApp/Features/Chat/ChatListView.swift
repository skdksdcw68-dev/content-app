import SwiftUI
import TipKit

/// One saved conversation, as the list needs it.
struct ChatThread: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let updatedAt: Date
    /// "chat" or "generation", so the list can say which is which and a
    /// reopened generation comes back as the generator (Abel, 26 Sep 2026:
    /// "on the chats list i want it to be identified as well").
    var kind: String = "chat"
    /// What the conversation MADE -- "video", "image" or "audio" -- or nil.
    /// Read from what was actually saved, not from what was asked for (0076).
    var media: String?

    var isGeneration: Bool { kind == "generation" }

    /// Anything that produced something, or was opened to. Both belong on the
    /// Create side of the list, whichever way they started.
    var isMaking: Bool { isGeneration || media != nil }

    var displayTitle: String {
        title.isEmpty ? "New chat" : title
    }

    /// The glyph for what it made, when it made something; "Generation" for a
    /// generator that has not yet; nothing for a plain conversation.
    ///
    /// Abel, 29 Sep 2026: "after you generate with the chat, there is no
    /// 'Video' or 'Generation' or 'Library' called or a badge."
    var badge: (title: String, symbol: String)? {
        switch media {
        case "video": return ("Video", "play.rectangle.fill")
        case "image": return ("Image", "photo.fill")
        case "audio": return ("Audio", "waveform")
        default:      return isGeneration ? ("Generation", "wand.and.stars") : nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, kind, media
        case updatedAt = "updated_at"
    }
}

/// The Chat tab: the Chat | Create switch, and the conversations had on each
/// side.
///
/// Abel, 2 Nov 2026, against Grok's Ask | Imagine: "make two options, Chat and
/// Creating ... on the chat bit, it's looking a bit messy." What was here: two
/// promotional rows with captions, filter chips in a header, and three-line
/// rows with a badge each. Now it is Claude's Chats list (Abel, after seeing it
/// on Mobbin: "this one fits me perfectly") under Grok's Ask | Imagine switch:
/// the switch (which is also the filter), a plain row per conversation -- its
/// title and how long ago -- a glyph where something was made, one floating
/// button to start, and a Search pill.
///
/// Built on the email app's `AITabView` rather than invented. The conversation
/// is PUSHED from here as an ordinary page -- not presented over the app as a
/// sheet -- because a conversation is somewhere you go into and come back from,
/// with the system's own back button and swipe-back gesture. It is pushed by
/// value (`AppRoute.chat`) on the stack around the tabs, so it opens over the
/// tab bar and the list keeps its bar underneath during the swipe back.
struct ChatListView: View {
    @Environment(AppSession.self) private var session

    /// Nil until the first read comes back, so the list can show its shape
    /// while it waits instead of an empty section.
    @State private var threads: [ChatThread]?
    @State private var showingSettings = false
    @State private var query = ""
    /// The search field is open at the top of the list.
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// Which side of the switch is showing, kept between launches.
    @AppStorage("chatListSide") private var side: Side = .chat
    private let startTip = ChatStartTip()

    private enum Side: String, CaseIterable, Identifiable {
        case chat, create
        var id: String { rawValue }
    }

    /// The conversations on this side -- the ones that only talked, or the
    /// ones that made things -- narrowed by what is typed in Search.
    private var shown: [ChatThread] {
        guard let threads else { return [] }
        let onThisSide = threads.filter { side == .create ? $0.isMaking : !$0.isMaking }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return onThisSide }
        return onThisSide.filter {
            $0.displayTitle.lowercased().contains(needle) || $0.preview.lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            // Search lives at the top now, opened from the bar beside the
            // settings gear. A solid field, not glass: over the rows it read as
            // a smear (Abel, 2 Nov 2026: "it's not clean").
            if searching {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search", text: $query)
                            .focused($searchFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                // The full width of the row: a fixed width in a row that also
                // asks for all of it made the switch shrink and fight itself.
                ModeSwitch(isCreate: Binding(
                    get: { side == .create },
                    set: { side = $0 ? .create : .chat }
                ), width: nil)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
            }

            // Everything that was made, from every conversation, on one shelf.
            if side == .create {
                Section {
                    NavigationLink(value: AppRoute.generated) {
                        Label("Library", systemImage: "square.grid.2x2")
                            .font(.body.weight(.medium))
                    }
                } footer: {
                    Text("Every picture, video and sound you've made.")
                }
            }

            if threads != nil {
                if shown.isEmpty {
                    Section {
                        Text(!query.isEmpty
                            ? "No matches."
                            : side == .create
                            ? "Nothing made yet. Tap New creation and describe a picture or a video."
                            : "No chats yet. Tap New chat to start one.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(shown) { thread in
                            // A generation opens AS the generator, from the
                            // first frame; everything else opens as chat.
                            NavigationLink(value: thread.isGeneration ? AppRoute.generation(thread.id) : AppRoute.chat(thread.id)) {
                                ThreadRow(thread: thread)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        await session.deleteThread(thread.id)
                                        self.threads?.removeAll { $0.id == thread.id }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            } else {
                // Shaped like the rows that are coming, breathing (Abel,
                // 22 Sep 2026: "when it loads make sure it's with skeleton").
                Section {
                    SkeletonRows(count: 4)
                } header: {
                    Text("Recent")
                }
            }
        }
        // Claude's way: "New chat" floating at the bottom. The button starts on
        // whichever side is showing. Search is up in the bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                NavigationLink(value: side == .create ? AppRoute.chatCreating : AppRoute.chat(nil)) {
                    Label(
                        side == .create ? "New creation" : "New chat",
                        systemImage: side == .create ? "sparkles" : "plus"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .popoverTip(startTip, arrowEdge: .bottom)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        // The title on the same line as search and settings (Abel, 2 Nov 2026).
        .tabChrome(
            title: "Chat",
            mode: .inlineLarge,
            trailing: AnyView(
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            searching.toggle()
                            if searching {
                                searchFocused = true
                            } else {
                                query = ""
                                searchFocused = false
                            }
                        }
                    } label: {
                        Image(systemName: searching ? "xmark" : "magnifyingglass")
                    }
                    .accessibilityLabel(searching ? "Close search" : "Search")

                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Chat settings")
                }
            )
        )
        .sheet(isPresented: $showingSettings, onDismiss: {
            Task { threads = await session.threads() }
        }) {
            ChatSettingsView()
        }
        // Reloaded whenever the list comes back into view, so a conversation
        // that just gained a reply -- or one started a moment ago -- is here
        // on the pop rather than after a pull-to-refresh.
        .task { threads = await session.threads() }
        .onAppear { Task { threads = await session.threads() } }
        .refreshable { threads = await session.threads() }
    }
}

/// One conversation, as Claude's list draws it: the title, and under it how
/// long ago, with a glyph in front when it made something.
private struct ThreadRow: View {
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 12) {
            if let badge = thread.badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
