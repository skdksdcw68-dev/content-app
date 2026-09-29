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

    /// Anything that produced something, or was opened to. Both belong under
    /// Generations, whichever way they started.
    var isMaking: Bool { isGeneration || media != nil }

    var displayTitle: String {
        title.isEmpty ? "New chat" : title
    }

    /// The word on the row, and its glyph. What it made, when it made
    /// something; "Generation" for a generator that has not yet; nothing for
    /// a plain conversation.
    ///
    /// Abel, 29 Sep 2026: "after you generate with the chat, there is no
    /// 'Video' or 'Generation' or 'Library' called or a badge." There was a
    /// wand the size of a full stop.
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

/// The word that says what a conversation made: a small accent capsule.
private struct ThreadBadge: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// The Chat tab: a way into a new conversation, and the ones already had.
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
    @State private var filter: Filter = .all
    private let startTip = ChatStartTip()

    /// Which conversations are shown: everything, the ones that only talked,
    /// or the ones that made things.
    private enum Filter: String, CaseIterable, Identifiable {
        case all, chats, generations
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:         "All"
            case .chats:       "Chats"
            case .generations: "Generations"
            }
        }
    }

    private var shown: [ChatThread] {
        guard let threads else { return [] }
        switch filter {
        case .all:         return threads
        case .chats:       return threads.filter { !$0.isMaking }
        case .generations: return threads.filter { $0.isMaking }
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink(value: AppRoute.chat(nil)) {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.text.bubble.right.fill")
                            .font(.body)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Talk to Autocast")
                                .font(.subheadline.weight(.semibold))
                            Text("Plan, research, make — it keeps working when you close the app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .popoverTip(startTip, arrowEdge: .top)

                // Everything that was made, from every conversation, on one
                // shelf. Named on the screen where the making starts.
                NavigationLink(value: AppRoute.generated) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.body)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Library")
                                .font(.subheadline.weight(.semibold))
                            Text("Every picture, video and sound you've made.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            if let threads {
                if !threads.isEmpty {
                    Section {
                        if shown.isEmpty {
                            Text(filter == .generations ? "Nothing made yet." : "No chats yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(shown) { thread in
                            NavigationLink(value: AppRoute.chat(thread.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(thread.displayTitle)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        // What it made, in a word -- Video,
                                        // Image or Generation -- so the ones
                                        // that made things read differently
                                        // from the ones that talked.
                                        if let badge = thread.badge {
                                            ThreadBadge(title: badge.title, symbol: badge.symbol)
                                        }
                                    }
                                    if !thread.preview.isEmpty {
                                        Text(thread.preview)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
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
                    } header: {
                        filterChips
                    }
                }
            } else {
                // Shaped like the rows that are coming, breathing (Abel,
                // 22 Sep 2026: "when it loads make sure it's with skeleton").
                Section {
                    SkeletonRows(count: 4)
                } header: {
                    Text("Recent chats")
                }
            }
        }
        .tabChrome(
            title: "Chat",
            trailing: AnyView(
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Chat settings")
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

    /// All, Chats, Generations -- what the list is showing, said as chips.
    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { filter = item }
                } label: {
                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(filter == item ? Theme.onAccent : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            filter == item ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.track),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}
