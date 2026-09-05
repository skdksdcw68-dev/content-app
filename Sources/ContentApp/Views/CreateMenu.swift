import SwiftUI

/// What the Create button opens: four things you can ask for by name.
///
/// A compact sheet rather than a full screen, because choosing one of four is
/// not a task that deserves a screen. Whichever is picked lands in the queue as
/// a planned post and the sheet closes -- there is no wizard, because the
/// autopilot writing it is the entire point.
struct CreateMenu: View {
    @Environment(ContentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CreateKind.allCases) { kind in
                        Button {
                            store.requestDraft(kind)
                            dismiss()
                        } label: {
                            CreateRow(kind: kind)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Autocast plans on its own as well. These are for when you want something specific rather than whatever it would have chosen.")
                }
            }
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct CreateRow: View {
    let kind: CreateKind

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.softAccent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(kind.detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    let store = ContentStore()
    return Color(.systemGroupedBackground)
        .sheet(isPresented: .constant(true)) {
            CreateMenu()
                .environment(store)
        }
        .task { await store.connect() }
}
