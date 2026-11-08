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
    /// Pinned to the top of the list (0102).
    var pinned: Bool?

    var isGeneration: Bool { kind == "generation" }
    var isPinned: Bool { pinned == true }

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

    /// Where tapping it goes: a generation opens AS the generator, from the
    /// first frame; everything else opens as chat.
    var route: AppRoute { isGeneration ? .generation(id) : .chat(id) }

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, kind, media, pinned
        case updatedAt = "updated_at"
    }
}

/// The Chat tab: the Chat | Create switch, and the conversations had on each
/// side.
///
/// Claude's Chats list under Grok's Ask | Imagine switch: a plain row per
/// conversation -- its title and how long ago -- a glyph where something was
/// made, one floating button to start, and search up in the bar.
///
/// Abel, 8 Nov 2026 ("the chat needs a lot of features"): pinned chats sit in
/// their own section at the top; a long press offers Pin, Rename, Share and
/// Delete; swipe left to delete, right to pin; Select ticks several at once;
/// search looks inside the messages too; and a deleted chat goes to Recently
/// Deleted for 30 days instead of being gone at once.
///
/// The conversation is PUSHED from here as an ordinary page, by value
/// (`AppRoute.chat`) on the stack around the tabs, so it opens over the tab
/// bar and the list keeps its bar underneath during the swipe back.
struct ChatListView: View {
    @Environment(AppSession.self) private var session

    /// Nil until the first read comes back, so the list can show its shape
    /// while it waits instead of an empty section.
    @State private var threads: [ChatThread]?
    @State private var query = ""
    /// The search field is open at the top of the list.
    @State private var searching = false
    /// What the server found inside the messages, for `query`.
    @State private var found: [ChatThread]?
    @FocusState private var searchFocused: Bool
    /// Which side of the switch is showing, kept between launches.
    @AppStorage("chatListSide") private var side: Side = .chat
    /// Ticking several chats to delete or pin them together.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var renaming: ChatThread?
    @State private var newTitle = ""
    @State private var askingToShare: ChatThread?
    @State private var shared: SharedLink?
    private let startTip = ChatStartTip()

    private enum Side: String, CaseIterable, Identifiable {
        case chat, create
        var id: String { rawValue }
    }

    private struct SharedLink: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The conversations on this side -- the ones that only talked, or the
    /// ones that made things. While searching: what the server found inside
    /// the messages, or the titles that match until it answers.
    private var shown: [ChatThread] {
        guard let threads else { return [] }
        let needle = trimmedQuery.lowercased()
        let source: [ChatThread]
        if needle.isEmpty {
            source = threads
        } else if let found {
            source = found
        } else {
            source = threads.filter {
                $0.displayTitle.lowercased().contains(needle) || $0.preview.lowercased().contains(needle)
            }
        }
        return source.filter { side == .create ? $0.isMaking : !$0.isMaking }
    }

    private var pinned: [ChatThread] { trimmedQuery.isEmpty ? shown.filter(\.isPinned) : [] }
    private var recent: [ChatThread] { trimmedQuery.isEmpty ? shown.filter { !$0.isPinned } : shown }

    var body: some View {
        list
            .dismissesKeyboardOnTapInside()
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .tabChrome(title: "Chat", mode: .inlineLarge, trailing: AnyView(barItems))
            .task(id: trimmedQuery) { await search() }
            // Reloaded whenever the list comes back into view, so a
            // conversation that just gained a reply -- or one started a moment
            // ago -- is here on the pop rather than after a pull-to-refresh.
            .task { await reload() }
            .onAppear { Task { await reload() } }
            .refreshable { await reload() }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { rename() }
            }
            .confirmationDialog(
                "Share this chat?",
                isPresented: Binding(get: { askingToShare != nil }, set: { if !$0 { askingToShare = nil } }),
                titleVisibility: .visible,
                presenting: askingToShare
            ) { thread in
                Button("Create link") { share(thread) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Anyone with the link can read this conversation on the web. You can stop sharing any time by deleting the chat.")
            }
            .sheet(item: $shared) { link in
                ShareSheet(items: [link.url]).presentationDetents([.medium, .large])
            }
    }

    private var list: some View {
        List {
            // Search lives at the top, opened from the bar beside the photo.
            // A solid field, not glass: over the rows glass read as a smear
            // (Abel, 2 Nov 2026: "it's not clean").
            if searching {
                Section {
                    searchField
                }
            }

            if !selecting {
                Section {
                    // The full width of the row: a fixed width in a row that
                    // also asks for all of it made the switch fight itself.
                    ModeSwitch(isCreate: Binding(
                        get: { side == .create },
                        set: { side = $0 ? .create : .chat }
                    ), width: nil)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 6, trailing: 16))
                }
            }

            // Everything that was made, from every conversation, on one shelf.
            if side == .create && !selecting && trimmedQuery.isEmpty {
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
                        Text(emptyText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { row($0) }
                    } header: {
                        Text("Pinned")
                    }
                }
                if !recent.isEmpty {
                    Section {
                        ForEach(recent) { row($0) }
                    } header: {
                        if !pinned.isEmpty { Text("Recent") }
                    }
                }
                if !selecting && trimmedQuery.isEmpty {
                    Section {
                        NavigationLink(value: AppRoute.recentlyDeleted) {
                            Label("Recently Deleted", systemImage: "trash")
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
        .animation(.easeOut(duration: 0.2), value: threads)
        .animation(.easeOut(duration: 0.2), value: selecting)
    }

    private var emptyText: String {
        if !trimmedQuery.isEmpty { return "No chats with “\(trimmedQuery)”." }
        return side == .create
            ? "Nothing made yet. Tap New creation and describe a picture or a video."
            : "No chats yet. Tap New chat to start one."
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search titles and messages", text: $query)
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

    // MARK: One row

    @ViewBuilder
    private func row(_ thread: ChatThread) -> some View {
        if selecting {
            Button { toggle(thread.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected.contains(thread.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected.contains(thread.id) ? Theme.accent : Color(.tertiaryLabel))
                        .contentTransition(.symbolEffect(.replace))
                    ThreadRow(thread: thread, snippet: false)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: thread.route) {
                ThreadRow(thread: thread, snippet: !trimmedQuery.isEmpty)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete([thread.id]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                Button { pin(thread, !thread.isPinned) } label: {
                    Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
                }
                .tint(Theme.accent)
            }
            .contextMenu {
                Button { pin(thread, !thread.isPinned) } label: {
                    Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
                }
                Button {
                    newTitle = thread.title
                    renaming = thread
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { askingToShare = thread } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    selecting = true
                    selected = [thread.id]
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                Divider()
                Button(role: .destructive) { delete([thread.id]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Bars

    private var barItems: some View {
        HStack(spacing: 16) {
            if selecting {
                Button("Done") {
                    selecting = false
                    selected = []
                }
                .fontWeight(.semibold)
            } else {
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

                Menu {
                    Button {
                        selecting = true
                        selected = []
                    } label: {
                        Label("Select chats", systemImage: "checkmark.circle")
                    }
                    Button { session.push(.recentlyDeleted) } label: {
                        Label("Recently Deleted", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }

            SettingsAvatarButton()
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if selecting {
            let count = selected.count
            let allPinned = !selected.isEmpty && selected.allSatisfy { id in shown.first { $0.id == id }?.isPinned == true }
            HStack {
                Button {
                    let ids = selected
                    Task {
                        for id in ids { await session.pinThread(id, pinned: !allPinned) }
                        selecting = false
                        selected = []
                        await reload()
                    }
                } label: {
                    Label(allPinned ? "Unpin" : "Pin", systemImage: allPinned ? "pin.slash" : "pin")
                }
                .disabled(count == 0)

                Spacer()

                Text(count == 0 ? "Select chats" : "\(count) selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) { delete(selected) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(count == 0)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        } else {
            // Claude's way: "New chat" floating at the bottom. The button
            // starts on whichever side is showing.
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
    }

    // MARK: Actions

    private func reload() async {
        threads = await session.threads()
    }

    /// Asks the server once typing pauses; the titles already on the phone
    /// answer in the meantime.
    private func search() async {
        let words = trimmedQuery
        guard !words.isEmpty else {
            found = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let results = await session.searchThreads(words)
        guard !Task.isCancelled else { return }
        found = results
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Off the list at once, into Recently Deleted on the server.
    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            threads?.removeAll { ids.contains($0.id) }
            found?.removeAll { ids.contains($0.id) }
        }
        selecting = false
        selected = []
        Task {
            for id in ids { await session.deleteThread(id) }
            await reload()
        }
    }

    private func pin(_ thread: ChatThread, _ on: Bool) {
        if let index = threads?.firstIndex(where: { $0.id == thread.id }) {
            withAnimation(.easeOut(duration: 0.2)) { threads?[index].pinned = on }
        }
        Task {
            await session.pinThread(thread.id, pinned: on)
            await reload()
        }
    }

    private func rename() {
        guard let thread = renaming else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !title.isEmpty else { return }
        Task {
            await session.renameThread(thread.id, to: title)
            await reload()
        }
    }

    private func share(_ thread: ChatThread) {
        Task {
            if let url = await session.shareLink(for: thread.id) {
                shared = SharedLink(url: url)
            }
        }
    }
}

/// One conversation, as Claude's list draws it: the title, and under it how
/// long ago -- or, while searching, the words found inside it -- with a glyph
/// in front when it made something and a pin when it is pinned.
struct ThreadRow: View {
    let thread: ChatThread
    var snippet = false

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
                HStack(spacing: 6) {
                    Text(thread.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                    if thread.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                }
                if snippet && !thread.preview.isEmpty {
                    Text(thread.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
