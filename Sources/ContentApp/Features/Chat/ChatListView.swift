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

/// Where the Chat tab lands.
///
/// It used to open straight into a conversation, which meant there was no way
/// to reach an earlier one and no obvious way to start a fresh one -- the tab
/// was a door into whichever chat happened to be in memory.
///
/// So the tab is the list, and a conversation is something you enter from it.
/// That also fixes the tab bar: browsing your conversations is browsing, and
/// the bar belongs there. It hides only once you are inside a conversation,
/// which is the one place the full screen is worth having.
struct ChatListView: View {
    @Environment(AppSession.self) private var session

    @State private var threads: [ChatThread] = []
    @State private var opened: ChatThread?
    @State private var startingNew = false
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if threads.isEmpty {
                EmptyState { startingNew = true }
            } else {
                List {
                    ForEach(threads) { thread in
                        Button { opened = thread } label: {
                            ThreadRow(thread: thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { startingNew = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New chat")
            }
        }
        // A conversation covers the app, keeps the tab bar hidden, and comes
        // back here. Full screen rather than a sheet because a chat is a place
        // you work in, not something you peek at.
        .fullScreenCover(item: $opened) { thread in
            NavigationStack {
                ChatView(threadId: thread.id, onClose: { opened = nil })
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .fullScreenCover(isPresented: $startingNew) {
            NavigationStack {
                ChatView(onClose: { startingNew = false })
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .task { await load() }
        // Reloaded on return so a conversation that just gained a reply, or one
        // that was started from the empty state, is in the list.
        .onChange(of: opened) { _, value in if value == nil { Task { await load() } } }
        .onChange(of: startingNew) { _, value in if !value { Task { await load() } } }
        .refreshable { await load() }
    }

    private func load() async {
        threads = await session.threads()
        loading = false
    }
}

private struct ThreadRow: View {
    let thread: ChatThread

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(thread.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(thread.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !thread.preview.isEmpty {
                Text(thread.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct EmptyState: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Ask Autocast")
                    .font(.title3.weight(.semibold))
                Text("Plan a month, research something, make a video. It keeps working when you close the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onStart) {
                Text("Start a chat")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(PressButtonStyle())
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
