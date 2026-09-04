import SwiftUI

/// The chip row pinned under the nav bar. Tap a chip to narrow the queue, tap
/// it again to clear.
///
/// Built from `store.availableStatuses`, not from every case, so it never
/// offers a filter that would empty the list.
struct StatusFilterBar: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.availableStatuses) { status in
                    let isSelected = store.statusFilter == status
                    Button {
                        store.statusFilter = isSelected ? nil : status
                    } label: {
                        Label(status.displayName, systemImage: status.symbolName)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                isSelected
                                    ? StatusBadge.tint(for: status).opacity(0.2)
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? StatusBadge.tint(for: status) : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
}

#Preview {
    StatusFilterBar()
        .environment(ContentStore())
}
