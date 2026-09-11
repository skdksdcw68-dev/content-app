import SwiftUI

/// One saved conversation, as the list needs it.
struct ChatThread: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let updatedAt: Date

    var displayTitle: String {
        title.isEmpty ? "New chat" : title
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, preview
        case updatedAt = "updated_at"
    }
}

/// Where the Chat tab can go.
///
/// Value-based, like the email app's `AIRoute`, and for the reason recorded
/// there: a view-based push and value-based pushes inside the chat cannot share
/// one navigation path, so tapping something from inside a conversation would
/// replace the conversation instead of stacking on it.
enum ChatRoute: Hashable {
    /// A saved conversation by id, or a fresh one.
    case chat(UUID?)
}

/// The Chat tab: a way into a new conversation, and the ones already had.
///
/// Built on the email app's `AITabView` rather than invented. The conversation
/// is PUSHED from here as an ordinary page -- not presented over the app as a
/// sheet -- because a conversation is somewhere you go into and come back from,
/// with the system's own back button and swipe-back gesture. The tab bar slides
/// away with the push and back with the pop (`hidesTabBar()`), which is what
/// UIKit's `hidesBottomBarWhenPushed` always did.
struct ChatListView: View {
    @Environment(AppSession.self) private var session

    @State private var threads: [ChatThread] = []

    var body: some View {
        List {
            Section {
                NavigationLink(value: ChatRoute.chat(nil)) {
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
            }

            if !threads.isEmpty {
                Section {
                    ForEach(threads) { thread in
                        NavigationLink(value: ChatRoute.chat(thread.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
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
                    }
                } header: {
                    Text("Recent chats")
                }
            }
        }
        .navigationTitle("Chat")
        .navigationDestination(for: ChatRoute.self) { route in
            switch route {
            case .chat(let id): ChatView(threadId: id)
            }
        }
        // Reloaded whenever the list comes back into view, so a conversation
        // that just gained a reply -- or one started a moment ago -- is here
        // on the pop rather than after a pull-to-refresh.
        .task { threads = await session.threads() }
        .onAppear { Task { threads = await session.threads() } }
        .refreshable { threads = await session.threads() }
    }
}
