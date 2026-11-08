import SwiftUI

/// A chat in Recently Deleted.
struct DeletedThread: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let updatedAt: Date
    let deletedAt: Date
    var kind: String?
    var media: String?

    var displayTitle: String { title.isEmpty ? "New chat" : title }

    /// Days before it goes for good, as Photos counts them.
    var daysLeft: Int {
        let gone = deletedAt.addingTimeInterval(30 * 24 * 3600)
        let seconds = gone.timeIntervalSinceNow
        return max(0, Int((seconds / 86_400).rounded(.up)))
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, kind, media
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

/// Recently Deleted, Photos' way (Abel, 8 Nov 2026: "recovery things for the
/// deleted chats, a recycling kind of thing"): each deleted chat with the days
/// it has left, Restore or Delete Now on a swipe or a tap, Select for several,
/// and Recover All / Delete All. After 30 days a nightly job removes them.
struct RecentlyDeletedView: View {
    @Environment(AppSession.self) private var session

    @State private var chats: [DeletedThread]?
    @State private var acting: DeletedThread?
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var confirmingDeleteAll = false

    private var deleteTitle: String {
        selected.isEmpty ? "Delete all chats for good?" : "Delete \(selected.count) for good?"
    }

    private var targets: [DeletedThread] {
        guard let chats else { return [] }
        return selected.isEmpty ? chats : chats.filter { selected.contains($0.id) }
    }

    var body: some View {
        List {
            if let chats {
                if chats.isEmpty {
                    ContentUnavailableView(
                        "No deleted chats",
                        systemImage: "trash",
                        description: Text("Chats you delete stay here for 30 days, so you can get them back.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(chats) { chat in
                            row(chat)
                        }
                    } footer: {
                        Text("Chats are deleted for good after the number of days shown.")
                    }
                }
            } else {
                Section { SkeletonRows(count: 3) }
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if chats?.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        selected = []
                    }
                    .fontWeight(selecting ? .semibold : .regular)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if chats?.isEmpty == false {
                bottomBar
            }
        }
        .confirmationDialog(
            acting?.displayTitle ?? "",
            isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
            titleVisibility: .visible,
            presenting: acting
        ) { chat in
            Button("Recover Chat") { restore([chat.id]) }
            Button("Delete Now", role: .destructive) { purge([chat.id]) }
            Button("Cancel", role: .cancel) {}
        } message: { chat in
            Text("This chat will be deleted for good in \(chat.daysLeft) \(chat.daysLeft == 1 ? "day" : "days").")
        }
        .alert(deleteTitle, isPresented: $confirmingDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if selected.isEmpty {
                    emptyAll()
                } else {
                    purge(selected)
                }
            }
        } message: {
            Text("They can’t be recovered after this.")
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func row(_ chat: DeletedThread) -> some View {
        Button {
            if selecting {
                if selected.contains(chat.id) { selected.remove(chat.id) } else { selected.insert(chat.id) }
            } else {
                acting = chat
            }
        } label: {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: selected.contains(chat.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected.contains(chat.id) ? Theme.accent : Color(.tertiaryLabel))
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.displayTitle)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if !chat.preview.isEmpty {
                        Text(chat.preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("\(chat.daysLeft) \(chat.daysLeft == 1 ? "day" : "days")")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { purge([chat.id]) } label: {
                Label("Delete Now", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { restore([chat.id]) } label: {
                Label("Recover", systemImage: "arrow.uturn.backward")
            }
            .tint(Theme.accent)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(role: .destructive) { confirmingDeleteAll = true } label: {
                Text(selected.isEmpty ? "Delete All" : "Delete")
            }
            .tint(.red)
            .disabled(selecting && selected.isEmpty)

            Spacer()

            Button {
                restore(Set(targets.map(\.id)))
            } label: {
                Text(selected.isEmpty ? "Recover All" : "Recover")
            }
            .disabled(selecting && selected.isEmpty)
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func reload() async {
        chats = await session.deletedThreads()
    }

    private func restore(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { chats?.removeAll { ids.contains($0.id) } }
        selecting = false
        selected = []
        Task {
            for id in ids { await session.restoreThread(id) }
            await reload()
        }
    }

    private func purge(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) { chats?.removeAll { ids.contains($0.id) } }
        selecting = false
        selected = []
        Task {
            for id in ids { await session.purgeThread(id) }
            await reload()
        }
    }

    private func emptyAll() {
        withAnimation(.easeOut(duration: 0.2)) { chats = [] }
        selecting = false
        Task {
            await session.emptyDeletedThreads()
            await reload()
        }
    }
}
