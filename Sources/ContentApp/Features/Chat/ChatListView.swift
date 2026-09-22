import SwiftUI
import TipKit

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
    private let startTip = ChatStartTip()

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
            }

            if let threads {
                if !threads.isEmpty {
                    Section {
                        ForEach(threads) { thread in
                            NavigationLink(value: AppRoute.chat(thread.id)) {
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
        .tabChrome(title: "Chat")
        // Reloaded whenever the list comes back into view, so a conversation
        // that just gained a reply -- or one started a moment ago -- is here
        // on the pop rather than after a pull-to-refresh.
        .task { threads = await session.threads() }
        .onAppear { Task { threads = await session.threads() } }
        .refreshable { threads = await session.threads() }
    }
}
